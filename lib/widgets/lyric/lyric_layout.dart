import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../core/lyric/lyric_model.dart';

/// 歌词区左侧溢出缓冲（px）：歌词面板向左扩展该宽度作为可见安全区，逐字
/// awesome 放大/发光向左溢出时进入该缓冲而不会被视口左缘裁掉；歌词文字仍
/// 从原位置开始（ListView 左 padding 抵消面板左移）。
const double kLyricLeftBuffer = 24.0;

/// 歌词行的预测量 + 排版。
///
/// 职责（全部纯函数/数据类，便于单测）：
/// - 把 [LyricLine] 拆成音节（YRC words 直接用；LRC 走伪逐字均分）
/// - 用 [TextPainter] 一次性预测量每个音节/字符（awesome 动画才逐字测）
/// - 平衡换行（DP 代价）优先，贪心兜底
/// - 静态排版：RTL/右对齐、行高、wordPivot/charOffset
/// - 输出 [LyricLineLayout]，交给 [LyricLinePainter] 只读绘制
///
/// 不做任何动画/时间推进，仅做几何与度量。

/// 排版后的完整一行歌词：多行（换行后的视觉行）的渲染数据 + 总高度。
class LyricLineLayout {
  final List<RowRenderData> rows;
  final double totalHeight;

  const LyricLineLayout({required this.rows, required this.totalHeight});

  bool get isEmpty => rows.isEmpty;
}

/// 换行后的单条视觉行。
class WrappedLine {
  final List<SyllableLayout> syllables;
  final double totalWidth;

  const WrappedLine({required this.syllables, required this.totalWidth});
}

/// 单行渲染数据：定位 + 渐变裁切边界。
class RowRenderData {
  final List<SyllableLayout> rowLayouts;
  final double totalMinX;
  final double totalMaxX;
  final double totalWidth;
  final int firstSyllableStart;
  final int lastSyllableEnd;
  final Rect layerBounds;

  /// 行级歌词（LRC，无逐字时间轴）：揭示按整行单一颜色线性扫过，
  /// 而非逐音节推进（类似 AMLL 把 LRC 行折叠成"整行一个单词"的做法）。
  final bool isLineLevel;

  const RowRenderData({
    required this.rowLayouts,
    required this.totalMinX,
    required this.totalMaxX,
    required this.totalWidth,
    required this.firstSyllableStart,
    required this.lastSyllableEnd,
    required this.layerBounds,
    this.isLineLevel = false,
  });
}

/// 单词动画元信息：整个单词的时间窗、文本与预计算的逐字动画幅度。
///
/// [swellAmount] 只依赖单词时长与字符数，在排版阶段一次性算好，避免渲染期
/// 每个音节重复构造；绘制期用 sin(π·progress) 平滑曲线套用。
class WordAnimationInfo {
  final int wordStartTime;
  final int wordEndTime;
  final String wordContent;

  /// 放大幅度（0..0.1）：词越慢越大。
  final double swellAmount;

  final double awesomeDuration;

  WordAnimationInfo({
    required this.wordStartTime,
    required this.wordEndTime,
    required this.wordContent,
    required this.swellAmount,
    required this.awesomeDuration,
  });

  int get wordDuration => wordEndTime - wordStartTime;
}

/// 单个音节的排版结果：文本 + 度量 + 位置（位置在静态排版阶段写入）。
class SyllableLayout {
  final LyricSyllable syllable;
  final TextPainter textPainter;
  final int wordId;
  final bool useAwesomeAnimation;
  final double width;
  final double firstBaseline;

  /// 是否允许"简单浮动"（4px 上下浮动）。LRC 伪逐字为 false → 完全静态。
  final bool allowFloat;

  /// awesome 动画专用：逐字预测量的普通绘制器。
  final List<TextPainter>? charPainters;

  /// awesome 动画专用：逐字预测量的发光绘制器（软阴影）。
  final List<TextPainter>? charGlowPainters;

  /// awesome 动画专用：逐字宽度（定位用，含居中修正）。
  final List<double> charWidths;

