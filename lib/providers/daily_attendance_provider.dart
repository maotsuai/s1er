import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/attendance_result.dart';
import '../services/forum_tools_service.dart';
import '../services/settings_store.dart';
import '../utils/daily_attendance_store.dart';
import 'auth_provider.dart';
import 'forum_tools_provider.dart';
import 'settings_provider.dart';

class DailyAttendanceState {
  const DailyAttendanceState({this.isSubmitting = false, this.result});

  final bool isSubmitting;
  final AttendanceResult? result;

  DailyAttendanceState copyWith({
    bool? isSubmitting,
    AttendanceResult? result,
  }) {
    return DailyAttendanceState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      result: result ?? this.result,
    );
  }
}

class DailyAttendanceNotifier extends Notifier<DailyAttendanceState> {
  @override
  DailyAttendanceState build() {
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
          raw: store.get(DailyAttendanceStore.settingsKeyFor(uid)) ??
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
    return const DailyAttendanceState();
  }

  ForumToolsService get _service => ref.read(forumToolsServiceProvider);

  SettingsStore? _trySettingsStore() {
    try {
      return ref.read(settingsStoreProvider);
    } on Object {
      return null;
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
            raw: store.get(DailyAttendanceStore.settingsKeyFor(uid)) ??
                store.get(DailyAttendanceStore.settingsKey),
            uid: uid,
            now: DateTime.now(),
          )) {
        return;
      }
    }
    state = state.copyWith(isSubmitting: true);
    try {
      final result = await _service.dailySign();
      if (!ref.mounted) return;
      if ((ref.read(authStateProvider).user?.uid.trim() ?? '') != uid) return;
      if (result.isSignedToday) {
        await _persistSignedToday(uid);
      }
      if (!ref.mounted ||
          (ref.read(authStateProvider).user?.uid.trim() ?? '') != uid) {
        return;
      }
      state = DailyAttendanceState(isSubmitting: false, result: result);
    } catch (e) {
      if (!ref.mounted) return;
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
