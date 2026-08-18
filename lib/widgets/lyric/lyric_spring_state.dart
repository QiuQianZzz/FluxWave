import 'dart:math' as math;

import '../../core/lyric/lyric_spring.dart';

/// 弹簧物理参数（质量-弹簧-阻尼）。
///
/// 与 AMLL `SpringParams` 对齐：`stiffness` 越大弹簧越硬越快，`damping` 越大
/// 越"沉"越不容易回弹。临界阻尼 = 2·sqrt(stiffness·mass)；阻尼比 =
/// damping / (2·sqrt(stiffness·mass))，>1 为过阻尼（无回弹）、<1 为欠阻尼
/// （带回弹）。
class SpringParams {
  final double mass;
  final double stiffness;
  final double damping;

  const SpringParams({
    this.mass = 0.9,
    this.stiffness = 90,
    this.damping = 15,
  });
}

/// 带"延迟目标"的弹簧/缓动状态（移植自 AMLL core `utils/spring.ts`）。
///
/// 与 Flutter 的 [SpringSimulation] 不同：这里保留当前位置与速度，支持
/// `setTarget(to, delayMs)` 延迟若干毫秒后再启动弹簧，且可动态改参
/// （换句时按相邻行时间间隔重算 stiffness/damping）——这是 AMLL 每行
/// 独立"placement spring"与级联错落的基础。
///
/// - 弹簧模式：阻尼振荡解析解（过阻尼/临界/欠阻尼自动切换），[tick] 每帧
///   推进；到达 [settleDistance]/[settleVelocity] 容差即吸附到精确目标。
/// - 缓动模式（[useEase]）：弹簧关闭时的回退，固定时长 easeOutCubic，
///   同样支持级联延迟。
class SpringState {
  SpringParams params;

  /// 是否走固定时长缓动（关闭弹簧动画时使用）。
  final bool useEase;

  /// 缓动时长（毫秒）。
  final double easeDurationMs;

  /// 视为到位的位移容差。
  final double settleDistance;

  /// 视为到位的速度容差（px/秒 或 比例/秒）。
  final double settleVelocity;

  double _pos;
  double _vel = 0;
  double _to = 0;
  bool _settled = true;

  // 延迟目标：到点后启动一次新仿真。
  double? _pendingTo;
  double _pendingRemainMs = 0;

  // 本次仿真起点（解析解初值）与已推进时间。
  double _simStartPos = 0;
  double _simStartVel = 0;
  double _simT = 0;

  // 缓动起点。
  double _easeFrom = 0;

  SpringState(
    this.params,
    double initial, {
    this.useEase = false,
    this.easeDurationMs = 300,
    this.settleDistance = 0.5,
    this.settleVelocity = 10,
  }) : _pos = initial,
       _to = initial;

  double get position => _pos;
  double get velocity => _vel;
  bool get settled => _settled;

  /// 是否仍在"忙"：要么正在弹簧/缓动，要么在级联延迟中等待启动。
  /// 用于驱动帧循环——级联延迟期间位置不变但必须继续走 tick 计时，
  /// 否则延迟阶段会被"无动画就停表"逻辑冻结。
  bool get busy => !_settled || _pendingTo != null;

  /// 设置新目标。已到位且目标未变时是空操作，避免无谓重启动画。
  ///
  /// [force] = true 时立即落位（不弹）——用于首帧布局、手动拖动跟手、seek。
  void setTarget(double to, double delayMs, {bool force = false}) {
    if (force) {
      _pos = to;
      _vel = 0;
      _to = to;
      _settled = true;
      _pendingTo = null;
      return;
    }
    if (!useEase && _pendingTo == null && _settled && (to - _to).abs() < 1e-6) {
      return;
    }
    _to = to;
    _pendingTo = to;
    _pendingRemainMs = math.max(0.0, delayMs);
  }

  /// 推进 [dtMs] 毫秒。延迟未走完时位置保持不动。
  void tick(double dtMs) {
    final pending = _pendingTo;
    if (pending != null) {
      _pendingRemainMs -= dtMs;
      if (_pendingRemainMs > 0) return; // 仍在延迟：保持当前位置。
      _pendingTo = null;
      _startSimulation(-_pendingRemainMs); // 已超出的时间补进仿真。
      _settled = false;
    }
    if (_settled) return;
    if (useEase) {
      _stepEase(dtMs);
    } else {
      _stepSpring(dtMs);
    }
  }