  Offset position = Offset.zero;
  Offset wordPivot = Offset.zero;
  WordAnimationInfo? wordAnimInfo;
  int charOffsetInWord = 0;

  SyllableLayout({
    required this.syllable,
    required this.textPainter,
    required this.wordId,
    required this.useAwesomeAnimation,
    required this.width,
    required this.firstBaseline,
    this.allowFloat = true,
    this.charPainters,
    this.charGlowPainters,
    this.charWidths = const [],
  });
}

/// 音节数据（与模型解耦，携带逐字时间与可选注音）。
class LyricSyllable {
  final String content;
  final int startTimeMs;
  final int endTimeMs;

  const LyricSyllable({
    required this.content,
    required this.startTimeMs,
    required this.endTimeMs,
  });
}

// ── 文字判定 ─────────────────────────────────────────────────

bool _inRange(int code, int low, int high) => code >= low && code <= high;

/// 是否为 CJK / 假名 / 谚文。
bool isCjkChar(String char) {
  final c = char.codeUnitAt(0);
  return _inRange(c, 0x4E00, 0x9FFF) || // CJK Unified
      _inRange(c, 0x3400, 0x4DBF) || // Ext A
      _inRange(c, 0x20000, 0x2A6DF) || // Ext B
      _inRange(c, 0x2A700, 0x2B73F) || // Ext C
      _inRange(c, 0x2B740, 0x2B81F) || // Ext D
      _inRange(c, 0x2B820, 0x2CEAF) || // Ext E
      _inRange(c, 0x2CEB0, 0x2EBEF) || // Ext F
      _inRange(c, 0x30000, 0x3134F) || // Ext G
      _inRange(c, 0x31350, 0x323AF) || // Ext H
      _inRange(c, 0xF900, 0xFAFF) || // Compat Ideographs
      _inRange(c, 0x3000, 0x303F) || // CJK Symbols & Punct
      _inRange(c, 0x3040, 0x309F) || // Hiragana
      _inRange(c, 0x30A0, 0x30FF) || // Katakana
      _inRange(c, 0xAC00, 0xD7AF) || // Hangul Syllables
      _inRange(c, 0x1100, 0x11FF) || // Hangul Jamo
      _inRange(c, 0x3130, 0x318F); // Hangul Compat Jamo
}

bool isArabicChar(String char) {
  final c = char.codeUnitAt(0);
  return _inRange(c, 0x0600, 0x06FF) ||
      _inRange(c, 0x0750, 0x077F) ||
      _inRange(c, 0x08A0, 0x08FF) ||
      _inRange(c, 0xFB50, 0xFDFF) ||
      _inRange(c, 0xFE70, 0xFEFF) ||
      _inRange(c, 0x0870, 0x089F);
}

bool isDevanagariChar(String char) {
  final c = char.codeUnitAt(0);
  return _inRange(c, 0x0900, 0x097F) || _inRange(c, 0xA8E0, 0xA8FF);
}

bool isPunctuationChar(String char) {
  if (char.isEmpty) return true;
  final c = char.codeUnitAt(0);
  if (char.trim().isEmpty) return true;
  if (".'\"(),!?;:[]{}…—–-、。，！？；：<>《》～·''\"\"".contains(char)) {
    return true;
  }
  // 常见标点码段近似（连接符/破折号/引号/括号等）
  return _inRange(c, 0x2010, 0x201F) ||
      _inRange(c, 0x2026, 0x2027) ||
      _inRange(c, 0x2030, 0x203E) ||
      _inRange(c, 0x2041, 0x2053) ||
      _inRange(c, 0x3001, 0x3003) ||
      _inRange(c, 0x3008, 0x3011) ||
      _inRange(c, 0x3014, 0x301F) ||
      _inRange(c, 0xFF01, 0xFF0F) ||
      _inRange(c, 0xFF1A, 0xFF20) ||
      _inRange(c, 0xFF3B, 0xFF40) ||
      _inRange(c, 0xFF5B, 0xFF65);
}

/// 是否纯 CJK（去除空白与标点后全部为 CJK）。
bool isPureCjk(String text) {
  final cleaned = text.split('').where((c) => !isPunctuationChar(c)).join();
  if (cleaned.isEmpty) return false;
  return cleaned.split('').every(isCjkChar);
}

