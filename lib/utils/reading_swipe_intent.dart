/// 被动读帖手势：只在松手后返回上一页 (-1) / 下一页 (1)。
///
/// 方向一旦锁定就不再切换；速度不降低位移门槛，避免短促甩动误翻页。
class ReadingSwipeIntent {
  static const double directionRatio = 1.8;
  static const double minimumIntentDistance = 24;
  static const double commitWidthFraction = 0.22;
  static const Duration longPressTimeout = Duration(milliseconds: 500);

  double _startX = 0;
  double _startY = 0;
  double _touchSlop = minimumIntentDistance;
  Duration _startTime = Duration.zero;
  _ReadingDirection _direction = _ReadingDirection.blocked;
  int _horizontalSign = 0;

  void begin({
    required double x,
    required double y,
    required Duration time,
    required double touchSlop,
  }) {
    _startX = x;
    _startY = y;
    _startTime = time;
    _touchSlop =
        touchSlop > minimumIntentDistance ? touchSlop : minimumIntentDistance;
    _direction = _ReadingDirection.pending;
    _horizontalSign = 0;
  }

  void cancel() => _direction = _ReadingDirection.blocked;

  void update({
    required double x,
    required double y,
    required Duration time,
  }) {
    if (_direction != _ReadingDirection.pending) return;
    // 先停留再拖动通常是长按选字或操作菜单，不能成为翻页候选。
    if (time - _startTime >= longPressTimeout) {
      cancel();
      return;
    }
    final dx = x - _startX;
    final dy = y - _startY;
    if (dx.abs() > _touchSlop && dx.abs() >= dy.abs() * directionRatio) {
      _direction = _ReadingDirection.horizontal;
      _horizontalSign = dx.sign.toInt();
    } else if (dy.abs() > _touchSlop) {
      cancel();
    }
  }

  int? end({
    required double x,
    required double y,
    required Duration time,
    required double width,
  }) {
    // 必须在移动阶段已经明确横向意图，不能只靠抬手坐标确认。
    final dx = x - _startX;
    final dy = y - _startY;
    final commit = _direction == _ReadingDirection.horizontal &&
        width.isFinite &&
        width > 0 &&
        time >= _startTime &&
        dx.sign.toInt() == _horizontalSign &&
        dx.abs() > _touchSlop &&
        dx.abs() >= width * commitWidthFraction &&
        dx.abs() >= dy.abs() * directionRatio;
    cancel();
    return commit ? (dx < 0 ? 1 : -1) : null;
  }
}

enum _ReadingDirection { pending, horizontal, blocked }
