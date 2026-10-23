import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/webdav_config.dart';
import '../services/http_client.dart';
import '../services/sync/webdav_credentials_store.dart';
import '../services/sync/webdav_sync_service.dart';
import '../utils/webdav_sync_schedule.dart';
import 'auth_provider.dart';
import 'automation_settings_provider.dart';
import 'backup_provider.dart';
import 'blacklist_provider.dart';
import 'pinned_threads_provider.dart';
import 'reading_history_provider.dart';
import 'settings_provider.dart';
import 'talker_provider.dart';

export '../models/webdav_config.dart';
export '../services/sync/webdav_sync_service.dart' show WebDavSyncFailureKind;

final webDavClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

final webDavCredentialsStoreProvider =
    Provider((ref) => WebDavCredentialsStore());

class WebDavConfigNotifier extends AsyncNotifier<WebDavConfig?> {
  @override
  Future<WebDavConfig?> build() =>
      ref.read(webDavCredentialsStoreProvider).read();

  Future<void> save(WebDavConfig config) async {
    config.directoryUri; // 校验后才写安全存储。
    final oldTarget = state.asData?.value?.targetId;
    await ref.read(webDavCredentialsStoreProvider).write(config);
    if (!ref.mounted) return;
    if (oldTarget != config.targetId) {
      await ref
          .read(settingsStoreProvider)
          .putAsync(WebDavSyncService.baselineKey, null);
      await ref
          .read(settingsStoreProvider)
          .putAsync('webdav_last_success', null);
      await ref.read(settingsStoreProvider).putAsync('webdav_auto_state', null);
    }
    if (ref.mounted) {
      state = AsyncData(config);
      ref
          .read(webDavSyncProvider.notifier)
          .configurationChanged(resetTarget: oldTarget != config.targetId);
    }
  }

  Future<void> clear() async {
    await ref.read(automationSettingsProvider.notifier).setSyncOnStartup(false);
    await ref.read(webDavCredentialsStoreProvider).clear();
    await ref
        .read(settingsStoreProvider)
        .putAsync(WebDavSyncService.baselineKey, null);
    await ref.read(settingsStoreProvider).putAsync('webdav_last_success', null);
    await ref.read(settingsStoreProvider).putAsync('webdav_auto_state', null);
    if (ref.mounted) {
      state = const AsyncData(null);
      ref
          .read(webDavSyncProvider.notifier)
          .configurationChanged(resetTarget: true);
    }
  }
}

final webDavConfigProvider =
    AsyncNotifierProvider<WebDavConfigNotifier, WebDavConfig?>(
  WebDavConfigNotifier.new,
);

class WebDavSyncState {
  const WebDavSyncState({
    this.isSyncing = false,
    this.lastSuccess,
    this.error,
    this.hasPendingChanges = false,
    this.nextAttempt,
    this.isPaused = false,
    this.hasDeferredRefresh = false,
  });
  final bool isSyncing;
  final DateTime? lastSuccess;
  final String? error;
  final bool hasPendingChanges;
  final DateTime? nextAttempt;
  final bool isPaused;
  final bool hasDeferredRefresh;
}

final webDavSyncServiceProvider = Provider(
  (ref) => WebDavSyncService(
    ref.watch(httpClientProvider),
    ref.watch(localDataProvider),
    ref.watch(s1BackupServiceProvider),
  ),
);

class WebDavSyncNotifier extends Notifier<WebDavSyncState> {
  Timer? _timer;
  bool _started = false;
  bool _foreground = true;
  bool _startupPending = false;
  bool _remoteCheckPending = false;
  bool _blocked = false;
  bool _deferredRefresh = false;
  DateTime? _backgroundAt;
  DateTime? _lastAttempt;
  DateTime? _lastSuccess;
  int _networkFailures = 0;
  final Map<Object, bool> _readers = {};

  DateTime get _now => ref.read(webDavClockProvider)();
  bool get _smart => ref.read(automationSettingsProvider).syncWhileUsing;
  bool get _automaticEnabled =>
      ref.read(automationSettingsProvider).syncMode != WebDavAutoSyncMode.off;

