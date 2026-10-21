import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../utils/reading_swipe_intent.dart';

/// 内容交互取消本次翻页候选；pointer 可标识先于外层收到的 down。
class S1ReadingSwipeBlockNotification extends Notification {
  S1ReadingSwipeBlockNotification({this.pointer});

  final int? pointer;
}

/// 图片、按钮等内容拥有触摸优先权，不参与外层被动翻页。
class S1ReadingSwipeBlocker extends StatelessWidget {
  const S1ReadingSwipeBlocker({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) =>
          S1ReadingSwipeBlockNotification(pointer: event.pointer)
              .dispatch(context),
      child: child,
    );
  }
}

/// 观察原始触摸，不加入 Gesture Arena，不阻挡正文原有滚动/选字手势。
class S1ReadingSwipe extends StatefulWidget {
  const S1ReadingSwipe({
    super.key,
    required this.child,
    required this.onSwipe,
    this.enabled = true,
  });

  final Widget child;
  final ValueChanged<int> onSwipe;
  final bool enabled;

  @override
  State<S1ReadingSwipe> createState() => _S1ReadingSwipeState();
}

class _S1ReadingSwipeState extends State<S1ReadingSwipe> {
  final _intent = ReadingSwipeIntent();
  final _pointers = <int>{};
  final _blockedPointers = <int>{};
  int? _primaryPointer;
  bool _contentScrolling = false;
  double _verticalScrollDistance = 0;
  double _touchSlop = ReadingSwipeIntent.minimumIntentDistance;
  Timer? _scrollIdleTimer;

  @override
  void didUpdateWidget(covariant S1ReadingSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _intent.cancel();
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    // 包含所有 depth 和方向：引用、代码、表格等内部滚动同样取消翻页。
    if (notification is ScrollStartNotification) {
      _scrollIdleTimer?.cancel();
      _contentScrolling = true;
      // 没有横向竞争者时，竖向 Drag 可能默认获胜并立即发送 start，
      // 此时还没有任何竖向位移。主动拖动等 update/overscroll 再取消；
      // 非触摸滚动（惯性/程序滚动）仍立即取消。
      if (notification.dragDetails == null) _intent.cancel();
    } else if ((notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) != 0) ||
        (notification is OverscrollNotification &&
            notification.overscroll != 0)) {
      _scrollIdleTimer?.cancel();
      _contentScrolling = true;
      final delta = notification is ScrollUpdateNotification
          ? notification.scrollDelta!
          : (notification as OverscrollNotification).overscroll;
      final isDrag = notification is ScrollUpdateNotification
          ? notification.dragDetails != null
          : (notification as OverscrollNotification).dragDetails != null;
      if (_primaryPointer != null &&
          notification.depth == 0 &&
          notification.metrics.axis == Axis.vertical &&
          isDrag) {
        // 默认获胜的竖向识别器也会把横滑中的微小纵向抖动传给列表。
        // 容忍 slop 内抖动；真正竖读和嵌套内容滚动仍永久取消候选。
        _verticalScrollDistance += delta.abs();
        if (_verticalScrollDistance <= _touchSlop) return false;
      }
      _intent.cancel();
    } else if (notification is ScrollEndNotification) {
      // 按下可能先让 ListView 停止惯性，再传到外层 Listener；保留短暂
      // scrolling 状态，确保「点停惯性后顺手一划」也不触发翻页。
      _scrollIdleTimer?.cancel();
      _scrollIdleTimer = Timer(const Duration(milliseconds: 80), () {
        _contentScrolling = false;
      });
    }
    return false;
  }

  bool _onBlock(S1ReadingSwipeBlockNotification notification) {
    final pointer = notification.pointer;
    if (pointer != null) _blockedPointers.add(pointer);
    _intent.cancel();
    return true;
  }

  void _onDown(PointerDownEvent event, EdgeInsets systemInsets) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      _intent.cancel();
      return;
    }
    _primaryPointer = event.pointer;
    _verticalScrollDistance = 0;
    final systemSlop =
        MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? kTouchSlop;
    _touchSlop = systemSlop > ReadingSwipeIntent.minimumIntentDistance
        ? systemSlop
        : ReadingSwipeIntent.minimumIntentDistance;
    _intent.begin(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      time: event.timeStamp,
      touchSlop: _touchSlop,
    );
    if (!widget.enabled ||
        _contentScrolling ||
        _blockedPointers.contains(event.pointer) ||
        event.kind != PointerDeviceKind.touch ||
        event.buttons != kPrimaryButton ||
        (systemInsets.left > 0 && event.position.dx <= systemInsets.left) ||
        (systemInsets.right > 0 &&
            event.position.dx >=
                MediaQuery.sizeOf(context).width - systemInsets.right)) {
      _intent.cancel();
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _primaryPointer) return;
    _intent.update(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      time: event.timeStamp,
    );
  }

  void _onUp(PointerUpEvent event, double width) {
    int? direction;
    if (event.pointer == _primaryPointer && widget.enabled) {
      direction = _intent.end(
        x: event.localPosition.dx,
        y: event.localPosition.dy,
        time: event.timeStamp,
        width: width,
      );
    }
    _removePointer(event.pointer);
    if (direction != null) widget.onSwipe(direction);
  }

  void _removePointer(int pointer) {
    _pointers.remove(pointer);
    _blockedPointers.remove(pointer);
    if (_primaryPointer == pointer) {
      _primaryPointer = null;
      _intent.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final systemInsets = MediaQuery.systemGestureInsetsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return NotificationListener<S1ReadingSwipeBlockNotification>(
          onNotification: _onBlock,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) => _onDown(event, systemInsets),
              onPointerMove: _onMove,
              onPointerUp: (event) => _onUp(event, constraints.maxWidth),
              onPointerCancel: (event) => _removePointer(event.pointer),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
