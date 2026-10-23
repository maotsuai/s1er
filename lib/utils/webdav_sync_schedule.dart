/// 共用的自动同步节流；时间与失败次数由 provider 持久化。
class WebDavSyncSchedule {
  static const interval = Duration(minutes: 7);
  static const resumeThreshold = Duration(minutes: 5);
  static const idleDelay = Duration(seconds: 2);

  /// 前三次尝试保持正常频次，第三次连续网络失败后开始退避。
  static Duration delayAfterFailures(int failures) {
    if (failures < 3) return interval;
    return Duration(
      minutes: switch (failures) {
        3 => 14,
        4 => 28,
        5 => 56,
        _ => 60,
      },
    );
  }

  static DateTime? nextAttempt(DateTime? lastAttempt, int failures) =>
      lastAttempt?.add(delayAfterFailures(failures));
}