/// 行是否为 RTL（含阿拉伯字符）。
bool isRtlText(String text) => text.split('').any(isArabicChar);

/// 判定整个单词是否应走"简单浮动"而非逐字 awesome 动画。
bool shouldUseSimpleAnimation(String content) {
  final cleaned = content
      .split('')
      .where((c) => c.trim().isNotEmpty && !isPunctuationChar(c))
      .join();
  if (cleaned.isEmpty) return false;
  return isPureCjk(cleaned) ||
      cleaned.split('').any(isArabicChar) ||
      cleaned.split('').any(isDevanagariChar);
}

/// awesome 动画阈值：每字时长 >200ms 且整词 >=1000ms 才走逐字。
const double kFastCharAnimationThresholdMs = 200.0;
const double kMinWordDurationForAwesomeMs = 1000.0;
const double kAwesomeDurationFactor = 0.8;
const double kMaxSimpleFloatOffsetY = 4.0;
const double kFixedSimpleAnimationDurationMs = 700.0;

// ── 音节拆解 ─────────────────────────────────────────────────────

/// 把 [LyricLine] 拆成音节列表。
///
/// - YRC（words 非空）：直接用每个 word。
/// - LRC（无逐字）：按 `_buildPseudoSyllables` 均分时间戳（与旧渲染一致，
///   保证行级歌词也能逐字揭示，LRC 降级方案）。
List<LyricSyllable> resolveSyllables(LyricLine line) {
  final words = line.words;
  if (words != null && words.isNotEmpty) {
    return [
      for (final w in words)
        if (w.text.isNotEmpty)
          LyricSyllable(
            content: w.text,
            startTimeMs: w.startTimeMs,
            endTimeMs: w.endTimeMs,
          ),
    ];
  }
  return _buildPseudoSyllables(line.text, line.startTimeMs, line.endTimeMs);
}

/// LRC 伪逐字：连续 ASCII 字母/数字合并为一个音节（保单词完整），其余每
/// 字符一个音节。时间在 [startMs, endMs] 间按字符数线性均分。
List<LyricSyllable> _buildPseudoSyllables(String text, int startMs, int endMs) {
  if (text.isEmpty) return const [];
  final total = text.length;
  final dur = endMs - startMs;
  final perChar = dur <= 0 ? 0.0 : dur / total;

  final asciiWordRe = RegExp(r'[a-zA-Z0-9]+');
  final out = <LyricSyllable>[];
  var i = 0;
  while (i < total) {
    var j = i + 1;
    final m = asciiWordRe.matchAsPrefix(text, i);
    if (m != null) j = m.end;
    out.add(
      LyricSyllable(
        content: text.substring(i, j),
        startTimeMs: startMs + (i * perChar).round(),
        endTimeMs: startMs + (j * perChar).round(),
      ),
    );
    i = j;
  }
  return out;
}

/// 按尾部空白把音节分组为单词。
List<List<LyricSyllable>> groupIntoWords(List<LyricSyllable> syllables) {
  if (syllables.isEmpty) return const [];
  final words = <List<LyricSyllable>>[];
  var currentWord = <LyricSyllable>[];
  for (final syllable in syllables) {
    currentWord.add(syllable);
    if (syllable.content.trimRight().length < syllable.content.length) {
      words.add(currentWord.toList());
      currentWord = <LyricSyllable>[];
    }
  }
  if (currentWord.isNotEmpty) {
    words.add(currentWord.toList());
  }
  return words;
}

// ── 度量 + 动画判定 ──────────────────────────────────────────────

