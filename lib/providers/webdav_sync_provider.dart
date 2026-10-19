import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/webdav_config.dart';
import '../services/http_client.dart';
import '../services/sync/webdav_credentials_store.dart';
import '../services/sync/webdav_sync_service.dart';
import 'auth_provider.dart';
import 'automation_settings_provider.dart';
import 'backup_provider.dart';
import 'blacklist_provider.dart';
import 'pinned_threads_provider.dart';
import 'reading_history_provider.dart';
import 'settings_provider.dart';
import 'talker_provider.dart';

export '../models/webdav_config.dart';

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
      ref.invalidate(webDavSyncProvider);
    }
    if (ref.mounted) state = AsyncData(config);
  }

  Future<void> clear() async {
    await ref.read(automationSettingsProvider.notifier).setSyncOnStartup(false);
    await ref.read(webDavCredentialsStoreProvider).clear();
    await ref
        .read(settingsStoreProvider)
        .putAsync(WebDavSyncService.baselineKey, null);
    await ref.read(settingsStoreProvider).putAsync('webdav_last_success', null);
    ref.invalidate(webDavSyncProvider);
    if (ref.mounted) state = const AsyncData(null);
  }
}

final webDavConfigProvider =
    AsyncNotifierProvider<WebDavConfigNotifier, WebDavConfig?>(
  WebDavConfigNotifier.new,
);

class WebDavSyncState {
  const WebDavSyncState({this.isSyncing = false, this.lastSuccess, this.error});
  final bool isSyncing;
  final DateTime? lastSuccess;
  final String? error;
}

final webDavSyncServiceProvider = Provider(
  (ref) => WebDavSyncService(
    ref.watch(httpClientProvider),
    ref.watch(localDataProvider),
    ref.watch(s1BackupServiceProvider),
  ),
);

class WebDavSyncNotifier extends Notifier<WebDavSyncState> {
  @override
  WebDavSyncState build() {
    final raw =
        ref.read(settingsStoreProvider).get<String>('webdav_last_success');
    return WebDavSyncState(
      lastSuccess: raw == null ? null : DateTime.tryParse(raw),
    );
  }

  Future<void> sync() async {
    if (state.isSyncing) return;
    state = WebDavSyncState(isSyncing: true, lastSuccess: state.lastSuccess);
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
      ref.invalidate(settingsProvider);
      ref.invalidate(readingHistoryProvider);
      ref.invalidate(blacklistProvider);
      ref.invalidate(pinnedThreadsProvider);
      final now = DateTime.now();
      await ref
          .read(settingsStoreProvider)
          .putAsync('webdav_last_success', now.toIso8601String());
      if (!ref.mounted) return;
      state = WebDavSyncState(lastSuccess: now);
      await ref.read(settingsProvider.notifier).syncAppIconWithNative();
    } catch (e) {
      if (!ref.mounted) return;
      final message =
          e is WebDavSyncException ? e.message : '同步失败，请检查 WebDAV 配置及本机存储后重试';
      // 仅记录已脱敏文案，凭据和服务器地址不写日志。
      ref.read(talkerProvider).warning(message);
      state = WebDavSyncState(lastSuccess: state.lastSuccess, error: message);
    }
  }
}

final webDavSyncProvider =
    NotifierProvider<WebDavSyncNotifier, WebDavSyncState>(
  WebDavSyncNotifier.new,
);
