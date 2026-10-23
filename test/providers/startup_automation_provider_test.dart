import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/models/attendance_result.dart';
import 'package:s1er/models/user.dart';
import 'package:s1er/providers/auth_provider.dart';
import 'package:s1er/providers/automation_settings_provider.dart';
import 'package:s1er/providers/daily_attendance_provider.dart';
import 'package:s1er/providers/forum_tools_provider.dart';
import 'package:s1er/providers/settings_provider.dart';
import 'package:s1er/providers/startup_automation_provider.dart';
import 'package:s1er/providers/webdav_sync_provider.dart';
import 'package:s1er/services/forum_tools_service.dart';
import 'package:s1er/services/http_client.dart';

import '../helpers/test_local_data.dart';

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState();
}

class _ForumTools extends ForumToolsService {
  _ForumTools(super.client);
  int calls = 0;
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<AttendanceResult> dailySign() async {
    calls++;
    await gate?.future;
    return AttendanceResult(
      outcome: fail ? AttendanceOutcome.failed : AttendanceOutcome.signedNow,
      message: fail ? '请求超时' : '签到成功',
    );
  }
}

class _Sync extends WebDavSyncNotifier {
  int calls = 0;
  @override
  WebDavSyncState build() => const WebDavSyncState();
  @override
  Future<void> sync({bool automatic = false}) async {
    calls++;
  }

  @override
  void start() {
    if (ref.read(automationSettingsProvider).syncOnStartup && calls == 0) {
      unawaited(sync(automatic: true));
    }
  }
}

void main() {
  Future<void> settle() => pumpEventQueue(times: 30);
  AuthState loggedIn(String uid) =>
      AuthState(isLoggedIn: true, user: User(uid: uid, username: 'user'));

  test('defaults do no work; startup sync executes once when opted in',
      () async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        localDataProvider.overrideWithValue(local),
        authStateProvider.overrideWith(_Auth.new),
        webDavSyncProvider.overrideWith(_Sync.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(startupAutomationCoordinatorProvider);
    await settle();
    final sync = container.read(webDavSyncProvider.notifier) as _Sync;
    expect(sync.calls, 0);
    await container
        .read(automationSettingsProvider.notifier)
        .setSyncOnStartup(true);
    await settle();
    expect(sync.calls, 0); // 开关变更不冒充冷启动。
    final restarted = ProviderContainer(
      overrides: [
        localDataProvider.overrideWithValue(local),
        authStateProvider.overrideWith(_Auth.new),
        webDavSyncProvider.overrideWith(_Sync.new),
      ],
    );
    addTearDown(restarted.dispose);
    restarted.read(startupAutomationCoordinatorProvider);
    await settle();
    restarted.read(startupAutomationProvider.notifier).start();
    restarted.read(authStateProvider.notifier).debugSetState(loggedIn('9'));
    await settle();
    expect((restarted.read(webDavSyncProvider.notifier) as _Sync).calls, 1);
  });

  test(
      'waits for session and uid, shares manual lock, persists daily skip across restart',
      () async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    await local.settings.putAsync('auto_daily_sign', true);
    final dummy = ProviderContainer();
    addTearDown(dummy.dispose);
    final forum = _ForumTools(S1HttpClient.test(dummy, Dio()))
      ..gate = Completer<void>();
    final overrides = [
      localDataProvider.overrideWithValue(local),
      authStateProvider.overrideWith(_Auth.new),
      forumToolsServiceProvider.overrideWithValue(forum),
    ];
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    container.read(startupAutomationCoordinatorProvider);
    await settle();
    expect(forum.calls, 0);
    container
        .read(authStateProvider.notifier)
        .debugSetState(AuthState(isLoggedIn: true));
    await settle();
    expect(forum.calls, 0);
    container.read(authStateProvider.notifier).debugSetState(loggedIn('9'));
    await settle();
    expect(forum.calls, 1);
    await container.read(dailyAttendanceProvider.notifier).sign();
    expect(forum.calls, 1);
    forum.gate!.complete();
    await settle();
    expect(container.read(dailyAttendanceProvider).result?.isSuccess, isTrue);
    final restarted = ProviderContainer(overrides: overrides);
    addTearDown(restarted.dispose);
    restarted.read(startupAutomationCoordinatorProvider);
    restarted.read(authStateProvider.notifier).debugSetState(loggedIn('9'));
    await settle();
    expect(forum.calls, 1);
    restarted.read(authStateProvider.notifier).debugSetState(loggedIn('10'));
    await settle();
    expect(forum.calls, 2);
  });

  test(
      'failed auto sign is visible and not automatically retried; manual retry works',
      () async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    await local.settings.putAsync('auto_daily_sign', true);
    final dummy = ProviderContainer();
    addTearDown(dummy.dispose);
    final forum = _ForumTools(S1HttpClient.test(dummy, Dio()))..fail = true;
    final container = ProviderContainer(
      overrides: [
        localDataProvider.overrideWithValue(local),
        authStateProvider.overrideWith(_Auth.new),
        forumToolsServiceProvider.overrideWithValue(forum),
      ],
    );
    addTearDown(container.dispose);
    container.read(startupAutomationCoordinatorProvider);
    container.read(authStateProvider.notifier).debugSetState(loggedIn('9'));
    await settle();
    container.read(startupAutomationProvider.notifier).start();
    await container
        .read(automationSettingsProvider.notifier)
        .setAutoSign(false);
    await container.read(automationSettingsProvider.notifier).setAutoSign(true);
    await settle();
    expect(forum.calls, 1);
    expect(container.read(dailyAttendanceProvider).result?.message, '请求超时');
    forum.fail = false;
    await container.read(dailyAttendanceProvider.notifier).sign();
    expect(forum.calls, 2);
    expect(container.read(dailyAttendanceProvider).result?.isSuccess, isTrue);
  });
}