/// 预测量全部音节，并为每个单词判定动画类型。
///
/// [glowColor] 仅用于 awesome 动画的发光层（软阴影），null 则不生成。
///
/// [allowAwesomeAnimation] 为 false 时强制全部走简单浮动（LRC 行级歌词没有
/// 逐字时间轴，伪逐字不应套用 awesome 跳动动画，仅静态揭示）。
List<SyllableLayout> measureSyllablesAndDetermineAnimation({
  required List<LyricSyllable> syllables,
  required TextStyle style,
  required double spaceWidth,
  Color? glowColor,
  bool allowAwesomeAnimation = true,
}) {
  final words = groupIntoWords(syllables);
  final out = <SyllableLayout>[];

  for (var wIndex = 0; wIndex < words.length; wIndex++) {
    final word = words[wIndex];
    final wordContent = word.map((s) => s.content).join();
    final wordDuration = word.isNotEmpty
        ? word.last.endTimeMs - word.first.startTimeMs
        : 0;
    final perCharDuration = wordContent.isNotEmpty && wordDuration > 0
        ? wordDuration / wordContent.length
        : 0.0;
    final useAwesomeAnimation =
        allowAwesomeAnimation &&
        perCharDuration > kFastCharAnimationThresholdMs &&
        wordDuration >= kMinWordDurationForAwesomeMs &&
        !shouldUseSimpleAnimation(wordContent);

    for (final syllable in word) {
      final painter = _measure(syllable.content, style);
      var width = painter.width;
      if (syllable.content.endsWith(' ')) {
        final trimmed = syllable.content.trimRight();
        final trimmedWidth = _measure(trimmed, style).width;
        if (width <= trimmedWidth) {
          width =
              trimmedWidth +
              spaceWidth * (syllable.content.length - trimmed.length);
        }
      }

      List<TextPainter>? charPainters;
      List<TextPainter>? charGlowPainters;
      List<double> charWidths = const [];
      if (useAwesomeAnimation) {
        charPainters = [];
        charGlowPainters = [];
        charWidths = [];
        for (final char in syllable.content.split('')) {
          charPainters.add(_measure(char, style));
          if (glowColor != null) {
            charGlowPainters.add(_measure(char, _withGlow(style, glowColor)));
          }
          charWidths.add(charPainters.last.width);
        }
      }

      out.add(
        SyllableLayout(
          syllable: syllable,
          textPainter: painter,
          wordId: wIndex,
          useAwesomeAnimation: useAwesomeAnimation,
          // LRC 伪逐字不允许任何逐字运动（含简单浮动）。
          allowFloat: allowAwesomeAnimation,
          width: width,
          firstBaseline: _baselineOf(painter),
          charPainters: charPainters,
          charGlowPainters: charGlowPainters,
          charWidths: charWidths,
        ),
      );
    }
  }
  return out;
}

TextPainter _measure(String text, TextStyle style) {
  return TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
}

TextStyle _withGlow(TextStyle style, Color color) {
  return style.copyWith(
    color: null,
    foreground: Paint()
      ..color = color.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
  );
}

double _baselineOf(TextPainter painter) {
  final metrics = painter.computeLineMetrics();
  return metrics.isEmpty ? 0.0 : metrics.first.baseline;
}

// ── 换行（平衡 DP 优先，贪心兜底）───────────────────────────────

List<WrappedLine> calculateBalancedLines({
  required List<SyllableLayout> syllableLayouts,
  required double availableWidth,
  required TextStyle style,
}) {
  if (syllableLayouts.isEmpty) return const [];

  final n = syllableLayouts.length;
  final costs = List<double>.filled(n + 1, double.infinity);
  final breaks = List<int>.filled(n + 1, 0);
  costs[0] = 0;

  for (var i = 1; i <= n; i++) {
    var currentLineWidth = 0.0;
    for (var j = i; j >= 1; j--) {
      if (j > 1 &&
          syllableLayouts[j - 2].wordId == syllableLayouts[j - 1].wordId) {
        currentLineWidth += syllableLayouts[j - 1].width;
        if (currentLineWidth > availableWidth) break;
        continue;
      }
      currentLineWidth += syllableLayouts[j - 1].width;
      if (currentLineWidth > availableWidth) break;

      final badness = math.pow(availableWidth - currentLineWidth, 2).toDouble();
      if (costs[j - 1].isFinite && costs[j - 1] + badness < costs[i]) {
        costs[i] = costs[j - 1] + badness;
        breaks[i] = j - 1;
      }
    }
  }

  if (!costs[n].isFinite) {
    return _calculateGreedyWrappedLines(syllableLayouts, availableWidth, style);
  }

  final lines = <WrappedLine>[];
  var currentIndex = n;
  while (currentIndex > 0) {
    final startIndex = breaks[currentIndex];
    final lineSyllables = syllableLayouts.sublist(startIndex, currentIndex);
    lines.insert(0, _trimDisplayLineTrailingSpaces(lineSyllables, style));
    currentIndex = startIndex;
  }
  return lines;
}

