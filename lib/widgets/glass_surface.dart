import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 通用毛玻璃面板：`ClipRRect` 隔离模糊范围 + `BackdropFilter` + 半透明渐变 + 描边。
///
/// 底部导航 / 侧边栏 / 迷你播放器等界面元素共用同一「玻璃语言」，避免各处复制
/// ClipRect/BackdropFilter/渐变/描边逻辑。模糊 sigma 与描边统一，渐变不透明度
/// 按用途微调：功能栏（导航，需图标可读）偏实，悬浮卡（小播放器）偏透。
///
/// [enabled] 对应全局毛玻璃开关：关闭时回退为 [solidColor] 实色（无模糊）。
class GlassSurface extends StatelessWidget {
  final Widget child;

  /// 高斯模糊半径（sigma）。
  final double sigma;

  /// 渐变顶部/底部不透明度（基于 [baseColor]）。
  final double topAlpha;
  final double bottomAlpha;

  /// 渐变基色（默认 `colorScheme.surface`）。
  final Color? baseColor;

  final BorderRadius borderRadius;

  /// 描边（高光边 / 分隔线），默认无。
  final BoxBorder border;

  /// 全局毛玻璃开关；false 时用 [solidColor] 实色替代。
  final bool enabled;

  /// 关闭模糊时的实色（默认 [baseColor]）。
  final Color? solidColor;

  const GlassSurface({
    super.key,
    required this.child,
    this.sigma = 18,
    this.topAlpha = 0.72,
    this.bottomAlpha = 0.55,
    this.baseColor,
    this.borderRadius = BorderRadius.zero,
    this.border = const Border(),
    this.enabled = true,
    this.solidColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = baseColor ?? cs.surface;
    if (!enabled) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: ColoredBox(color: solidColor ?? base, child: child),
      );
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                base.withValues(alpha: topAlpha),
                base.withValues(alpha: bottomAlpha),
              ],
            ),
            border: border,
          ),
          child: child,
        ),
      ),
    );
  }
}
