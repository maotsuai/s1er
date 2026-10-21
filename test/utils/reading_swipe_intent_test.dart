import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/utils/reading_swipe_intent.dart';

void main() {
  late ReadingSwipeIntent intent;

  void move(double x, double y, {int ms = 100}) => intent.update(
        x: x,
        y: y,
        time: Duration(milliseconds: ms),
      );

  int? release(double x, double y, {double width = 400}) => intent.end(
        x: x,
        y: y,
        time: const Duration(milliseconds: 200),
        width: width,
      );

  setUp(() {
    intent = ReadingSwipeIntent()
      ..begin(x: 0, y: 0, time: Duration.zero, touchSlop: 18);
  });

  test('horizontal displacement commits only once, in either direction', () {
    move(-100, 5);
    expect(release(-100, 5), 1);
    expect(release(-100, 5), isNull);
    intent.begin(x: 0, y: 0, time: Duration.zero, touchSlop: 18);
    move(100, 5);
    expect(release(100, 5), -1);
  });

  test('short fast swipe never bypasses width threshold', () {
    move(-60, 0, ms: 10);
    expect(release(-60, 0), isNull);
  });

  test('threshold is based on pane width, not full screen width', () {
    move(-87, 0);
    expect(release(-87, 0), isNull);
    intent.begin(x: 0, y: 0, time: Duration.zero, touchSlop: 18);
    move(-88, 0);
    expect(release(-88, 0), 1);
  });

  test('vertical intent is irrevocable even after a long horizontal move', () {
    move(10, 30);
    move(-200, 30);
    expect(release(-200, 30), isNull);
  });

  test('ambiguous diagonal movement favors reading', () {
    move(-100, 70);
    expect(release(-100, 70), isNull);
  });

  test('initial jitter below slop does not prevent deliberate horizontal swipe',
      () {
    move(4, 10);
    move(-100, 15);
    expect(release(-100, 15), 1);
  });

  test('returning below threshold or reversing cancels commit', () {
    move(-130, 0);
    expect(release(-40, 0), isNull);
    intent.begin(x: 0, y: 0, time: Duration.zero, touchSlop: 18);
    move(-130, 0);
    expect(release(130, 0), isNull);
  });

  test('horizontal lock still requires horizontal intent at release', () {
    move(-40, 0);
    expect(release(-100, 150), isNull);
  });

  test('long press before movement cannot turn into pagination', () {
    move(-150, 0, ms: 500);
    expect(release(-150, 0), isNull);
  });

  test('slow deliberate drag remains valid after intent is locked', () {
    move(-30, 0);
    expect(
      intent.end(x: -100, y: 0, time: const Duration(seconds: 2), width: 400),
      1,
    );
  });

  test('system touch slop is respected even in narrow panes', () {
    intent.begin(x: 0, y: 0, time: Duration.zero, touchSlop: 50);
    move(-45, 0);
    expect(release(-45, 0, width: 100), isNull);
  });

  test('cancel and pointer up without movement never commit', () {
    expect(release(-100, 0), isNull);
    move(-100, 0);
    intent.cancel();
    expect(release(-100, 0), isNull);
  });

  test('invalid viewport width never commits', () {
    move(-100, 0);
    expect(release(-100, 0, width: double.infinity), isNull);
  });
}