List<WrappedLine> _calculateGreedyWrappedLines(
  List<SyllableLayout> syllableLayouts,
  double availableWidth,
  TextStyle style,
) {
  final lines = <WrappedLine>[];
  final currentLine = <SyllableLayout>[];
  var currentLineWidth = 0.0;

  final wordGroups = <List<SyllableLayout>>[];
  if (syllableLayouts.isNotEmpty) {
    var currentWordGroup = <SyllableLayout>[];
    var currentWordId = syllableLayouts.first.wordId;
    for (final layout in syllableLayouts) {
      if (layout.wordId != currentWordId) {
        wordGroups.add(currentWordGroup);
        currentWordGroup = <SyllableLayout>[];
        currentWordId = layout.wordId;
      }
      currentWordGroup.add(layout);
    }
    wordGroups.add(currentWordGroup);
  }

  for (final wordSyllables in wordGroups) {
    final wordWidth = wordSyllables.fold<double>(0, (sum, s) => sum + s.width);
    if (currentLineWidth + wordWidth <= availableWidth) {
      currentLine.addAll(wordSyllables);
      currentLineWidth += wordWidth;
    } else {
      if (currentLine.isNotEmpty) {
        final trimmed = _trimDisplayLineTrailingSpaces(currentLine, style);
        if (trimmed.syllables.isNotEmpty) lines.add(trimmed);
        currentLine.clear();
        currentLineWidth = 0;
      }
      if (wordWidth <= availableWidth) {
        currentLine.addAll(wordSyllables);
        currentLineWidth += wordWidth;
      } else {
        for (final syllable in wordSyllables) {
          if (currentLineWidth + syllable.width > availableWidth &&
              currentLine.isNotEmpty) {
            final trimmed = _trimDisplayLineTrailingSpaces(currentLine, style);
            if (trimmed.syllables.isNotEmpty) lines.add(trimmed);
            currentLine.clear();
            currentLineWidth = 0;
          }
          currentLine.add(syllable);
          currentLineWidth += syllable.width;
        }
      }
    }
  }

  if (currentLine.isNotEmpty) {
    final trimmed = _trimDisplayLineTrailingSpaces(currentLine, style);
    if (trimmed.syllables.isNotEmpty) lines.add(trimmed);
  }
  return lines;
}

/// 去掉视觉行尾部的空白音节，并把最后一个音节的尾部空白修剪掉。
WrappedLine _trimDisplayLineTrailingSpaces(
  List<SyllableLayout> displayLineSyllables,
  TextStyle style,
) {
  if (displayLineSyllables.isEmpty) {
    return const WrappedLine(syllables: [], totalWidth: 0);
  }

  final processed = displayLineSyllables.toList();
  while (processed.isNotEmpty &&
      processed.last.syllable.content.trim().isEmpty) {
    processed.removeLast();
  }
  if (processed.isEmpty) {
    return const WrappedLine(syllables: [], totalWidth: 0);
  }

  final lastLayout = processed.last;
  final originalContent = lastLayout.syllable.content;
  final trimmedContent = originalContent.trimRight();
  if (trimmedContent.length < originalContent.length) {
    if (trimmedContent.isNotEmpty) {
      final trimmedPainter = _measure(trimmedContent, style);
      processed[processed.length - 1] = SyllableLayout(
        syllable: LyricSyllable(
          content: trimmedContent,
          startTimeMs: lastLayout.syllable.startTimeMs,
          endTimeMs: lastLayout.syllable.endTimeMs,
        ),
        textPainter: trimmedPainter,
        wordId: lastLayout.wordId,
        useAwesomeAnimation: lastLayout.useAwesomeAnimation,
        width: trimmedPainter.width,
        firstBaseline: lastLayout.firstBaseline,
        allowFloat: lastLayout.allowFloat,
        charPainters: lastLayout.charPainters,
        charGlowPainters: lastLayout.charGlowPainters,
        charWidths: lastLayout.charWidths,
      );
    } else {
      processed.removeLast();
    }
  }

  final totalWidth = processed.fold<double>(0, (sum, s) => sum + s.width);
  return WrappedLine(syllables: processed, totalWidth: totalWidth);
}

