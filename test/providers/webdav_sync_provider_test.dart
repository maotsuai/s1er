import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:s1er/providers/auth_provider.dart';
import 'package:s1er/providers/automation_settings_provider.dart';
import 'package:s1er/providers/talker_provider.dart';
import 'package:s1er/providers/settings_provider.dart';
import 'package:s1er/providers/webdav_sync_provider.dart';
import 'package:s1er/services/app_local_data.dart';
import 'package:s1er/services/app_icon_service.dart';
import 'package:s1er/services/backup/s1_backup_service.dart';
import 'package:s1er/services/http_client.dart';
import 'package:s1er/services/sync/webdav_sync_service.dart';

import '../helpers/test_local_data.dart';

class _Config extends WebDavConfigNotifier {
  @override
  Future<WebDavConfig?> build() async => const WebDavConfig(
        directoryUrl: 'https://dav.example.com/s1er/',
        username: 'test',
        password: 'test-secret',
      );
}

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState();
}

class _Icons extends AppIconService {
  @override
  bool get isSupported => false;
}

class _SyncService extends WebDavSyncService {
  _SyncService(super.client, super.local, super.backup);
  int calls = 0;
  WebDavSyncException? failure;
  Completer<void>? gate;
  Future<void> Function()? onSync;

  @override
  Future<void> synchronize({
    required WebDavConfig config,
    required String? uid,
    required PackageInfo packageInfo,
    required String platform,
  }) async {
    calls++;
    await gate?.future;
    if (failure != null) throw failure!;
    await onSync?.call();
  }
}