  @override
  WebDavSyncState build() {
    final store = ref.read(settingsStoreProvider);
    _lastSuccess =
        DateTime.tryParse(store.get<String>('webdav_last_success') ?? '');
    final saved = store.get<Object>('webdav_auto_state');
    if (saved is Map) {
      _lastAttempt = DateTime.tryParse('${saved['lastAttempt'] ?? ''}');
      _networkFailures = (saved['networkFailures'] as num?)?.toInt() ?? 0;
      _blocked = saved['blocked'] == true;
      _remoteCheckPending = saved['remoteCheckPending'] == true;
    }
    _lastAttempt ??= _lastSuccess;
    final changes = ref.read(localDataProvider).syncChanges.listen((_) {
      if (!ref.mounted) return;
      _publish();
      _schedule();
    });
    ref.listen(automationSettingsProvider, (previous, next) {
      if (previous?.syncMode == next.syncMode) return;
      if (next.syncMode == WebDavAutoSyncMode.off) _startupPending = false;
      if (next.syncWhileUsing) _remoteCheckPending = true;
      scheduleMicrotask(() {
        if (!ref.mounted) return;
        _publish();
        _schedule();
      });
    });
    ref.listen(webDavConfigProvider, (_, __) => _schedule());
    ref.onDispose(() {
      _timer?.cancel();
      unawaited(changes.cancel());
    });
    return WebDavSyncState(
      lastSuccess: _lastSuccess,
      isPaused: _blocked,
      hasPendingChanges: ref.read(localDataProvider).hasPendingSyncChanges,
      error: saved is Map ? saved['error'] as String? : null,
    );
  }

