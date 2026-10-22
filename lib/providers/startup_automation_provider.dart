import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/daily_attendance_store.dart';
import 'auth_provider.dart';
import 'automation_settings_provider.dart';
import 'daily_attendance_provider.dart';
import 'webdav_sync_provider.dart';

class StartupAutomationNotifier extends Notifier<void> {
  bool _startupChecked = false;
  final Set<String> _signAttempts = {};

  @override
  void build() {
    ref.listen(authStateProvider, (_, __) => _schedule());
    ref.listen(automationSettingsProvider, (_, __) => _schedule());
  }

  void start() => _schedule();

  void _schedule() {
    scheduleMicrotask(() {
      if (!ref.mounted) return;
      final settings = ref.read(automationSettingsProvider);
      if (!_startupChecked) {
        _startupChecked = true;
        ref.read(webDavSyncProvider.notifier).start();
      }
      final auth = ref.read(authStateProvider);
      final uid = auth.user?.uid ?? '';
      if (!settings.autoSign || !auth.isLoggedIn || uid.isEmpty) return;
      final key = '$uid/${DailyAttendanceStore.formatDate(DateTime.now())}';
      if (!_signAttempts.add(key)) return;
      // 手动与自动共用状态和并发锁，失败信息保留到设置页打开。
      unawaited(
        ref.read(dailyAttendanceProvider.notifier).sign(automatic: true),
      );
    });
  }
}

final startupAutomationProvider =
    NotifierProvider<StartupAutomationNotifier, void>(
  StartupAutomationNotifier.new,
);

final startupAutomationCoordinatorProvider = Provider<void>((ref) {
  ref.read(startupAutomationProvider.notifier).start();
});
