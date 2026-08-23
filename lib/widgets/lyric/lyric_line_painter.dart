import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/lyric/line_lyric_reveal_mode.dart';
import 'lyric_layout.dart';

/// 放大字符相对锚点（词水平中心）左移时，返回把左缘拉回缓冲墙（`-leftBuffer`）
/// 的平移量。
///
/// 逐字 awesome 动画以词中心为锚点缩放，行首词的最左字符放大时左缘会左移。
/// 左侧有 [kLyricLeftBuffer] 宽的可见缓冲，正常溢出进入缓冲即可（返回 0）；
/// 仅当溢出超过缓冲（超长词）才整词右移补齐，避免被视口左缘裁掉。
double safeShiftXForScale(
  double xPos,
  double pivotX,
  double scale,
  double leftBuffer,
) {
  final scaledLeft = pivotX + (xPos - pivotX) * scale;
  final wall = -leftBuffer;
  return scaledLeft < wall ? -(scaledLeft - wall) : 0.0;
}

/// 单行歌词的 Canvas 绘制。
///
/// - 每行预测量一次（[LyricLineLayout]），paint 只做几何定位 + 渐变裁切。
/// - 逐字 awesome 动画：DipAndRise（下沉回升）/ Swell（放大）/ Bounce
///   （阴影）按 char 比例错峰起始，仅对慢速非 CJK 词启用。
/// - 简单浮动：CJK/阿拉伯语等按音节 4px 下浮（700ms，SimpleFloat 缓动）。
/// - 行内渐变：saveLayer + BlendMode.dstIn 裁切（active→inactive 软边界）。
///
/// [isFocused] 时走完整 karaoke 渲染；否则只画静态文字（供模糊/缩放层叠加）。
class LyricLinePainter extends CustomPainter {
  final LyricLineLayout layout;
  final int currentTimeMs;
  final Color activeColor;
  final bool isFocused;

  /// 非聚焦行用色（透明度由外层动画叠加）。
  final Color inactiveColor;

  /// 行级歌词（LRC）的揭示方式；逐字 YRC 恒走逐字动画不受影响。
  final LineLyricRevealMode lineLyricRevealMode;

  /// 卡拉 OK 渐变淡出宽度（px）。
  final double fadeWidthPx;

