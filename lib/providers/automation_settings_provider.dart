import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/settings_store.dart';
import 'settings_provider.dart';

enum WebDavAutoSyncMode { off, startup, smart }

class AutomationSettings {
  const AutomationSettings({
    this.syncOnStartup = false,
    this.syncWhileUsing = false,
    this.autoSign = false,
  });
  final bool syncOnStartup;
  final bool syncWhileUsing;
  final bool autoSign;
  WebDavAutoSyncMode get syncMode => syncWhileUsing
      ? WebDavAutoSyncMode.smart
      : syncOnStartup
          ? WebDavAutoSyncMode.startup
          : WebDavAutoSyncMode.off;
}

/// 自动执行属于本机授权，不随普通备份传播到其他设备。
class AutomationSettingsNotifier extends Notifier<AutomationSettings> {
  AutomationSettingsNotifier({this.initial});
  final AutomationSettings? initial;

  SettingsStore get _store => ref.read(settingsStoreProvider);

  @override
  AutomationSettings build() {
    if (initial != null) return initial!;
    return AutomationSettings(
      syncOnStartup: _store.get<bool>('webdav_sync_on_startup') ?? false,
      syncWhileUsing: _store.get<bool>('webdav_sync_while_using') ?? false,
      autoSign: _store.get<bool>('auto_daily_sign') ?? false,
    );
  }

  Future<void> setSyncOnStartup(bool value) async {
    await setSyncMode(
      value ? WebDavAutoSyncMode.startup : WebDavAutoSyncMode.off,
    );
  }

  Future<void> setSyncMode(WebDavAutoSyncMode mode) async {
    final startup = mode != WebDavAutoSyncMode.off;
    final smart = mode == WebDavAutoSyncMode.smart;
    await _store.putAsync('webdav_sync_on_startup', startup);
    await _store.putAsync('webdav_sync_while_using', smart);
    if (ref.mounted) {
      state = AutomationSettings(
        syncOnStartup: startup,
        syncWhileUsing: smart,
        autoSign: state.autoSign,
      );
    }
  }

  Future<void> setAutoSign(bool value) async {
    await _store.putAsync('auto_daily_sign', value);
    if (ref.mounted) {
      state = AutomationSettings(
        syncOnStartup: state.syncOnStartup,
        syncWhileUsing: state.syncWhileUsing,
        autoSign: value,
      );
    }
  }
}

final automationSettingsProvider =
    NotifierProvider<AutomationSettingsNotifier, AutomationSettings>(
  AutomationSettingsNotifier.new,
);