void main() {
  late ProviderContainer container;
  late AppLocalData local;
  late _SyncService service;
  late DateTime now;
  late ProviderContainer Function() reopen;

  Future<WebDavSyncNotifier> setup({bool smart = true}) async {
    final (db, data) = await openTestLocalData();
    local = data;
    addTearDown(db.close);
    now = DateTime(2026, 10, 22, 12);
    await local.settings.putAsync('webdav_sync_on_startup', true);
    await local.settings.putAsync('webdav_sync_while_using', smart);
    await local.settings.putAsync('themeMode', 'system');
    final dummy = ProviderContainer();
    addTearDown(dummy.dispose);
    service = _SyncService(
      S1HttpClient.test(dummy, Dio()),
      local,
      S1BackupService(local),
    );
    reopen = () => ProviderContainer(
          overrides: [
            localDataProvider.overrideWithValue(local),
            authStateProvider.overrideWith(_Auth.new),
            webDavConfigProvider.overrideWith(_Config.new),
            webDavSyncServiceProvider.overrideWithValue(service),
            webDavClockProvider.overrideWithValue(() => now),
            appIconServiceProvider.overrideWithValue(_Icons()),
            packageInfoProvider.overrideWith(
              (_) async => PackageInfo(
                appName: 's1er',
                packageName: 's1er',
                version: '1',
                buildNumber: '1',
              ),
            ),
          ],
        );
    container = reopen();
    addTearDown(container.dispose);
    final notifier = container.read(webDavSyncProvider.notifier);
    await container.read(webDavConfigProvider.future);
    notifier.start();
    return notifier;
  }

  Future<void> advance(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
    await tester.runAsync(() => pumpEventQueue(times: 30));
    // Drift 和 provider 的异步完成需要后续 microtask 帧。
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
  }

  testWidgets('coalesces thread switches, waits for idle and saves long reads',
      (tester) async {
    final notifier = await setup();
    await advance(tester, const Duration(seconds: 2));
    expect(service.calls, 1);
    expect(container.read(webDavSyncProvider).lastSuccess, isNotNull);
    for (var i = 0; i < 20; i++) {
      final session = Object();
      notifier.enterReading(session);
      local.markSyncChanged();
      notifier.leaveReading(session);
      await advance(tester, const Duration(seconds: 10));
    }
    expect(service.calls, 1);
    final reader = Object();
    notifier.enterReading(reader);
    await advance(tester, const Duration(minutes: 4));
    expect(service.calls, 1); // 到期仍在加载/滚动。
    notifier.setReadingBusy(reader, false);
    await advance(tester, const Duration(seconds: 2));
    expect(service.calls, 2); // 同一帖内停止滚动后兜底。
    expect(container.read(webDavSyncProvider).hasPendingChanges, isFalse);
    notifier.leaveReading(reader);
    await advance(tester, const Duration(minutes: 30));
    expect(service.calls, 2); // 没有本机改动，不轮询。
  });

  testWidgets('three network failures use seven minutes before capped backoff',
      (tester) async {
    await setup();
    service.failure =
        const WebDavSyncException('网络不可用', kind: WebDavSyncFailureKind.network);
    await advance(tester, const Duration(seconds: 2));
    expect(service.calls, 1);
    for (final minutes in [7, 7, 14, 28, 56, 60]) {
      await advance(tester, Duration(minutes: minutes, seconds: -1));
      final before = service.calls;
      await advance(tester, const Duration(seconds: 1));
      expect(service.calls, before + 1);
    }
    service.failure = null;
    await tester
        .runAsync(() => container.read(webDavSyncProvider.notifier).sync());
    expect(container.read(webDavSyncProvider).error, isNull);
    expect(
      container.read(webDavSyncProvider).nextAttempt,
      now.add(const Duration(minutes: 7)),
    );
  });

  testWidgets(
      'background suspends work; resume checks remote under shared cooldown',
      (tester) async {
    final notifier = await setup();
    await advance(tester, const Duration(seconds: 2));
    notifier.setForeground(false);
    local.markSyncChanged();
    await advance(tester, const Duration(hours: 1));
    expect(service.calls, 1);
    notifier.setForeground(true);
    await advance(tester, const Duration(seconds: 2));
    expect(service.calls, 2);
    notifier.setForeground(false);
    await advance(tester, const Duration(minutes: 5));
    notifier.setForeground(true);
    await advance(tester, const Duration(minutes: 1, seconds: 59));
    expect(service.calls, 2);
    await advance(tester, const Duration(seconds: 1));
    expect(service.calls, 3); // 本机没有改动也接收其他设备的数据。
  });

  testWidgets('manual sync shares lock, retains new writes and resets cooldown',
      (tester) async {
    final notifier = await setup();
    service.gate = Completer<void>();
    await advance(tester, const Duration(seconds: 2));
    expect(service.calls, 1);
    await tester.runAsync(() => notifier.sync());
    expect(service.calls, 1);
    local.markSyncChanged();
    service.gate!.complete();
    await advance(tester, Duration.zero);
    expect(container.read(webDavSyncProvider).hasPendingChanges, isTrue);
    service.gate = null;
    await tester.runAsync(() => notifier.sync());
    expect(service.calls, 2);
    expect(container.read(webDavSyncProvider).hasPendingChanges, isFalse);
    local.markSyncChanged();
    await advance(tester, const Duration(minutes: 6, seconds: 59));
    expect(service.calls, 2);
    await advance(tester, const Duration(seconds: 1));
    expect(service.calls, 3);
  });

  testWidgets(
      'permanent errors pause; configuration change and manual retry recover',
      (tester) async {
    final notifier = await setup();
    service.failure = const WebDavSyncException('认证失败');
    await advance(tester, const Duration(seconds: 2));
    expect(container.read(webDavSyncProvider).isPaused, isTrue);
    await advance(tester, const Duration(hours: 3));
    expect(service.calls, 1);
    notifier.configurationChanged(resetTarget: false);
    service.failure = null;
    await advance(tester, const Duration(seconds: 2));
    expect(service.calls, 2);
    expect(container.read(webDavSyncProvider).isPaused, isFalse);
  });

  testWidgets(
      'cloud layout preferences stay frozen until all reading sessions leave',
      (tester) async {
    final notifier = await setup();
    expect(container.read(settingsProvider).fontSize, 14);
    final reader = Object();
    notifier.enterReading(reader);
    service.onSync = () async {
      await local.db.setSetting('fontSize', 20);
      await local.settings.load(); // 云端导入，不属于用户修改。
    };
    await tester.runAsync(() => notifier.sync());
    expect(local.settings.get<int>('fontSize'), 20);
    expect(container.read(settingsProvider).fontSize, 14);
    expect(container.read(webDavSyncProvider).hasDeferredRefresh, isTrue);
    notifier.leaveReading(reader);
    await advance(tester, Duration.zero);
    expect(container.read(settingsProvider).fontSize, 20);
    expect(container.read(webDavSyncProvider).hasDeferredRefresh, isFalse);
  });

  testWidgets('restart preserves cooldown and three-failure backoff',
      (tester) async {
    await setup();
    service.failure =
        const WebDavSyncException('网络超时', kind: WebDavSyncFailureKind.network);
    await advance(tester, const Duration(seconds: 2));
    await advance(tester, const Duration(minutes: 7));
    await advance(tester, const Duration(minutes: 7));
    expect(service.calls, 3);
    container.dispose();
    local = AppLocalData(local.db);
    await local.load();
    now = now.add(const Duration(minutes: 5));
    container = reopen();
    addTearDown(container.dispose);
    await container.read(webDavConfigProvider.future);
    final notifier = container.read(webDavSyncProvider.notifier)..start();
    await advance(tester, const Duration(minutes: 8, seconds: 59));
    expect(service.calls, 3);
    await advance(tester, const Duration(seconds: 1));
    expect(service.calls, 4);
    notifier.setForeground(false);
  });

  testWidgets('turning automation off cancels a queued startup task',
      (tester) async {
    await setup();
    await container
        .read(automationSettingsProvider.notifier)
        .setSyncMode(WebDavAutoSyncMode.off);
    await advance(tester, const Duration(minutes: 10));
    expect(service.calls, 0);
  });

  testWidgets('legacy startup mode does not sync again while using app',
      (tester) async {
    final notifier = await setup(smart: false);
    await advance(tester, const Duration(seconds: 2));
    expect(service.calls, 1);
    local.markSyncChanged();
    notifier.setForeground(false);
    await advance(tester, const Duration(minutes: 8));
    notifier.setForeground(true);
    await advance(tester, const Duration(hours: 1));
    expect(service.calls, 1);
  });
}
