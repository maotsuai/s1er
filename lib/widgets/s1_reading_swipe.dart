import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../utils/reading_swipe_intent.dart';

/// 内容交互取消本次翻页候选；pointer 标识先于外层收到的 down。
class S1ReadingSwipeBlockNotification extends Notification {
  S1ReadingSwipeBlockNotification({this.pointer});

  final int? pointer;
}

/// 用于图片缩放等拥有横向手势的内容；普通点击区域无需阻止翻页。
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

/// 方向识别参与 Gesture Arena，跟手预览与松手后的翻页提交各用独立阈值。
class S1ReadingSwipe extends StatefulWidget {
  const S1ReadingSwipe({
    super.key,
    required this.child,
    required this.onSwipe,
    this.enabled = true,
    this.canSwipeToPrevious = true,
    this.canSwipeToNext = true,
    this.previousPreview,
    this.nextPreview,
  });

  final Widget child;
  final FutureOr<void> Function(int direction) onSwipe;
  final bool enabled;
  final bool canSwipeToPrevious;
  final bool canSwipeToNext;
  final Widget? previousPreview;
  final Widget? nextPreview;

  @override
  State<S1ReadingSwipe> createState() => _S1ReadingSwipeState();
}

class _S1ReadingSwipeState extends State<S1ReadingSwipe>
    with SingleTickerProviderStateMixin {
  final _intent = ReadingSwipeIntent();
  final _pointers = <int>{};
  final _blockedPointers = <int>{};
  late final AnimationController _offset;
  _ReadingDragRecognizer? _recognizer;
  bool _contentScrolling = false;
  bool _settling = false;
  Timer? _scrollIdleTimer;
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _offset = AnimationController.unbounded(vsync: this);
  }

  @override
  void didUpdateWidget(covariant S1ReadingSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 自己提交后的加载会暂时 disabled，保持邻页预览直到数据返回。
    if (!widget.enabled && !_settling) _cancelGesture();
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    _offset.dispose();
    super.dispose();
  }

  void _cancelGesture() {
    _intent.cancel();
    if (!_settling && _offset.value != 0) unawaited(_restore());
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _scrollIdleTimer?.cancel();
      _contentScrolling = true;
      _cancelGesture();
    } else if (notification is ScrollEndNotification) {
      // 按下会先让列表停止惯性，短暂保留标记，避免点停后误翻页。
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
    _cancelGesture();
    return true;
  }

  bool _canStart(PointerDownEvent event) =>
      widget.enabled &&
      !_settling &&
      !_contentScrolling &&
      _pointers.isEmpty &&
      !_blockedPointers.contains(event.pointer) &&
      event.kind == PointerDeviceKind.touch &&
      event.buttons == kPrimaryButton;

  void _onDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length > 1) _cancelGesture();
  }

  void _removePointer(int pointer) {
    _pointers.remove(pointer);
    _blockedPointers.remove(pointer);
  }

  bool _canTravel(int direction) =>
      direction < 0 ? widget.canSwipeToPrevious : widget.canSwipeToNext;

  void _onDragUpdate() {
    if (!_intent.isHorizontal || _settling) return;
    final dx = _intent.horizontalDelta.clamp(-_width, _width).toDouble();
    // 首尾页轻微阻尼，松手回弹；不把不存在的页面拖进来。
    final direction = dx < 0 ? 1 : -1;
    _offset.value = _canTravel(direction) ? dx : dx * 0.2;
  }

  Future<void> _animateTo(double target) async {
    await _offset
        .animateTo(
          target,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        )
        .orCancel;
  }

  Future<void> _restore() async {
    try {
      await _animateTo(0);
    } on TickerCanceled {
      // 新手势或页面卸载会中断旧的动画，无需报错。
    }
  }

  Future<void> _onDragEnd() async {
    final event = _recognizer?.lastEvent;
    if (event == null || _settling) return;
    final direction = _intent.end(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      time: event.timeStamp,
      width: _width,
    );
    if (direction == null || !widget.enabled) {
      await _restore();
      return;
    }
    setState(() => _settling = true);
    try {
      if (_canTravel(direction)) {
        await _animateTo(direction > 0 ? -_width : _width);
      } else {
        await _animateTo(0);
      }
      if (mounted) await widget.onSwipe(direction);
    } on TickerCanceled {
      // 翻页数据到达后旧页面及其动画一并销毁。
    } finally {
      if (mounted) {
        await _restore();
        if (mounted) setState(() => _settling = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        return NotificationListener<S1ReadingSwipeBlockNotification>(
          onNotification: _onBlock,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onDown,
              onPointerUp: (event) => _removePointer(event.pointer),
              onPointerCancel: (event) {
                _cancelGesture();
                _removePointer(event.pointer);
              },
              child: RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                gestures: {
                  _ReadingDragRecognizer: GestureRecognizerFactoryWithHandlers<
                      _ReadingDragRecognizer>(
                    () => _recognizer = _ReadingDragRecognizer(
                      intent: _intent,
                      canStart: _canStart,
                      debugOwner: this,
                    ),
                    (recognizer) {
                      recognizer
                        ..gestureSettings =
                            MediaQuery.maybeGestureSettingsOf(context)
                        ..dragStartBehavior = DragStartBehavior.down
                        ..onlyAcceptDragOnThreshold = true
                        ..onStart = (_) {
                          _onDragUpdate();
                        }
                        ..onUpdate = (_) {
                          _onDragUpdate();
                        }
                        ..onEnd = (_) {
                          unawaited(_onDragEnd());
                        }
                        ..onCancel = _cancelGesture;
                    },
                  ),
                },
                child: IgnorePointer(
                  ignoring: _settling,
                  child: AnimatedBuilder(
                    animation: _offset,
                    child: RepaintBoundary(child: widget.child),
                    builder: (context, child) {
                      final dx = _offset.value;
                      final preview =
                          dx > 0 ? widget.previousPreview : widget.nextPreview;
                      return ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (dx != 0 && preview != null)
                              Transform.translate(
                                offset: Offset(
                                  dx > 0 ? dx - _width : dx + _width,
                                  0,
                                ),
                                child: IgnorePointer(child: preview),
                              ),
                            Transform.translate(
                              key: const ValueKey('s1-reading-swipe-content'),
                              offset: Offset(dx, 0),
                              child: child,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 在横纵识别器竞争期间检查方向，胜出后不再被累计 dy 撤销。
class _ReadingDragRecognizer extends HorizontalDragGestureRecognizer {
  _ReadingDragRecognizer({
    required this.intent,
    required this.canStart,
    super.debugOwner,
  });

  final ReadingSwipeIntent intent;
  final bool Function(PointerDownEvent) canStart;
  int? _pointer;
  PointerEvent? lastEvent;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event is PointerDownEvent &&
      _pointer == null &&
      canStart(event) &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    lastEvent = event;
    intent.begin(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      time: event.timeStamp,
      touchSlop: gestureSettings?.touchSlop ?? kTouchSlop,
    );
    super.addAllowedPointer(event);
  }

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    // 触控板滚动保留给正文，鼠标拖选同样不用于翻页。
  }

  @override
  void handleEvent(PointerEvent event) {
    lastEvent = event;
    if (event is PointerMoveEvent) {
      intent.update(
        x: event.localPosition.dx,
        y: event.localPosition.dy,
        time: event.timeStamp,
      );
      if (intent.isBlocked) {
        resolve(GestureDisposition.rejected);
        return;
      }
    } else if (event is PointerCancelEvent) {
      intent.cancel();
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind kind,
    double? slop,
  ) =>
      intent.isHorizontal;

  @override
  void rejectGesture(int pointer) {
    intent.cancel();
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _pointer = null;
  }
}