  void _startSimulation(double extraMs) {
    _simStartPos = _pos;
    _simStartVel = _vel;
    _simT = extraMs / 1000.0;
    if (useEase) _easeFrom = _pos;
  }

  void _stepEase(double dtMs) {
    _simT += dtMs / 1000.0;
    final p = (_simT * 1000 / easeDurationMs).clamp(0.0, 1.0);
    final e = 1 - math.pow(1 - p, 3).toDouble(); // easeOutCubic
    final next = _easeFrom + (_to - _easeFrom) * e;
    _vel = (next - _pos) / math.max(1e-4, dtMs / 1000.0);
    _pos = next;
    if (p >= 1) {
      _pos = _to;
      _vel = 0;
      _settled = true;
    }
  }

  void _stepSpring(double dtMs) {
    _simT += dtMs / 1000.0;
    final next = _solve(_simStartPos, _simStartVel, _to, params, _simT);
    _vel = _solveVelocity(_simStartPos, _simStartVel, _to, params, _simT);
    _pos = next;
    if ((next - _to).abs() <= settleDistance && _vel.abs() <= settleVelocity) {
      _pos = _to;
      _vel = 0;
      _settled = true;
    }
  }

  /// 阻尼振荡解析解：x(t)，初值 (x0, v0)，目标 to。
  static double _solve(
    double x0,
    double v0,
    double to,
    SpringParams p,
    double t,
  ) {
    if (t <= 0) return x0;
    final m = p.mass;
    final k = p.stiffness;
    final d = p.damping;
    final delta = x0 - to;
    final critical = 2 * math.sqrt(m * k);

    if (d > critical) {
      final sq = math.sqrt(d * d - 4 * m * k);
      final r1 = (-d - sq) / (2 * m);
      final r2 = (-d + sq) / (2 * m);
      final c1 = (v0 - r2 * delta) / (r1 - r2);
      final c2 = delta - c1;
      return to + c1 * math.exp(r1 * t) + c2 * math.exp(r2 * t);
    }
    if (d == critical) {
      final omega = d / (2 * m);
      return to + (delta + (v0 + omega * delta) * t) * math.exp(-omega * t);
    }
    // 欠阻尼：衰减振荡。
    final omega = math.sqrt(4 * m * k - d * d) / (2 * m);
    final decay = d / (2 * m);
    final a = delta;
    final b = (v0 + decay * delta) / omega;
    return to +
        (a * math.cos(omega * t) + b * math.sin(omega * t)) *
            math.exp(-decay * t);
  }

  /// 速度 = 解析解的中央差分（与 AMLL `derivative.ts` 相同）。
  static double _solveVelocity(
    double x0,
    double v0,
    double to,
    SpringParams p,
    double t,
  ) {
    const h = 1e-4;
    return (_solve(x0, v0, to, p, t + h) - _solve(x0, v0, to, p, t - h)) /
        (2 * h);
  }
}

/// 按相邻两句歌词的时间间隔计算换行时的 posY 弹簧参数（AMLL
/// `computeLinePosYSpringParams`）：间隔越短弹簧越硬越快（stiffness 220），
/// 间隔越长越软（stiffness 170）。damping = √stiffness × 档位系数。
///
/// 这就是"每一句上来的手感都不一样"的来源——换句时动态重算并广播给所有行。
SpringParams computeLinePosYSpringParams({
  required int prevStartMs,
  required int curStartMs,
  required LyricSpringPreset preset,
  bool isSeek = false,
}) {
  if (isSeek) {
    // 拖动/跳转：用稳定偏软的参数。
    return SpringParams(stiffness: 90, damping: 15 * _dampingFactor(preset));
  }
  final interval = (curStartMs - prevStartMs).clamp(100, 800);
  final ratio = math.pow(1 - (interval - 100) / (800 - 100), 0.2).toDouble();
  final stiffness = 170 + ratio * (220 - 170);
  final damping = math.sqrt(stiffness) * _dampingFactor(preset);
  return SpringParams(stiffness: stiffness, damping: damping);
}

/// 档位 → 阻尼系数（AMLL 基准 2.2，让"标准"档贴合 AMLL 手感；
/// bouncy 1.4 ≈ 阻尼比 0.74，欠阻尼可见回弹）。
double _dampingFactor(LyricSpringPreset preset) => switch (preset) {
  LyricSpringPreset.soft => 2.8,
  LyricSpringPreset.standard => 2.2,
  LyricSpringPreset.bouncy => 1.4,
};