  const LyricLinePainter({
    required this.layout,
    required this.currentTimeMs,
    required this.activeColor,
    required this.inactiveColor,
    required this.isFocused,
    this.lineLyricRevealMode = LineLyricRevealMode.linearSweep,
    this.fadeWidthPx = 10.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!isFocused) {
      _paintStatic(canvas);
      return;
    }
    for (final row in layout.rows) {
      // LRC 纯静态模式：整行固定 active 色，无渐变、无逐字（对齐用户要求）。
      if (row.isLineLevel &&
          lineLyricRevealMode == LineLyricRevealMode.staticLine) {
        _paintRowActive(canvas, row.rowLayouts, row.layerBounds);
        continue;
      }
      if (currentTimeMs >= row.lastSyllableEnd) {
        _paintRowStatic(canvas, row.rowLayouts);
        continue;
      }
      final bounds = row.layerBounds;
      canvas.saveLayer(bounds, Paint());
      _drawRowText(canvas, row.rowLayouts, currentTimeMs);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = _createLineGradientShader(row, currentTimeMs)
          ..blendMode = BlendMode.dstIn,
      );
      canvas.restore();
    }
  }

  /// 非聚焦行：静态绘制全部行（不做逐字动画/发光，省 GPU）。
  void _paintStatic(Canvas canvas) {
    for (final row in layout.rows) {
      _paintRowStatic(canvas, row.rowLayouts);
    }
  }

  void _paintRowStatic(Canvas canvas, List<SyllableLayout> rowLayouts) {
    for (final sl in rowLayouts) {
      sl.textPainter.paint(canvas, sl.position);
    }
  }

  /// LRC 纯静态整行：整行固定 active 色（无渐变、无逐字揭示）。
  ///
  /// 文本先以原始色画出，再用 solid active 色 + dstIn 覆写为整行统一 active
  /// 色，效果等同"线性扫过完全播完"的终态，但全程无渐变/无逐字。
  void _paintRowActive(
    Canvas canvas,
    List<SyllableLayout> rowLayouts,
    Rect bounds,
  ) {
    canvas.saveLayer(bounds, Paint());
    for (final sl in rowLayouts) {
      sl.textPainter.paint(canvas, sl.position);
    }
    canvas.drawRect(
      bounds,
      Paint()
        ..color = activeColor
        ..blendMode = BlendMode.dstIn,
    );
    canvas.restore();
  }

  /// 每视觉行绘制：awesome 逐字 / 简单浮动。
  void _drawRowText(
    Canvas canvas,
    List<SyllableLayout> rowLayouts,
    int timeMs,
  ) {
    for (var index = 0; index < rowLayouts.length; index++) {
      final sl = rowLayouts[index];
      final anim = sl.wordAnimInfo;
      if (anim != null) {
        _drawAwesomeWord(canvas, sl, anim, timeMs);
      } else {
        _drawSimpleSyllable(canvas, sl, rowLayouts, index, timeMs);
      }
    }
  }

  void _drawAwesomeWord(
    Canvas canvas,
    SyllableLayout sl,
    WordAnimationInfo anim,
    int timeMs,
  ) {
    final awesomeDuration = anim.awesomeDuration;
    final earliestStart = anim.wordStartTime;
    final swellAmount = anim.swellAmount;

    final charPainters = sl.charPainters;
    final charGlowPainters = sl.charGlowPainters;
    final charWidths = sl.charWidths;

    if (charPainters != null) {
      // 平滑上浮（对齐"上浮"而非"跳动"）：整词同步，去掉逐字错峰起始——
      // 错峰正是"阶段性起伏"的来源。前半程 easeInOutCubic 平滑升到峰值，
      // 后半程保持（上浮后停在原位，不回落）。幅度固定 1px。
      final wordProgress = ((timeMs - earliestStart) / awesomeDuration).clamp(
        0.0,
        1.0,
      );
      final floatProgress = Curves.easeInOutCubic.transform(
        (wordProgress / 0.5).clamp(0.0, 1.0),
      );
      // Flutter y 向下，负值=上浮。
      final floatOffset = -1.0 * floatProgress;
      final scale = 1.0 + swellAmount * math.sin(wordProgress * math.pi);
      final blurRadius = 10.0 * math.sin(wordProgress * math.pi);

      // 第一遍：预计算每个字符的绘制参数与"整词需要右移的安全量"。
      // 以词中心为锚点放大时，行首词的最左字符会左移出可视区左缘；必须整词
      // 统一平移（而非逐字符平移），保留词内相邻关系，否则最左字符会压到右侧
      // 字符上造成重叠。
      final charData = <(double, double)>[];
      double safeShift = 0;
      var cursorX = sl.position.dx;
      for (var ci = 0; ci < charPainters.length; ci++) {
        final cp = charPainters[ci];
        final charWidth = charWidths[ci];
        final xPos = cursorX + (charWidth - cp.width) / 2;
        final yPos = sl.position.dy + floatOffset;
        final shift = safeShiftXForScale(
          xPos,
          sl.wordPivot.dx,
          scale,
          kLyricLeftBuffer,
        );
        if (shift > safeShift) safeShift = shift;
        charData.add((xPos, yPos));
        cursorX += charWidth;
      }

      canvas.save();
      canvas.translate(safeShift, 0);
      for (var ci = 0; ci < charPainters.length; ci++) {
        final cp = charPainters[ci];
        final (xPos, yPos) = charData[ci];

        canvas.save();
        canvas.translate(sl.wordPivot.dx, sl.wordPivot.dy);
        canvas.scale(scale);
        canvas.translate(-sl.wordPivot.dx, -sl.wordPivot.dy);

        final glow = charGlowPainters != null && ci < charGlowPainters.length
            ? charGlowPainters[ci]
            : null;
        if (glow != null && blurRadius > 0.1) {
          // 发光层自带 maskFilter 模糊，无需 saveLayer；直接绘制避免光晕被
          // 字框裁成硬边。
          glow.paint(canvas, Offset(xPos, yPos));
        }
        cp.paint(canvas, Offset(xPos, yPos));
        canvas.restore();
      }
      canvas.restore();
    } else {
      // 无逐字数据兜底：整音节按简单动画绘制
      _drawSimpleSyllable(canvas, sl, [sl], 0, timeMs);
    }
  }

  void _drawSimpleSyllable(
    Canvas canvas,
    SyllableLayout sl,
    List<SyllableLayout> rowLayouts,
    int index,
    int timeMs,
  ) {
    // LRC 伪逐字不允许逐字运动：纯静态绘制（仅保留行级渐变揭示）。
    if (!sl.allowFloat) {
      sl.textPainter.paint(canvas, sl.position);
      return;
    }
    final driver = _resolveDriverSyllable(rowLayouts, index);
    final timeSinceStart = timeMs - driver.syllable.startTimeMs;
    final animationProgress = (timeSinceStart / kFixedSimpleAnimationDurationMs)
        .clamp(0.0, 1.0);
    // SimpleFloat 缓动近似：CubicBezier(0,0,0.2,1)（快速浮起、慢速回落）
    final floatCurveValue = _simpleFloat(1.0 - animationProgress);
    final floatOffset = kMaxSimpleFloatOffsetY * floatCurveValue;

    final finalPosition = sl.position + Offset(0, floatOffset);
    sl.textPainter.paint(canvas, finalPosition);
  }

  SyllableLayout _resolveDriverSyllable(
    List<SyllableLayout> rowLayouts,
    int index,
  ) {
    final content = rowLayouts[index].syllable.content.trim();
    if (isPunctuationChar(content) && index > 0) {
      var searchIndex = index - 1;
      while (searchIndex >= 0) {
        final candidate = rowLayouts[searchIndex];
        if (!isPunctuationChar(candidate.syllable.content.trim())) {
          return candidate;
        }
        searchIndex--;
      }
    }
    return rowLayouts[index];
  }

  double _simpleFloat(double fraction) {
    final f = fraction.clamp(0.0, 1.0);
    // 近似 CubicBezier(0, 0, 0.2, 1)：x(t)=t, y = 1-(1-t)^4 拉伸
    // 简化：使用平滑幂函数，避免引入动画包。
    final t = f;
    final c = 0.2;
    final s = 1 - t;
    final bez = (1 - (s * s * s * s));
    return (t <= 0.0001)
        ? 0.0
        : (bez + c * (t * (1 - t))) * (1 / (1 + c * 0.25));
  }

  /// 行内渐变 shader：active 前沿 + 软边界。
  Shader _createLineGradientShader(RowRenderData row, int currentTimeMs) {
    final activeColor = this.activeColor;
    final inactiveColor = activeColor.withValues(alpha: 0.2);
    final minFadeWidth = fadeWidthPx;

    final totalMinX = row.totalMinX;
    final totalMaxX = row.totalMaxX;
    final totalWidth = row.totalWidth;

    if (totalWidth <= 0) {
      final isFinished = currentTimeMs >= row.lastSyllableEnd;
      return LinearGradient(
        colors: [
          isFinished ? activeColor : inactiveColor,
          isFinished ? activeColor : inactiveColor,
        ],
      ).createShader(Rect.fromLTRB(totalMinX, 0, totalMaxX, 0));
    }

    final lineProgress = _lineProgress(row, currentTimeMs);
    final fadeRange = (minFadeWidth / totalWidth).clamp(0.0, 1.0);
    final fadeCenter = (-fadeRange / 2) + (1 + fadeRange) * lineProgress;
    final fadeStart = fadeCenter - fadeRange / 2;
    final fadeEnd = fadeCenter + fadeRange / 2;

    return LinearGradient(
      colors: [activeColor, activeColor, inactiveColor, inactiveColor],
      stops: [0.0, fadeStart.clamp(0.0, 1.0), fadeEnd.clamp(0.0, 1.0), 1.0],
    ).createShader(Rect.fromLTRB(totalMinX, 0, totalMaxX, 0));
  }

  double _lineProgress(RowRenderData row, int currentTimeMs) {
    if (currentTimeMs <= row.firstSyllableStart) return 0;
    if (currentTimeMs >= row.lastSyllableEnd) return 1;

    // 行级歌词（LRC）：整行单一颜色线性揭示，不随音节几何/时间逐字推进，
    // 整行折叠为一个单词的整行卡拉 OK。
    if (row.isLineLevel) {
      final dur = row.lastSyllableEnd - row.firstSyllableStart;
      return dur <= 0
          ? 0
          : ((currentTimeMs - row.firstSyllableStart) / dur).clamp(0.0, 1.0);
    }

    // YRC 逐字：找到当前正在播放的音节。
    final activeLayout = row.rowLayouts.firstWhere(
      (l) =>
          currentTimeMs >= l.syllable.startTimeMs &&
          currentTimeMs < l.syllable.endTimeMs,
      orElse: () {
        final last = row.rowLayouts
            .where((l) => currentTimeMs >= l.syllable.endTimeMs)
            .toList();
        return last.isEmpty
            ? row.rowLayouts.first
            : last.reduce(
                (a, b) => a.syllable.endTimeMs > b.syllable.endTimeMs ? a : b,
              );
      },
    );

    // 音节内进度
    final syllableDur =
        (activeLayout.syllable.endTimeMs - activeLayout.syllable.startTimeMs)
            .clamp(1, 0x7FFFFFFF);
    final intraProgress =
        ((currentTimeMs - activeLayout.syllable.startTimeMs) / syllableDur)
            .clamp(0.0, 1.0);
    final syllablePixelEnd =
        activeLayout.position.dx + activeLayout.width;

    // currentTimeMs 落在音节间隙（两个音节之间）时，线性插值到下一个音节
    // 起点，避免进度卡在当前音节右端导致"回跳"。
    if (currentTimeMs >= activeLayout.syllable.endTimeMs) {
      final nextIdx = row.rowLayouts.indexOf(activeLayout) + 1;
      if (nextIdx < row.rowLayouts.length) {
        final next = row.rowLayouts[nextIdx];
        final gapStart = activeLayout.syllable.endTimeMs.toDouble();
        final gapEnd = next.syllable.startTimeMs.toDouble();
        final gap =
            (gapEnd - gapStart).clamp(1.0, double.infinity);
        final t = ((currentTimeMs - gapStart) / gap).clamp(0.0, 1.0);
        final pixelAtEnd = syllablePixelEnd;
        final pixelAtNextStart = next.position.dx;
        final currentPixelPosition =
            pixelAtEnd + (pixelAtNextStart - pixelAtEnd) * t;
        return ((currentPixelPosition - row.totalMinX) / row.totalWidth)
            .clamp(0.0, 1.0);
      }
    }

    final currentPixelPosition =
        activeLayout.position.dx + activeLayout.width * intraProgress;

    return ((currentPixelPosition - row.totalMinX) / row.totalWidth).clamp(
      0.0,
      1.0,
    );
  }

  @override
  bool shouldRepaint(covariant LyricLinePainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.currentTimeMs != currentTimeMs ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.isFocused != isFocused ||
        oldDelegate.lineLyricRevealMode != lineLyricRevealMode ||
        oldDelegate.fadeWidthPx != fadeWidthPx;
  }
}
