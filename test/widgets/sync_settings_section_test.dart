import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/providers/auth_provider.dart';
import 'package:s1er/providers/automation_settings_provider.dart';
import 'package:s1er/providers/settings_provider.dart';
import 'package:s1er/providers/webdav_sync_provider.dart';
import 'package:s1er/services/sync/webdav_credentials_store.dart';
import 'package:s1er/widgets/settings/sync_settings_section.dart';

import '../helpers/test_local_data.dart';
import '../helpers/test_theme.dart';

class _Credentials extends WebDavCredentialsStore {
  WebDavConfig? config;
  @override
  Future<WebDavConfig?> read() async => config;
  @override
  Future<void> write(WebDavConfig value) async {
    config = value;
  }

  @override
  Future<void> clear() async {
    config = null;
  }
}

class _Guest extends AuthNotifier {
  @override
  AuthState build() => AuthState();
}

class _IdleSync extends WebDavSyncNotifier {
  @override
  WebDavSyncState build() => const WebDavSyncState();
}

void main() {
  testWidgets(
      'configure, persist switches and remove connection on compact screen',
      (tester) async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    final credentials = _Credentials();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDataProvider.overrideWithValue(local),
          authStateProvider.overrideWith(_Guest.new),
          webDavCredentialsStoreProvider.overrideWithValue(credentials),
          webDavSyncProvider.overrideWith(_IdleSync.new),
        ],
        child: wrapWithAppTheme(
          const SingleChildScrollView(child: SyncSettingsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final syncMode = find.byType(DropdownButton<WebDavAutoSyncMode>);
    expect(
      tester.widget<DropdownButton<WebDavAutoSyncMode>>(syncMode).onChanged,
      isNull,
    );
    await tester.tap(find.text('WebDAV 连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入目录地址'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'https://dav.example.com/s1er/');
    await tester.enterText(fields.at(1), 'user');
    await tester.enterText(fields.at(2), 'secret-password');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(credentials.config?.username, 'user');
    expect(find.textContaining('secret-password'), findsNothing);
    expect(
      tester.widget<DropdownButton<WebDavAutoSyncMode>>(syncMode).onChanged,
      isNotNull,
    );
    await tester.ensureVisible(syncMode);
    await tester.tap(syncMode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('智能同步').last);
    await tester.pumpAndSettle();
    expect(local.settings.get<bool>('webdav_sync_on_startup'), isTrue);
    expect(local.settings.get<bool>('webdav_sync_while_using'), isTrue);
    final signSwitch = find.widgetWithText(SwitchListTile, '自动签到');
    await tester.ensureVisible(signSwitch);
    await tester.tap(signSwitch);
    await tester.pumpAndSettle();
    expect(local.settings.get<bool>('auto_daily_sign'), isTrue);
    await tester.ensureVisible(find.text('移除 WebDAV 连接'));
    await tester.tap(find.text('移除 WebDAV 连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(credentials.config, isNull);
    expect(local.settings.get<bool>('webdav_sync_on_startup'), isFalse);
    expect(local.settings.get<bool>('webdav_sync_while_using'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid directory URL stays in dialog without saving',
      (tester) async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    final credentials = _Credentials();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDataProvider.overrideWithValue(local),
          authStateProvider.overrideWith(_Guest.new),
          webDavCredentialsStoreProvider.overrideWithValue(credentials),
          webDavSyncProvider.overrideWith(_IdleSync.new),
        ],
        child: wrapWithAppTheme(
          const SingleChildScrollView(child: SyncSettingsSection()),
          dark: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('WebDAV 连接'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'https://user:pass@dav.example.com/');
    await tester.enterText(fields.at(1), 'user');
    await tester.enterText(fields.at(2), 'password');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(credentials.config, isNull);
    expect(find.textContaining('请输入有效的 WebDAV 目录地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
