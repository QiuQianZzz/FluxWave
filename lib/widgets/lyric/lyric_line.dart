import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/lyric/line_lyric_reveal_mode.dart';
import '../../core/lyric/lyric_model.dart';
import 'lyric_layout.dart';
import 'lyric_line_painter.dart';

/// 是否含日语假名。
bool containsJapaneseKana(String text) {
  return text.split('').any((char) {
    final c = char.codeUnitAt(0);
    return (c >= 0x3040 && c <= 0x30FF) ||
        (c >= 0x31F0 && c <= 0x31FF) ||
        (c >= 0xFF66 && c <= 0xFF9F);
  });
}

/// 单行歌词渲染。
///
/// - 聚焦行：Canvas 绘制（逐字 awesome 动画 / 简单浮动 + 行内渐变揭示）
/// - 非聚焦行：静态文字 + 外层 [LyricView] 叠加缩放/透明度/模糊
/// - 行下方翻译（假名原文额外留间距）
/// - 点击 seek；长按触发 [onLongPressLine]
class LyricLineView extends StatelessWidget {
  final LyricLine line;
  final LyricLineLayout layout;
  final bool isActive;
  final int currentTimeMs;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final double? translationFontSize;
  final VoidCallback? onTapLine;
  final VoidCallback? onLongPressLine;
  final bool showTranslation;

  /// 行级歌词（LRC）的揭示方式；逐字 YRC 不受影响。
  final LineLyricRevealMode lineLyricRevealMode;

  /// 前奏/间奏呼吸圆点（null = 不显示）。
  final Widget? leadingDots;

  const LyricLineView({
    super.key,
    required this.line,
    required this.layout,
    required this.isActive,
    required this.currentTimeMs,
    required this.activeColor,
    required this.inactiveColor,
    required this.fontSize,
    this.translationFontSize,
    this.onTapLine,
    this.onLongPressLine,
    this.showTranslation = true,
    this.lineLyricRevealMode = LineLyricRevealMode.linearSweep,
    this.leadingDots,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canvasHeight = layout.totalHeight;

    final translationText = showTranslation
        ? (line.translation ?? '').isNotEmpty
              ? line.translation!
              : (line.roman ?? '').isNotEmpty
              ? line.roman!
              : null
        : null;

    final child = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leadingDots != null)
          Padding(padding: const EdgeInsets.only(top: 4), child: leadingDots!),
        // 画布文字对读屏不可见，用 Semantics 补回整行歌词。
        Semantics(
          label: line.text,
          container: true,
          child: CustomPaint(
            size: Size(double.infinity, canvasHeight),
            painter: LyricLinePainter(
              layout: layout,
              currentTimeMs: currentTimeMs,
              activeColor: activeColor,
              inactiveColor: inactiveColor,
              isFocused: isActive,
              lineLyricRevealMode: lineLyricRevealMode,
            ),
          ),
        ),
        if (translationText != null)
          Padding(
            padding: EdgeInsets.only(
              top: containsJapaneseKana(line.text) ? 7 : 4,
            ),
            child: Text(
              translationText,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: translationFontSize ?? fontSize * 0.7,
                color: isActive
                    ? activeColor.withValues(alpha: 0.85)
                    : inactiveColor.withValues(alpha: 0.7),
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
      ],
    );

    if (onTapLine == null && onLongPressLine == null) return child;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTapLine,
        onLongPress: onLongPressLine,
        borderRadius: BorderRadius.circular(8),
        splashColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.12),
        highlightColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.06),
        child: child,
      ),
    );
  }
}

/// 单行视觉动画包装：聚焦行放大提亮、非聚焦行缩小压暗 + 按传入模糊值。
///
/// - 聚焦：scale 1.015 / alpha 1.0，600ms LinearOutSlowIn
/// - 非聚焦：scale 0.965 / alpha 0.28，300ms EaseInOut
/// - 模糊半径 = [blurSigma]（由 LyricView 按"距当前行的归一化距离"曲线计算，
///   滑动/自动滚动期间置 0；此处仅做 300ms 平滑过渡）
class LyricLineVisual extends StatelessWidget {
  final bool isFocused;
  final Widget child;

  /// 高斯模糊半径（sigma）；0 = 不模糊。由外层按景深模型计算。
  final double blurSigma;

  const LyricLineVisual({
    super.key,
    required this.isFocused,
    required this.child,
    this.blurSigma = 0,
  });

  @override
  Widget build(BuildContext context) {
    final target = isFocused ? 1.0 : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: target, end: target),
      duration: isFocused
          ? const Duration(milliseconds: 600)
          : const Duration(milliseconds: 300),
      curve: isFocused ? Curves.linearToEaseOut : Curves.easeInOut,
      builder: (context, t, child) {
        final scale = lerpDouble(0.965, 1.015, t)!;
        final alpha = lerpDouble(0.28, 1.0, t)!;
        final blurTarget = isFocused ? 0.0 : blurSigma;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: blurTarget, end: blurTarget),
          duration: const Duration(milliseconds: 300),
          builder: (context, sigma, child) {
            Widget result = Transform.scale(
              scale: scale,
              // TransformOrigin(0, 1)（LTR 左下角）：
              // 放大时左边缘保持不动，避免聚焦行左溢出可视区。
              alignment: Alignment.bottomLeft,
              child: Opacity(opacity: alpha, child: child),
            );
            if (sigma > 0.05) {
              result = ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: result,
              );
            }
            return result;
          },
          child: child,
        );
      },
      child: child,
    );
  }
}