// ── 静态排版（定位 + wordPivot + charOffset）───────────────────

/// 把换行结果排版到画布坐标，写入每个音节的 position / wordPivot /
/// charOffsetInWord，返回按视觉行分组的 [SyllableLayout]。
List<List<SyllableLayout>> calculateStaticLineLayout({
  required List<WrappedLine> wrappedLines,
  required bool isLineRightAligned,
  required double canvasWidth,
  required double lineHeight,
  required bool isRtl,
}) {
  final layoutsByWord = <int, List<SyllableLayout>>{};
  final positionedLines = <List<SyllableLayout>>[];

  for (var lineIndex = 0; lineIndex < wrappedLines.length; lineIndex++) {
    final wrappedLine = wrappedLines[lineIndex];
    final maxBaselineInLine = wrappedLine.syllables.fold<double>(
      0,
      (m, s) => math.max(m, s.firstBaseline),
    );
    final rowTopY = lineIndex * lineHeight;
    final startX = isLineRightAligned
        ? canvasWidth - wrappedLine.totalWidth
        : 0.0;

    var currentX = isRtl ? startX + wrappedLine.totalWidth : startX;
    final positioned = <SyllableLayout>[];
    for (final initial in wrappedLine.syllables) {
      final positionX = isRtl ? currentX - initial.width : currentX;
      final verticalOffset = maxBaselineInLine - initial.firstBaseline;
      final positionY = rowTopY + verticalOffset;
      final positionedLayout = initial..position = Offset(positionX, positionY);
      layoutsByWord
          .putIfAbsent(positionedLayout.wordId, () => [])
          .add(positionedLayout);
      currentX += isRtl ? -initial.width : initial.width;
      positioned.add(positionedLayout);
    }
    positionedLines.add(positioned);
  }

  final animInfoByWord = <int, WordAnimationInfo>{};
  final charOffsetsBySyllable = <SyllableLayout, int>{};
  for (final entry in layoutsByWord.entries) {
    final layouts = entry.value;
    if (layouts.first.useAwesomeAnimation) {
      final wordStartTime = layouts
          .map((s) => s.syllable.startTimeMs)
          .reduce(math.min);
      final wordEndTime = layouts
          .map((s) => s.syllable.endTimeMs)
          .reduce(math.max);
      final wordContent = layouts.map((s) => s.syllable.content).join();
      final intensityBase =
          (wordEndTime -
              wordStartTime -
              kFastCharAnimationThresholdMs * wordContent.length) /
          1000;
      animInfoByWord[entry.key] = WordAnimationInfo(
        wordStartTime: wordStartTime,
        wordEndTime: wordEndTime,
        wordContent: wordContent,
        swellAmount: (0.1 * intensityBase).clamp(0.0, 0.1),
        awesomeDuration: math.max(
          1.0,
          (wordEndTime - wordStartTime) * kAwesomeDurationFactor,
        ),
      );
      var runningCharOffset = 0;
      for (final layout in layouts) {
        charOffsetsBySyllable[layout] = runningCharOffset;
        runningCharOffset += layout.syllable.content.length;
      }
    }
  }

  for (final line in positionedLines) {
    for (final positioned in line) {
      final wordLayouts = layoutsByWord[positioned.wordId]!;
      final minX = wordLayouts.map((s) => s.position.dx).reduce(math.min);
      final maxX = wordLayouts
          .map((s) => s.position.dx + s.width)
          .reduce(math.max);
      final bottomY = wordLayouts
          .map((s) => s.position.dy + s.textPainter.height)
          .reduce(math.max);
      positioned
        ..wordPivot = Offset((minX + maxX) / 2, bottomY)
        ..wordAnimInfo = animInfoByWord[positioned.wordId]
        ..charOffsetInWord = charOffsetsBySyllable[positioned] ?? 0;
    }
  }
  return positionedLines;
}

