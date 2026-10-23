import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/widgets/s1_click_region.dart';
import 'package:s1er/widgets/s1_reading_swipe.dart';
import 'package:s1er/widgets/s1_swipe_pagination.dart';

import '../helpers/test_theme.dart';

Future<void> _pumpHarness(
  WidgetTester tester, {
  required List<int> requests,
  int currentPage = 2,
  int totalPages = 3,
  bool enabled = true,
  bool updatePage = true,
  Future<void>? pending,
  Future<void> Function()? onTerminalRefresh,
  Widget? content,
  ScrollController? controller,
  EdgeInsets systemGestureInsets = EdgeInsets.zero,
}) async {
  var page = currentPage;
  await tester.pumpWidget(
    wrapWithAppTheme(
      MediaQuery(
        data: MediaQueryData(
          size: tester.view.physicalSize / tester.view.devicePixelRatio,
          systemGestureInsets: systemGestureInsets,
        ),
        child: Center(
          child: SizedBox(
            width: 400,
            child: StatefulBuilder(
              builder: (context, setState) => S1SwipePagination(
                mode: S1SwipePaginationMode.smart,
                enabled: enabled,
                currentPage: page,
                totalPages: totalPages,
                onPageChanged: (next) async {
                  requests.add(next);
                  if (pending != null) await pending;
                  if (updatePage) setState(() => page = next);
                },
                onTerminalRefresh: onTerminalRefresh,
                pageBuilder: (context, scrollController) => ListView(
                  controller: controller ?? scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    content ??
                        SizedBox(height: 2200, child: Text('page $page')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Offset _start(WidgetTester tester) =>
    tester.getRect(find.byType(S1ReadingSwipe)).topCenter +
    const Offset(0, 250);

Future<void> _swipe(WidgetTester tester, Offset delta) async {
  await tester.dragFrom(_start(tester), delta);
  await tester.pumpAndSettle();
}

double _previewOffset(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const ValueKey('s1-reading-swipe-content')))
    .transform
    .storage[12];

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform commits only on release and resets new page to top',
      (tester) async {
        final requests = <int>[];
        await _pumpHarness(tester, requests: requests);
        expect(find.byType(PageView), findsNothing);

        final gesture = await tester.startGesture(_start(tester));
        await gesture.moveBy(
          const Offset(-130, 0),
          timeStamp: const Duration(milliseconds: 100),
        );
        await tester.pump();
        expect(requests, isEmpty);
        await gesture.up(timeStamp: const Duration(milliseconds: 120));
        await tester.pumpAndSettle();
        expect(requests, [3]);
        expect(find.text('page 3'), findsOneWidget);
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position
              .pixels,
          0,
        );
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('horizontal swipe tolerates small vertical finger jitter',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    await _swipe(tester, const Offset(-130, -6));
    expect(requests, [3]);
  });

  testWidgets('small threshold previews and incomplete swipe animates back',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    final gesture = await tester.startGesture(_start(tester));
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    expect(_previewOffset(tester), 0);
    await gesture.moveBy(const Offset(-30, -8));
    await tester.pump();
    expect(_previewOffset(tester), closeTo(-40, 0.01));
    expect(requests, isEmpty);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_previewOffset(tester), greaterThan(-40));
    expect(_previewOffset(tester), lessThan(0));
    await tester.pumpAndSettle();
    expect(_previewOffset(tester), 0);
    expect(requests, isEmpty);
  });

  testWidgets(
      'half-width swipes within 30 degrees work throughout both edge bands',
      (tester) async {
    final requests = <int>[];
    for (final startFraction in [0.001, 0.1, 0.2, 0.8, 0.9, 0.999]) {
      for (final angle in [-30, -15, 0, 15, 30]) {
        await tester.pumpWidget(const SizedBox.shrink());
        requests.clear();
        await _pumpHarness(tester, requests: requests);
        final rect = tester.getRect(find.byType(S1ReadingSwipe));
        final direction = startFraction < 0.5 ? 1 : -1;
        final start =
            Offset(rect.left + rect.width * startFraction, rect.top + 250);
        final delta = Offset(
          direction * rect.width / 2,
          rect.width / 2 * math.tan(angle * math.pi / 180),
        );
        final position =
            tester.state<ScrollableState>(find.byType(Scrollable)).position;
        await tester.timedDragFrom(
          start,
          delta,
          const Duration(milliseconds: 400),
        );
        await tester.pumpAndSettle();
        expect(
          requests,
          [direction > 0 ? 1 : 3],
          reason: 'start=$startFraction angle=$angle',
        );
        // 横向胜出后不能让正文跟着 dy 滚动。
        expect(position.pixels, 0);
      }
    }
  });

  testWidgets('short fling and withdrawn drag keep current page',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    await tester.flingFrom(_start(tester), const Offset(-60, 0), 2500);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    final gesture = await tester.startGesture(_start(tester));
    await gesture.moveBy(const Offset(-150, 0));
    await gesture.moveBy(const Offset(130, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets('diagonal swipe scrolls content without pagination',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    await _swipe(tester, const Offset(-150, -200));
    expect(requests, isEmpty);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
  });

  testWidgets('vertical start stays locked when finger turns horizontal',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    final gesture = await tester.startGesture(_start(tester));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(-180, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets('touch stopping vertical inertia cannot paginate',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    await tester.flingFrom(_start(tester), const Offset(0, -300), 1500);
    await tester.pump(const Duration(milliseconds: 30));
    await _swipe(tester, const Offset(-150, 0));
    expect(requests, isEmpty);
    await _swipe(tester, const Offset(-150, 0));
    expect(requests, [3]);
  });

  testWidgets('multi touch and cancellation cannot paginate', (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    final first = await tester.startGesture(_start(tester), pointer: 1);
    final second = await tester
        .startGesture(_start(tester) + const Offset(40, 0), pointer: 2);
    await second.up();
    await first.moveBy(const Offset(-150, 0));
    await first.up();
    expect(requests, isEmpty);
    final canceled = await tester.startGesture(_start(tester));
    await canceled.moveBy(const Offset(-150, 0));
    await canceled.cancel();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets('mouse selection and long press drag cannot paginate',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    final mouse = await tester.startGesture(
      _start(tester),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-150, 0));
    await mouse.up();
    final held = await tester.startGesture(_start(tester));
    await tester.pump(kLongPressTimeout);
    await held.moveBy(const Offset(-150, 0), timeStamp: kLongPressTimeout);
    await held.up(
      timeStamp: kLongPressTimeout + const Duration(milliseconds: 30),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets('blocked content keeps taps and yields vertical scrolling',
      (tester) async {
    final requests = <int>[];
    var taps = 0;
    await _pumpHarness(
      tester,
      requests: requests,
      content: S1ReadingSwipeBlocker(
        child: S1ClickRegion(
          onTap: () => taps++,
          child:
              const SizedBox(height: 2200, child: Text('interactive content')),
        ),
      ),
    );
    await tester.tapAt(_start(tester));
    expect(taps, 1);
    await _swipe(tester, const Offset(-150, 0));
    expect(requests, isEmpty);
    await _swipe(tester, const Offset(0, -150));
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
  });

  testWidgets('nested horizontal scroll consumes the gesture', (tester) async {
    final requests = <int>[];
    final inner = ScrollController();
    addTearDown(inner.dispose);
    await _pumpHarness(
      tester,
      requests: requests,
      content: SizedBox(
        height: 500,
        child: SingleChildScrollView(
          controller: inner,
          scrollDirection: Axis.horizontal,
          child: const SizedBox(width: 1600, child: Text('wide table')),
        ),
      ),
    );
    await _swipe(tester, const Offset(-150, 0));
    expect(inner.offset, greaterThan(0));
    expect(requests, isEmpty);
  });

  testWidgets('explicit selection notification cancels current candidate',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    final gesture = await tester.startGesture(_start(tester));
    await gesture.moveBy(const Offset(-130, 0));
    S1ReadingSwipeBlockNotification()
        .dispatch(tester.element(find.byType(ListView)));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets('paging in flight ignores subsequent swipes', (tester) async {
    final requests = <int>[];
    final pending = Completer<void>();
    await _pumpHarness(tester, requests: requests, pending: pending.future);
    await tester.dragFrom(_start(tester), const Offset(-150, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(requests, [3]);
    await tester.dragFrom(_start(tester), const Offset(-150, 0));
    expect(requests, [3]);
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('failed page request preserves current reading offset',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests, updatePage: false);
    await _swipe(tester, const Offset(0, -200));
    final before =
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    await _swipe(tester, const Offset(-150, 0));
    expect(requests, [3]);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      before,
    );
    expect(find.text('page 2'), findsOneWidget);
  });

  testWidgets('last page refresh requires bottom and a committed swipe',
      (tester) async {
    final requests = <int>[];
    var refreshes = 0;
    await _pumpHarness(
      tester,
      requests: requests,
      currentPage: 3,
      onTerminalRefresh: () async => refreshes++,
    );
    await _swipe(tester, const Offset(-150, 0));
    expect(refreshes, 0);
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    await _swipe(tester, const Offset(-40, 0));
    expect(refreshes, 0);
    await _swipe(tester, const Offset(-150, 0));
    expect(refreshes, 1);
    expect(requests, isEmpty);
  });

  testWidgets('single page and disabled reader never request another page',
      (tester) async {
    final requests = <int>[];
    var refreshes = 0;
    await _pumpHarness(
      tester,
      requests: requests,
      currentPage: 1,
      totalPages: 1,
      content: const SizedBox(height: 100, child: Text('short thread')),
      onTerminalRefresh: () async => refreshes++,
    );
    await _swipe(tester, const Offset(-150, 0));
    expect(refreshes, 1);
    expect(requests, isEmpty);
    await _pumpHarness(tester, requests: requests, enabled: false);
    await _swipe(tester, const Offset(-150, 0));
    expect(requests, isEmpty);
  });

  testWidgets('right swipe requests previous page and first page stays bounded',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    await _swipe(tester, const Offset(150, 0));
    expect(requests, [1]);
    await _swipe(tester, const Offset(150, 0));
    expect(requests, [1]);
  });

  testWidgets('edge events delivered by the system can paginate',
      (tester) async {
    final directions = <int>[];
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.pumpWidget(
      wrapWithAppTheme(
        MediaQuery(
          data: MediaQueryData(
            size: size,
            systemGestureInsets: const EdgeInsets.symmetric(horizontal: 20),
          ),
          child: S1ReadingSwipe(
            onSwipe: directions.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.dragFrom(Offset(10, size.height / 2), const Offset(250, 0));
    await tester.pumpAndSettle();
    await tester.dragFrom(
      Offset(size.width - 10, size.height / 2),
      const Offset(-250, 0),
    );
    await tester.pumpAndSettle();
    expect(directions, [-1, 1]);
    await tester.dragFrom(size.center(Offset.zero), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(directions, [-1, 1, 1]);
  });

  testWidgets('ordinary tappable content supports taps and angled pagination',
      (tester) async {
    final requests = <int>[];
    var taps = 0;
    await _pumpHarness(
      tester,
      requests: requests,
      content: S1ClickRegion(
        onTap: () => taps++,
        child:
            const SizedBox(height: 2200, child: Text('tappable post header')),
      ),
    );
    await tester.tapAt(_start(tester));
    expect(taps, 1);
    await tester.timedDragFrom(
      _start(tester),
      const Offset(-160, -85),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(requests, [3]);
    expect(taps, 1);
  });

  testWidgets(
      'multi touch after preview rolls back and does not poison next swipe',
      (tester) async {
    final requests = <int>[];
    await _pumpHarness(tester, requests: requests);
    final first = await tester.startGesture(_start(tester), pointer: 1);
    await first.moveBy(const Offset(-50, 0));
    await tester.pump();
    expect(_previewOffset(tester), lessThan(0));
    final second = await tester
        .startGesture(_start(tester) + const Offset(30, 0), pointer: 2);
    await second.up();
    await first.moveBy(const Offset(-80, 0));
    await first.up();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(_previewOffset(tester), 0);
    await _swipe(tester, const Offset(-130, -30));
    expect(requests, [3]);
  });
}
