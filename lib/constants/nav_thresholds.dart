/// 水平滑动切换阈值（统一外部 Tab 与播放页内歌词页切换）。
///
/// 两处场景共享同一套阈值，保证全应用内滑动手感一致：
/// - 距离：拖动超过 [dragDistanceRatio] 比例的屏宽 → 完成切换
/// - 速度：方向一致且速度 > [flingVelocityThreshold] px/s → 完成切换
/// 满足任一条件即切换，避免"必须拖过半"的迟钝手感。
class NavThresholds {
  NavThresholds._();

  /// 完成切换所需的最小拖动距离比例（相对屏宽）。
  static const double dragDistanceRatio = 0.25;

  /// 完成切换所需的最小 fling 速度（px/s）。
  static const double flingVelocityThreshold = 280;

  /// 判定是否应完成切换。
  ///
  /// [dragRatio] 拖动距离与屏宽之比的绝对值（0..1）。
  /// [velocity] 松手时的 primaryVelocity（px/s），带方向。
  /// [drag] 原始拖动量（带符号），用于判定方向是否与速度一致。
  /// [dragDistanceRatio] 完成切换所需的最小拖动距离比例，缺省用 [dragDistanceRatio]
  /// 常量（外部 Tab 默认）；需要更灵敏手势的页面（如播放页歌词切换）可传更小值。
  static bool shouldComplete({
    required double dragRatio,
    required double velocity,
    required double drag,
    double? dragDistanceRatio,
  }) {
    final ratio = dragDistanceRatio ?? NavThresholds.dragDistanceRatio;
    final flingSameDir =
        velocity.abs() > flingVelocityThreshold && (velocity > 0) == (drag > 0);
    return dragRatio > ratio || flingSameDir;
  }
}