  /// 冷启动只安排一次，所有自动入口共用同一时钟和锁。
  void start() {
    if (_started) return;
    _started = true;
    _startupPending = ref.read(automationSettingsProvider).syncOnStartup;
    if (_startupPending) _remoteCheckPending = true;
    _schedule();
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      _backgroundAt = _now;
      _timer?.cancel();
      return;
    }
    if (_smart &&
        _backgroundAt != null &&
        _now.difference(_backgroundAt!) >= WebDavSyncSchedule.resumeThreshold) {
      _remoteCheckPending = true;
    }
    _schedule();
  }

  /// Screen 仅报告会话/滚动状态；调度及数据刷新留在 provider。
  void enterReading(Object session) {
    _readers[session] = true;
    _timer?.cancel();
  }

  void setReadingBusy(Object session, bool busy) {
    if (!_readers.containsKey(session) || _readers[session] == busy) return;
    _readers[session] = busy;
    _schedule();
  }

  void leaveReading(Object session) {
    _readers.remove(session);
    scheduleMicrotask(() async {
      if (!ref.mounted) return;
      if (_readers.isEmpty && _deferredRefresh) {
        _deferredRefresh = false;
        await _refreshProviders();
        if (!ref.mounted) return;
        _publish();
      }
      _schedule();
    });
  }

  void configurationChanged({required bool resetTarget}) {
    _blocked = false;
    _networkFailures = 0;
    _remoteCheckPending = true;
    if (resetTarget) {
      _lastAttempt = null;
      _lastSuccess = null;
    }
    _publish(keepError: false);
    _persistSchedule();
    _schedule();
  }

  void _persistSchedule() {
    ref.read(settingsStoreProvider).put('webdav_auto_state', {
      'lastAttempt': _lastAttempt?.toUtc().toIso8601String(),
      'networkFailures': _networkFailures,
      'blocked': _blocked,
      'remoteCheckPending': _remoteCheckPending,
      'error': state.error,
    });
  }

  void _publish({bool? syncing, String? error, bool keepError = true}) {
    state = WebDavSyncState(
      isSyncing: syncing ?? state.isSyncing,
      lastSuccess: _lastSuccess,
      error: keepError && error == null ? state.error : error,
      hasPendingChanges: ref.read(localDataProvider).hasPendingSyncChanges ||
          _remoteCheckPending,
      nextAttempt: !_blocked && _smart
          ? WebDavSyncSchedule.nextAttempt(_lastAttempt, _networkFailures)
          : null,
      isPaused: _blocked,
      hasDeferredRefresh: _deferredRefresh,
    );
  }

  void _schedule() {
    _timer?.cancel();
    if (!ref.mounted ||
        !_started ||
        !_foreground ||
        state.isSyncing ||
        _blocked) {
      return;
    }
    if (!_automaticEnabled || (!_smart && !_startupPending)) return;
    if (ref.read(webDavConfigProvider).asData?.value == null) return;
    if (!ref.read(localDataProvider).hasPendingSyncChanges &&
        !_remoteCheckPending) {
      return;
    }
    if (_readers.values.any((busy) => busy)) return;
    final due = WebDavSyncSchedule.nextAttempt(_lastAttempt, _networkFailures);
    final remaining = due?.difference(_now) ?? Duration.zero;
    final wait = remaining > WebDavSyncSchedule.idleDelay
        ? remaining
        : WebDavSyncSchedule.idleDelay;
    _timer = Timer(wait, () {
      if (!ref.mounted) return;
      unawaited(sync(automatic: true));
    });
  }

  Future<void> _refreshProviders() async {
    ref.invalidate(settingsProvider);
    ref.invalidate(readingHistoryProvider);
    ref.invalidate(blacklistProvider);
    ref.invalidate(pinnedThreadsProvider);
    await ref.read(settingsProvider.notifier).syncAppIconWithNative();
  }

  Future<void> sync({bool automatic = false}) async {
    if (state.isSyncing) return;
    if (automatic &&
        (!_automaticEnabled ||
            !_foreground ||
            _blocked ||
            (!_smart && !_startupPending) ||
            _readers.values.any((busy) => busy))) {
      return;
    }
    final due = WebDavSyncSchedule.nextAttempt(_lastAttempt, _networkFailures);
    if (automatic && due != null && _now.isBefore(due)) {
      _schedule();
      return;
    }
    _timer?.cancel();
    _startupPending = false;
    _lastAttempt = _now;
    _remoteCheckPending = true;
    final revision = ref.read(localDataProvider).syncRevision;
    _publish(syncing: true, keepError: false);
    _persistSchedule();
    try {
      final config = await ref.read(webDavConfigProvider.future);
      if (config == null) throw const WebDavSyncException('请先配置 WebDAV');
      final info = await ref.read(packageInfoProvider.future);
      if (!ref.mounted) return;
      await ref.read(webDavSyncServiceProvider).synchronize(
            config: config,
            uid: ref.read(authStateProvider).user?.uid,
            packageInfo: info,
            platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
          );
      if (!ref.mounted) return;
      _deferredRefresh = _readers.isNotEmpty;
      if (!_deferredRefresh) await _refreshProviders();
      if (!ref.mounted) return;
      final now = _now;
      await ref
          .read(settingsStoreProvider)
          .putAsync('webdav_last_success', now.toUtc().toIso8601String());
      if (!ref.mounted) return;
      _lastSuccess = now;
      _lastAttempt = now;
      _networkFailures = 0;
      _blocked = false;
      _remoteCheckPending = false;
      ref.read(localDataProvider).markSyncCompleted(revision);
      _publish(syncing: false, keepError: false);
    } catch (e) {
      if (!ref.mounted) return;
      final message =
          e is WebDavSyncException ? e.message : '同步失败，请检查 WebDAV 配置及本机存储后重试';
      // 仅记录已脱敏文案，凭据和服务器地址不写日志。
      ref.read(talkerProvider).warning(message);
      final kind = e is WebDavSyncException
          ? e.kind
          : WebDavSyncFailureKind.configuration;
      _networkFailures =
          kind == WebDavSyncFailureKind.network ? _networkFailures + 1 : 0;
      _blocked = kind == WebDavSyncFailureKind.configuration;
      _publish(syncing: false, error: message);
    }
    if (!ref.mounted) return;
    _persistSchedule();
    _schedule();
  }
}

final webDavSyncProvider =
    NotifierProvider<WebDavSyncNotifier, WebDavSyncState>(
  WebDavSyncNotifier.new,
);
