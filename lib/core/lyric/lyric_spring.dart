import 'package:flutter/physics.dart';

/// 歌词弹簧动画强度档位。
///
/// 位置/缩放双弹簧：不同档位对应不同
/// 的 [SpringDescription]（用 [SpringDescription.withDurationAndBounce] 描述
/// 时长 + 回弹强度）。档位表达"回弹强度 + 总时长"，关闭开关后走回原有的
/// 固定时长缓动（easeOutCubic）。
enum LyricSpringPreset {
  /// 轻弹：接近线性缓动，几乎无过冲。
  soft,

  /// 标准：轻微过冲后回正，默认档位。
  standard,

  /// 强弹：明显过冲，回弹感最强。
  bouncy;

  /// 展示名（设置页档位标签）。
  String get label => switch (this) {
    LyricSpringPreset.soft => '轻弹',
    LyricSpringPreset.standard => '标准',
    LyricSpringPreset.bouncy => '强弹',
  };

  /// 动画名义时长：行切换/聚焦动画的总时长（含最后一小段收敛余量，
  /// 结束帧由控制器吸附到精确目标，避免弹簧长尾巴空转）。
  Duration get duration => switch (this) {
    LyricSpringPreset.soft => const Duration(milliseconds: 360),
    LyricSpringPreset.standard => const Duration(milliseconds: 420),
    LyricSpringPreset.bouncy => const Duration(milliseconds: 480),
  };

  /// 回弹强度（0 = 无过冲，越大过冲越明显；对应曲线峰值过冲 ≈ 值 × 0.4）。
  double get bounce => switch (this) {
    LyricSpringPreset.soft => 0.18,
    LyricSpringPreset.standard => 0.38,
    LyricSpringPreset.bouncy => 0.45,
  };

  /// 该档位的弹簧物理参数（时长 + 回弹）。
  SpringDescription get spring => SpringDescription.withDurationAndBounce(
    duration: duration,
    bounce: bounce,
  );
}

/// 歌词弹簧动画的共享描述。
///
/// - 滚动：行切换时当前行滚到锚点，位置曲线带轻微过冲。
/// - 行视觉：聚焦行放大、非聚焦行缩小 + 透明度，过冲体现在缩放上。
class LyricSpring {
  const LyricSpring._();

  /// 滚动/缩放共用的目标容差：位移或比例与该阈值内即视为到达终点。
  static const tolerance = Tolerance(velocity: 0.5, distance: 0.001);

  /// 由位移/比例差生成弹簧仿真（无初速度）。
  ///
  /// [from] 当前值，[to] 目标值。返回的仿真用秒作为时间单位，
  /// 可查询 [SpringSimulation.x]/[isDone]/[type]。
  static SpringSimulation spring(
    SpringDescription spring,
    double from,
    double to,
  ) {
    return SpringSimulation(
      spring,
      from,
      to,
      0, // 初速度：行切换是瞬态起点，无残余速度。
      tolerance: tolerance,
    );
  }

  /// 弹簧动画的名义时长：直接取 [preset] 档位时长。
  ///
  /// 弹簧没有严格的结束点（[SpringSimulation.isDone] 受容差影响，收敛尾巴
  /// 远超可视运动），用固定名义时长 + 动画结束帧吸附到精确目标即可，避免
  /// 控制器为肉眼不可见的长尾巴空转。
  static Duration duration(LyricSpringPreset preset) => preset.duration;
}

/// 弹簧过冲程度：仿真在到达目标值前超出目标的最大超调量。
///
/// 用于单元测试验证不同档位的回弹强度排序（soft < standard < bouncy），
/// 以及确认曲线在收敛前确实存在过冲（而不是退化为单调缓动）。
double springOvershoot(SpringDescription spring) {
  final sim = SpringSimulation(spring, 0, 1, 0);
  var maxOver = 0.0;
  for (var ms = 0; ms < 3000; ms += 4) {
    final x = sim.x(ms / 1000.0);
    if (x > 1) maxOver = _maxDouble(maxOver, x - 1);
  }
  return maxOver;
}

double _maxDouble(double a, double b) => a > b ? a : b;