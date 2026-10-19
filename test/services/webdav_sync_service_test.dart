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
  var getCalls = 0;
  var requests = <HttpRequest>[];
  String Function(int)? formatEtag;
  Future<void> Function(int)? onGet;
  Future<void> Function()? onPut;
  Future<void> Function()? afterPut;

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
    getCalls = 0;
    requests = [];
    formatEtag = null;
    onGet = null;
    onPut = null;
    afterPut = null;
    server.listen((request) async {
      requests.add(request);
      final response = request.response;
      if (request.method == 'GET') {
        getCalls++;
        await onGet?.call(getCalls);
        if (failGet != 0) {
          response.statusCode = failGet;
        } else if (cloud == null) {
          response.statusCode = 404;
        } else {
          if (!omitEtag) {
            response.headers
                .set('etag', formatEtag?.call(revision) ?? '"$revision"');
          }
          response.add(cloud!);
        }
      } else if (request.method == 'PUT') {
        putCalls++;
        final data = await request
            .fold<List<int>>([], (out, chunk) => out..addAll(chunk));
        await onPut?.call();
        final expected = cloud == null
            ? request.headers.value('if-none-match') == '*'
            : request.headers.value('if-match') ==
                (formatEtag?.call(revision) ?? '"$revision"');
        if (conflict || !expected) {
          response.statusCode = 412;
        } else {
          cloud = Uint8List.fromList(data);
          revision++;
          response.statusCode = 201;
          await afterPut?.call();
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

  test('removed optional settings do not reappear on the next sync', () async {
    await local.settings.putAsync('forumSplitListPaneWidth', 600.0);
    await sync();
    final remote = S1BackupCodec.decode(cloud!);
    remote.settings!.remove('forum_split_list_pane_width');
    cloud = S1BackupCodec.encode(remote);
    revision++;
    await sync();
    expect(local.settings.get<Object>('forumSplitListPaneWidth'), isNull);
    await sync();
    expect(
      S1BackupCodec.decode(cloud!)
          .settings!
          .containsKey('forum_split_list_pane_width'),
      isFalse,
    );
  });

  test('Nutstore bare ETag is preserved and repeated sync verifies content',
      () async {
    formatEtag = (value) => 'nutstore-$value';
    cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
    await sync();
    expect(local.settings.get<String>('themeMode'), 'dark');
    expect(getCalls, 3);
    expect(
      requests.singleWhere((r) => r.method == 'PUT').headers.value('if-match'),
      'nutstore-1',
    );
    await local.settings.putAsync('fontSize', 20);
    await sync();
    expect(S1BackupCodec.decode(cloud!).settings!['font_size'], 20);
    expect(putCalls, 2);
    expect(getCalls, 6);
  });

  test('bare ETag preflight detects changed content even if ETag is unchanged',
      () async {
    formatEtag = (value) => '$value';
    await sync();
    final baseline = local.settings.get<Object>(WebDavSyncService.baselineKey);
    final changed = S1BackupCodec.encode(
      payload(settings: {'theme_mode': 'dark'}),
    );
    getCalls = 0;
    putCalls = 0;
    onGet = (count) async {
      if (count == 2) cloud = changed;
    };
    await expectLater(
      sync(),
      throwsA(
        isA<WebDavSyncException>()
            .having((e) => e.message, 'message', contains('另一台设备')),
      ),
    );
    expect(cloud, changed);
    expect(putCalls, 0);
    expect(local.settings.get<String>('themeMode'), isNot('dark'));
    expect(local.settings.get<Object>(WebDavSyncService.baselineKey), baseline);
  });

  test('bare ETag still uses conditional PUT when another device wins the race',
      () async {
    formatEtag = (value) => '$value';
    cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
    final oldCloud = cloud;
    onPut = () async {
      revision++;
    };
    await expectLater(sync(), throwsA(isA<WebDavSyncException>()));
    expect(putCalls, 1);
    expect(cloud, oldCloud);
    expect(local.settings.get<String>('themeMode'), isNot('dark'));
    expect(local.settings.get<Object>(WebDavSyncService.baselineKey), isNull);
  });

  test('bare ETag write verification failure preserves local data and baseline',
      () async {
    formatEtag = (value) => '$value';
    await local.settings.putAsync('themeMode', 'light');
    await sync();
    final baseline = local.settings.get<Object>(WebDavSyncService.baselineKey);
    cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
    revision++;
    afterPut = () async {
      cloud = S1BackupCodec.encode(payload(settings: {'font_size': 18}));
      revision++;
    };
    await expectLater(
      sync(),
      throwsA(
        isA<WebDavSyncException>()
            .having((e) => e.message, 'message', contains('写入后校验不一致')),
      ),
    );
    expect(local.settings.get<String>('themeMode'), 'light');
    expect(local.settings.get<Object>(WebDavSyncService.baselineKey), baseline);
  });

  test('bare ETag preflight does not recreate a concurrently deleted file',
      () async {
    formatEtag = (value) => '$value';
    cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
    onGet = (count) async {
      if (count == 2) cloud = null;
    };
    await expectLater(sync(), throwsA(isA<WebDavSyncException>()));
    expect(putCalls, 0);
    expect(cloud, isNull);
    expect(local.settings.get<String>('themeMode'), isNot('dark'));
  });

  test('quoted strong ETag with comma retains the standard single GET path',
      () async {
    formatEtag = (value) => '"$value,version"';
    cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
    await sync();
    expect(local.settings.get<String>('themeMode'), 'dark');
    expect(getCalls, 1);
    expect(requests.last.headers.value('if-match'), '"1,version"');
  });

  for (final invalidEtag in ['W/"1"', '*', '"1", "2"', '1,2', 'W/1']) {
    test('unsafe ETag $invalidEtag never uploads or imports', () async {
      formatEtag = (_) => invalidEtag;
      cloud = S1BackupCodec.encode(payload(settings: {'theme_mode': 'dark'}));
      await expectLater(sync(), throwsA(isA<WebDavSyncException>()));
      expect(putCalls, 0);
      expect(local.settings.get<String>('themeMode'), isNot('dark'));
      expect(local.settings.get<Object>(WebDavSyncService.baselineKey), isNull);
    });
  }

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
