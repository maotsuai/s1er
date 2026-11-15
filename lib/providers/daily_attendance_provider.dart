import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/attendance_result.dart';
import '../services/forum_tools_service.dart';
import '../services/settings_store.dart';
import '../services/talker.dart';
import '../utils/daily_attendance_store.dart';
import 'auth_provider.dart';
import 'forum_tools_provider.dart';
import 'settings_provider.dart';

class DailyAttendanceState {
  const DailyAttendanceState({
    this.isSubmitting = false,
    this.result,
    this.loadingStatus = false,
  });

  final bool isSubmitting;
  final AttendanceResult? result;

  /// 首次进个人页时正在读取插件页面状态。
  final bool loadingStatus;

  DailyAttendanceState copyWith({
    bool? isSubmitting,
    AttendanceResult? result,
    bool? loadingStatus,
  }) {
    return DailyAttendanceState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      result: result ?? this.result,
      loadingStatus: loadingStatus ?? this.loadingStatus,
    );
  }
}

class DailyAttendanceNotifier extends Notifier<DailyAttendanceState> {
  int _statusRequest = 0;

  @override
  DailyAttendanceState build() {
    final request = ++_statusRequest;
    final auth = ref.watch(authStateProvider);
    final uid = auth.user?.uid.trim() ?? '';
    if (!auth.isLoggedIn || uid.isEmpty) {
      return const DailyAttendanceState();
    }

    // 请求结果跨页面保留，但到次日要清掉「今日已签到」展示。
    final now = DateTime.now();
    final nextDay = DateTime(now.year, now.month, now.day + 1);
    final reset = Timer(nextDay.difference(now), () {
      if (ref.mounted) ref.invalidateSelf();
    });
    ref.onDispose(reset.cancel);

    final store = _trySettingsStore();
    if (store != null &&
        DailyAttendanceStore.matches(
          raw:
              store.get(DailyAttendanceStore.settingsKeyFor(uid)) ??
              store.get(DailyAttendanceStore.settingsKey),
          uid: uid,
          now: DateTime.now(),
        )) {
      return const DailyAttendanceState(
        result: AttendanceResult(
          outcome: AttendanceOutcome.alreadySigned,
          message: '今日已签到',
        ),
      );
    }
    // 页面是唯一真源（插件没有只读接口），进入时主动读一次。
    scheduleMicrotask(() {
      if (ref.mounted && request == _statusRequest) unawaited(loadStatus());
    });

    return const DailyAttendanceState(loadingStatus: true);
  }

  ForumToolsService get _service => ref.read(forumToolsServiceProvider);

  SettingsStore? _trySettingsStore() {
    try {
      return ref.read(settingsStoreProvider);
    } catch (e, st) {
      talker.handle(e, st, 'Attendance settings unavailable');
      return null;
    }
  }

  /// 读取插件页面状态；只读，不产生签到写入。
  Future<void> loadStatus() async {
    if (state.isSubmitting) return;
    final request = ++_statusRequest;
    try {
      final result = await _service.fetchAttendanceStatus();
      if (!ref.mounted || request != _statusRequest) return;
      state = DailyAttendanceState(result: result);
    } catch (e) {
      if (!ref.mounted || request != _statusRequest) return;
      state = DailyAttendanceState(
        result: AttendanceResult(
          outcome: AttendanceOutcome.unknown,
          message: e.toString(),
        ),
      );
    }
  }

  /// 手动触发或已授权的启动自动签到；并发请求直接忽略。
  Future<void> sign({bool automatic = false}) async {
    if (state.isSubmitting) return;
    final auth = ref.read(authStateProvider);
    final uid = auth.user?.uid.trim() ?? '';
    if (automatic) {
      if (!auth.isLoggedIn || uid.isEmpty) return;
      final store = _trySettingsStore();
      if (store != null &&
          DailyAttendanceStore.matches(
            raw:
                store.get(DailyAttendanceStore.settingsKeyFor(uid)) ??
                store.get(DailyAttendanceStore.settingsKey),
            uid: uid,
            now: DateTime.now(),
          )) {
        return;
      }
    }
    final request = ++_statusRequest;
    state = state.copyWith(isSubmitting: true, loadingStatus: false);
    try {
      final result = await _service.dailySign();
      if (!ref.mounted || request != _statusRequest) return;
      if ((ref.read(authStateProvider).user?.uid.trim() ?? '') != uid) return;
      if (result.isSignedToday) {
        await _persistSignedToday(uid);
      }
      if (!ref.mounted ||
          request != _statusRequest ||
          (ref.read(authStateProvider).user?.uid.trim() ?? '') != uid) {
        return;
      }
      state = DailyAttendanceState(isSubmitting: false, result: result);
    } catch (e) {
      if (!ref.mounted || request != _statusRequest) return;
      if ((ref.read(authStateProvider).user?.uid.trim() ?? '') != uid) return;
      state = DailyAttendanceState(
        isSubmitting: false,
        result: AttendanceResult(
          outcome: AttendanceOutcome.failed,
          message: e.toString(),
        ),
      );
    }
  }

  Future<void> _persistSignedToday(String uid) async {
    if (uid.isEmpty) return;
    final store = _trySettingsStore();
    await store?.putAsync(
      DailyAttendanceStore.settingsKeyFor(uid),
      DailyAttendanceStore.payload(uid: uid, now: DateTime.now()),
    );
    await store?.putAsync(
      DailyAttendanceStore.settingsKey,
      DailyAttendanceStore.payload(uid: uid, now: DateTime.now()),
    );
  }
}

final dailyAttendanceProvider =
    NotifierProvider<DailyAttendanceNotifier, DailyAttendanceState>(
      DailyAttendanceNotifier.new,
    );