// ── 行渲染数据 ──────────────────────────────────────────────────

/// 计算每行渲染数据：渐变裁切边界 layerBounds。
List<RowRenderData> calculateRowRenderData(
  List<List<SyllableLayout>> lineLayouts, {
  double edgePadding = 8,
  bool isLineLevel = false,
}) {
  final rows = <RowRenderData>[];
  for (final rowLayouts in lineLayouts) {
    if (rowLayouts.isEmpty) continue;
    final totalMinX = rowLayouts.map((s) => s.position.dx).reduce(math.min);
    final totalMaxX = rowLayouts
        .map((s) => s.position.dx + s.width)
        .reduce(math.max);
    final totalWidth = totalMaxX - totalMinX;
    final minY = rowLayouts.map((s) => s.position.dy).reduce(math.min);
    final totalHeight = rowLayouts
        .map((s) => s.textPainter.height)
        .reduce(math.max);

    final verticalPadding = totalHeight * 0.1;
    final horizontalPadding = totalWidth * 0.2;
    rows.add(
      RowRenderData(
        rowLayouts: rowLayouts,
        totalMinX: totalMinX,
        totalMaxX: totalMaxX,
        totalWidth: totalWidth,
        firstSyllableStart: rowLayouts.first.syllable.startTimeMs,
        lastSyllableEnd: rowLayouts.last.syllable.endTimeMs,
        layerBounds: Rect.fromLTRB(
          totalMinX - horizontalPadding,
          minY - verticalPadding - edgePadding,
          totalMaxX + horizontalPadding,
          minY + totalHeight + verticalPadding + edgePadding,
        ),
        isLineLevel: isLineLevel,
      ),
    );
  }
  return rows;
}

// ── 顶层入口 ────────────────────────────────────────────────────

/// 完整测量一行 [LyricLine] 并排版。
LyricLineLayout measureLyricLine({
  required LyricLine line,
  required TextStyle style,
  required double availableWidth,
  Color? glowColor,
  List<Shadow>? shadows,
}) {
  // 对比投影：一次性并入基准 style，后续所有 _measure/发光层自然继承。
  final baseStyle =
      (shadows != null && shadows.isNotEmpty)
          ? style.copyWith(shadows: shadows)
          : style;
  final spaceWidth = _measure(' ', baseStyle).width;
  final syllables = resolveSyllables(line);
  if (syllables.isEmpty) {
    return const LyricLineLayout(rows: [], totalHeight: 0);
  }

  final measured = measureSyllablesAndDetermineAnimation(
    syllables: syllables,
    style: baseStyle,
    spaceWidth: spaceWidth,
    glowColor: glowColor,
    // LRC（无逐字时间轴）不启用 awesome 逐字动画，只走简单浮动/静态揭示。
    allowAwesomeAnimation: line.words?.isNotEmpty ?? false,
  );
  // 行高：`normalTextStyle.lineHeight = fontSize * 1.18`，
  // 但不得低于实际字体度量，避免 CJK 等被裁切。
  final lineHeight = math.max(
    _measure('M', baseStyle).height,
    (style.fontSize ?? 18) * 1.18,
  );

  final wrapped = calculateBalancedLines(
    syllableLayouts: measured,
    availableWidth: availableWidth,
    style: baseStyle,
  );
  if (wrapped.isEmpty) {
    return const LyricLineLayout(rows: [], totalHeight: 0);
  }

  final isRtl = measured.any((s) => isRtlText(s.syllable.content));
  final positioned = calculateStaticLineLayout(
    wrappedLines: wrapped,
    isLineRightAligned: isRtl,
    canvasWidth: availableWidth,
    lineHeight: lineHeight,
    isRtl: isRtl,
  );
  final rows = calculateRowRenderData(
    positioned,
    isLineLevel: !line.isWordLevel,
  );
  final totalHeight = lineHeight * wrapped.length;

  return LyricLineLayout(rows: rows, totalHeight: totalHeight);
}
