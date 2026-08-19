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
  final bool showTranslation;

  /// 行级歌词（LRC）的揭示方式；逐字 YRC 不受影响。
  final LineLyricRevealMode lineLyricRevealMode;

  /// 卡拉 OK 渐变的淡出宽度，相对 [fontSize] 的比例。
  /// 实际渐变长度 = `wordFadeWidth × fontSize`。
  final double wordFadeWidth;

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
    this.showTranslation = true,
    this.lineLyricRevealMode = LineLyricRevealMode.linearSweep,
    this.wordFadeWidth = 0.5,
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
              fadeWidthPx: wordFadeWidth * fontSize,
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

    return child;
  }
}

/// 单行视觉呈现：由 [LyricEngine] 每帧喂入的位置/缩放/透明度/模糊值，
/// 本组件只做组合，不含任何动画逻辑。
///
/// - [translateY]：本行顶边相对歌词可视区顶边的 Y 偏移（px，可负/超视口）。
/// - [scale]：聚焦行 1.0，非聚焦 0.97（引擎内的弹簧在驱动）。
/// - [alpha]：0..1。
/// - [blurSigma]：景深模糊半径（由 LyricView 按"距当前行的归一化距离"计算）。
class LyricLineVisual extends StatelessWidget {
  final Widget child;
  final double translateY;
  final double scale;
  final double alpha;
  final double blurSigma;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const LyricLineVisual({
    super.key,
    required this.child,
    this.translateY = 0,
    this.scale = 1,
    this.alpha = 1,
    this.blurSigma = 0,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // blur 只包裹文字内容（child），不包裹 InkWell，避免 ImageFiltered 吞点击。
    final blurred = blurSigma > 0.05
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: blurSigma,
              sigmaY: blurSigma,
            ),
            child: child,
          )
        : child;
    final scaled = Transform.scale(
      scale: scale,
      alignment: Alignment.bottomLeft,
      child: Opacity(opacity: alpha.clamp(0.0, 1.0), child: blurred),
    );
    // InkWell 在 Transform.translate 内部：跟随行偏移，hit test 命中正确位置。
    final inner = (onTap != null || onLongPress != null)
        ? Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              borderRadius: BorderRadius.circular(8),
              splashColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
              highlightColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
              child: scaled,
            ),
          )
        : scaled;
    return Transform.translate(
      offset: Offset(0, translateY),
      child: inner,
    );
  }
}
