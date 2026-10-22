import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/providers/webdav_sync_provider.dart';
import 'package:s1er/widgets/webdav_sync_button.dart';

import '../helpers/test_theme.dart';

class _Config extends WebDavConfigNotifier {
  @override
  Future<WebDavConfig?> build() async => const WebDavConfig(
        directoryUrl: 'https://dav.example.com/',
        username: 'test',
        password: 'private-secret',
      );
}

class _Sync extends WebDavSyncNotifier {
  @override
  WebDavSyncState build() => WebDavSyncState(
        error: '网络暂时不可用',
        hasPendingChanges: true,
        lastSuccess: DateTime(2026, 10, 22, 12),
        nextAttempt: DateTime(2026, 10, 22, 12, 7),
      );

  @override
  Future<void> sync({bool automatic = false}) async {
    state = WebDavSyncState(lastSuccess: DateTime(2026, 10, 22, 12, 7));
  }
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('status, error, manual retry and dismiss on $platform',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = platform == TargetPlatform.android
          ? const Size(360, 800)
          : const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            webDavConfigProvider.overrideWith(_Config.new),
            webDavSyncProvider.overrideWith(_Sync.new),
          ],
          child: wrapWithAppTheme(
            const Align(
              alignment: Alignment.topRight,
              child: WebDavSyncButton(),
            ),
            dark: platform == TargetPlatform.windows,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      await tester.tap(find.byTooltip('同步失败，点击查看'));
      await tester.pumpAndSettle();
      expect(find.text('网络暂时不可用'), findsOneWidget);
      expect(find.textContaining('下次可同步'), findsOneWidget);
      expect(find.textContaining('private-secret'), findsNothing);
      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();
      expect(find.text('本机改动已同步'), findsOneWidget);
      expect(find.text('同步成功'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
