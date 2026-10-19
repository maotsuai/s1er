import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:s1er/models/webdav_config.dart';
import 'package:s1er/services/app_database.dart';
import 'package:s1er/services/app_local_data.dart';
import 'package:s1er/services/backup/s1_backup_codec.dart';
import 'package:s1er/services/backup/s1_backup_service.dart';
import 'package:s1er/services/http_client.dart';
import 'package:s1er/services/sync/webdav_sync_service.dart';

import '../helpers/test_local_data.dart';

void main() {
  late AppDatabase db;
  late AppLocalData local;
  late S1BackupService backup;
  late WebDavSyncService service;
  late HttpServer server;
  late ProviderContainer container;
  late WebDavConfig config;
  Uint8List? cloud;
  var revision = 1;
  var failGet = 0;
  var conflict = false;
  var omitEtag = false;
  var putCalls = 0;
  var requests = <HttpRequest>[];
  Future<void> Function()? onPut;

  final info = PackageInfo(
    appName: 'S1er',
    packageName: 's1er',
    version: '0.9.0',
    buildNumber: '14',
  );

  Future<void> sync() => service.synchronize(
        config: config,
        uid: '9',
        packageInfo: info,
        platform: 'test',
      );

  S1BackupPayload payload({
    Map<String, dynamic>? settings,
    List<Map<String, dynamic>> history = const [],
  }) =>
      S1BackupPayload(
        manifest: {
          'format': s1BackupFormatId,
          'format_version': 1,
          'contents': [
            'settings',
            'reading_history',
            'blacklist',
            'poll_votes',
            'pinned_threads',
          ],
        },
        settings: settings,
        readingHistory: history,
      );

  setUp(() async {
    (db, local) = await openTestLocalData();
    backup = S1BackupService(local);
    container = ProviderContainer();
    var now = DateTime(2026);
    final client = S1HttpClient.test(
      container,
      Dio(),
      now: () => now,
      delay: (duration) async {
        now = now.add(duration);
      },
    );
    service = WebDavSyncService(client, local, backup);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    config = WebDavConfig(
      directoryUrl: 'http://127.0.0.1:${server.port}/dav/',
      username: 'user',
      password: 'private-test-password',
    );
    cloud = null;
    revision = 1;
    failGet = 0;
    conflict = false;
    omitEtag = false;
    putCalls = 0;
    requests = [];
    onPut = null;
    server.listen((request) async {
      requests.add(request);
      final response = request.response;
      if (request.method == 'GET') {
        if (failGet != 0) {
          response.statusCode = failGet;
        } else if (cloud == null) {
          response.statusCode = 404;
        } else {
          if (!omitEtag) response.headers.set('etag', '"$revision"');
          response.add(cloud!);
        }
      } else if (request.method == 'PUT') {
        putCalls++;
        final data = await request
            .fold<List<int>>([], (out, chunk) => out..addAll(chunk));
        await onPut?.call();
        final expected = cloud == null
            ? request.headers.value('if-none-match') == '*'
            : request.headers.value('if-match') == '"$revision"';
        if (conflict || !expected) {
          response.statusCode = 412;
        } else {
          cloud = Uint8List.fromList(data);
          revision++;
          response.statusCode = 201;
        }
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    container.dispose();
    await local.flushPendingWrites();
    await db.close();
  });

  test(
      'creates missing cloud file in existing directory using standard L1 backup',
      () async {
    await local.settings.putAsync('themeMode', 'dark');
    await local.settings.putAsync('auto_daily_sign', true);
    await sync();
    final uploaded = S1BackupCodec.decode(cloud!);
    expect(uploaded.settings!['theme_mode'], 'dark');
    expect(uploaded.settings!.containsKey('auto_daily_sign'), isFalse);
    expect(putCalls, 1);
    expect(requests.last.uri.path, '/dav/${WebDavConfig.fileName}');
    expect(
      requests.last.headers.value('authorization'),
      'Basic ${base64Encode(utf8.encode('user:private-test-password'))}',
    );
    expect(requests.last.headers.value('cookie'), isNull);
    expect(requests.last.uri.queryParameters.containsKey('formhash'), isFalse);
    expect(
      local.settings.get<Object>(WebDavSyncService.baselineKey),
      isNotNull,
    );
  });

  test('first sync restores cloud preferences and merges latest history by uid',
      () async {
    await backup.importPayload(
      payload(
        settings: {'theme_mode': 'light'},
        history: [
          {'uid': '9', 'tid': '1', 'last_read_at': 200, 'last_read_floor': 10},
          {'uid': '10', 'tid': '1', 'last_read_at': 50, 'last_read_floor': 2},
        ],
      ),
    );
    cloud = S1BackupCodec.encode(
      payload(
        settings: {'theme_mode': 'dark'},
        history: [
          {'uid': '9', 'tid': '1', 'last_read_at': 100, 'last_read_floor': 90},
          {'uid': '9', 'tid': '2', 'last_read_at': 300, 'last_read_floor': 20},
        ],
      ),
    );
    await sync();
    expect(local.settings.get<String>('themeMode'), 'dark');
    expect(local.readingHistory['9_1']!['lastReadFloor'], 10);
    expect(local.readingHistory.keys, containsAll(['9_1', '10_1', '9_2']));
    expect(requests.last.headers.value('if-match'), '"1"');
  });

  test(
      'propagates remote deletions and merges independent settings after baseline',
      () async {
    cloud = S1BackupCodec.encode(
      payload(
        settings: {'theme_mode': 'light', 'font_size': 14},
        history: [
          {'uid': '9', 'tid': '1', 'last_read_at': 100},
        ],
      ),
    );
    await sync();
    await local.settings.putAsync('fontSize', 18);
    cloud = S1BackupCodec.encode(
      payload(settings: {'theme_mode': 'dark', 'font_size': 14}),
    );
    revision++;
    await sync();
    expect(local.readingHistory, isEmpty);
    expect(local.settings.get<String>('themeMode'), 'dark');
    expect(local.settings.get<int>('fontSize'), 18);
    final uploaded = S1BackupCodec.decode(cloud!);
    expect(uploaded.readingHistory, isEmpty);
    expect(uploaded.settings!['font_size'], 18);
  });

  test(
      'concurrent remote update does not import or overwrite and retains baseline',
      () async {
    await sync();
    final baseline = local.settings.get<Object>(WebDavSyncService.baselineKey);
    final oldCloud = cloud;
    await local.settings.putAsync('themeMode', 'dark');
    conflict = true;
    await expectLater(
      sync(),
      throwsA(
        isA<WebDavSyncException>()
            .having((e) => e.message, 'message', contains('另一台设备')),
      ),
    );
    expect(cloud, oldCloud);
    expect(local.settings.get<String>('themeMode'), 'dark');
    expect(local.settings.get<Object>(WebDavSyncService.baselineKey), baseline);
  });

  test('invalid archive and missing ETag never upload or modify local data',
      () async {
    await local.settings.putAsync('themeMode', 'light');
    cloud = Uint8List.fromList(utf8.encode('invalid backup'));
    await expectLater(sync(), throwsA(isA<WebDavSyncException>()));
    cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
    omitEtag = true;
    await expectLater(
      sync(),
      throwsA(
        isA<WebDavSyncException>()
            .having((e) => e.message, 'message', contains('ETag')),
      ),
    );
    expect(putCalls, 0);
    expect(local.settings.get<String>('themeMode'), 'light');
  });

  test(
      'authentication and redirect failures are friendly and redact credentials',
      () async {
    for (final status in [401, 403, 302, 500]) {
      failGet = status;
      await expectLater(
        sync(),
        throwsA(
          isA<WebDavSyncException>().having(
            (e) => e.message,
            'message',
            isNot(contains(config.password)),
          ),
        ),
      );
    }
    expect(putCalls, 0);
  });

  test('local edits during upload stay local and are sent on next sync',
      () async {
    cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
    onPut = () => local.settings.putAsync('fontSize', 20);
    await sync();
    expect(local.settings.get<int>('fontSize'), 20);
    expect(S1BackupCodec.decode(cloud!).settings!['font_size'], 14);
    onPut = null;
    await sync();
    expect(S1BackupCodec.decode(cloud!).settings!['font_size'], 20);
  });
}
