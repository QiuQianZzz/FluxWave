import 'lyric_model.dart';
import 'ttml_parser.dart';

/// 歌词解析器。
///
/// 支持：
/// - LRC 行级格式：`[mm:ss.xx]文本`
/// - YRC 逐字格式：`[start,dur](start,dur,0)字(start,dur,0)字...`
/// - 翻译/罗马音按时间戳双指针对齐（300ms 容差）
class LyricParser {
  const LyricParser();

  // ── LRC 行级解析 ───────────────────────────────────────────

  static final _lrcTimestampRe = RegExp(
    r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?]',
  );

  /// 解析 LRC 文本为行级 [LyricLine] 列表。
  ///
  /// - 跳过元数据行（`[ti:...]`/`[ar:...]` 等，无数字时间戳的方括号）
  /// - 倒序填充 endTime：下一行 start，末行 +5s 兜底
  /// - 按 startTimeMs 升序输出
  static List<LyricLine> parseLrc(String content) {
    if (content.isEmpty) return const [];

    final entries = <_LrcEntry>[];
    for (final raw in content.split(RegExp(r'[\r\n]'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      // 提取行首所有连续时间戳（支持 [00:12.34][00:56.78]共享歌词）
      final matches = _lrcTimestampRe.allMatches(line).toList();
      if (matches.isEmpty) continue;

      // 第一个时间戳后的文本 = 歌词内容
      final textStart = matches.last.end;
      final text = line.substring(textStart).trim();
      // 跳过元数据：[ti:xxx] [ar:xxx] 等已被正则过滤（无数字），
      // 但 [12345] 这种纯数字方括号也匹配时间戳 → 需过滤明显非时间戳的
      // 实际 _lrcTimestampRe 要求 mm:ss 格式，[ti:] 不会匹配

      for (final m in matches) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final msStr = m.group(3) ?? '0';
        var ms = int.parse(msStr);
        // 2 位毫秒 → ×10；1 位 → ×100
        if (msStr.length == 2) ms *= 10;
        if (msStr.length == 1) ms *= 100;
        final timeMs = min * 60000 + sec * 1000 + ms;
        entries.add(_LrcEntry(timeMs, text));
      }
    }

    if (entries.isEmpty) return const [];
    entries.sort((a, b) => a.timeMs.compareTo(b.timeMs));

    // 倒序填充 endTime
    final out = <LyricLine>[];
    int? nextStart;
    for (var i = entries.length - 1; i >= 0; i--) {
      final e = entries[i];
      if (e.text.isEmpty) {
        nextStart = e.timeMs;
        continue;
      }
      final end = nextStart ?? (e.timeMs + 5000);
      out.add(LyricLine(text: e.text, startTimeMs: e.timeMs, endTimeMs: end));
      nextStart = e.timeMs;
    }
    return out.reversed.toList(growable: false);
  }

  // ── YRC 逐字解析 ───────────────────────────────────────────

  static final _yrcLineRe = RegExp(r'\[(\d{1,19}),\s*(\d{1,19})\]');
  static final _yrcWordRe = RegExp(
    r'\((\d{1,19}),\s*(\d{1,19}),\s*[-\d]{1,20}\)([^()\n\r]*)',
  );

  /// 检测是否为 YRC 格式。
  static bool isYrc(String content) =>
      content.contains(RegExp(r'\[\d{1,19},\s*\d{1,19}\]\(\d{1,19},'));

  /// 解析 YRC 逐字文本为 [LyricLine] 列表。
  ///
  /// 格式：`[startMs,durMs](startMs,durMs,0)字(startMs,durMs,0)字...`
  /// - 行头：`[start, dur]` → 行 startTime = start，endTime = start + dur
  /// - 字级：`(start, dur, style)text` → word startTime = start，endTime = start + dur
  static List<LyricLine> parseYrc(String content) {
    if (content.isEmpty) return const [];

    final out = <LyricLine>[];
    for (final raw in content.split(RegExp(r'[\r\n]'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      final headerMatch = _yrcLineRe.firstMatch(line);
      if (headerMatch == null) continue;

      final lineStart = int.parse(headerMatch.group(1)!);
      final lineDur = int.parse(headerMatch.group(2)!);
      final lineEnd = lineStart + lineDur;

      // 字级匹配从行头之后开始
      final wordSection = line.substring(headerMatch.end);
      final words = <LyricWord>[];
      final textBuf = StringBuffer();

      for (final m in _yrcWordRe.allMatches(wordSection)) {
        final wStart = int.parse(m.group(1)!);
        final wDur = int.parse(m.group(2)!);
        final wText = m.group(3) ?? '';
        if (wText.isEmpty) continue;
        words.add(
          LyricWord(text: wText, startTimeMs: wStart, endTimeMs: wStart + wDur),
        );
        textBuf.write(wText);
      }

      final text = textBuf.toString();
      if (text.isEmpty && words.isEmpty) continue;

      out.add(
        LyricLine(
          text: text,
          startTimeMs: lineStart,
          endTimeMs: lineEnd,
          words: words.isEmpty ? null : words,
        ),
      );
    }

    out.sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));
    return out;
  }

  // ── TTML 逐字解析 ────────────────────────────────────────

  /// 检测是否为 TTML 格式。
  static bool isTtml(String content) {
    final trimmed = content.trim();
    return trimmed.startsWith('<tt') ||
        trimmed.contains('xmlns="http://www.w3.org/ns/ttml"');
  }

  /// 解析 TTML 逐字文本为 [LyricLine] 列表。
  static List<LyricLine> parseTtml(String ttmlContent) {
    if (ttmlContent.isEmpty) return const [];
    try {
      return TtmlParser.parse(ttmlContent);
    } catch (_) {
      return const [];
    }
  }

  // ── 自动分发 ───────────────────────────────────────────────

  /// 自动识别格式并解析。
  static List<LyricLine> parseAuto(String content) {
    if (content.isEmpty) return const [];
    if (isTtml(content)) {
      try {
        return parseTtml(content);
      } catch (_) {
        return const [];
      }
    }
    if (isYrc(content)) return parseYrc(content);
    return parseLrc(content);
  }

  // ── 翻译/罗马音对齐 ────────────────────────────────────────

  /// 翻译对齐容差。
  static const alignToleranceMs = 300;

  /// 将翻译/罗马音按时间戳对齐到主歌词行。
  ///
  /// 双指针按 startTimeMs 对齐，容差 [alignToleranceMs]。
  /// 无效翻译（空、`//`、版权声明）跳过。
  static List<LyricLine> alignTranslation(
    List<LyricLine> main,
    List<LyricLine> trans, {
    bool isRoman = false,
  }) {
    if (main.isEmpty || trans.isEmpty) return main;

    var j = 0;
    var result = main.toList();
    for (var i = 0; i < result.length; i++) {
      final mainLine = result[i];
      // 持续推进 j 直到翻译行 start 超过主行 start+容差，保留容差内最优匹配。
      var bestJ = -1;
      var bestDelta = alignToleranceMs;
      while (j < trans.length) {
        final t = trans[j];
        final delta = (t.startTimeMs - mainLine.startTimeMs).abs();
        if (delta <= bestDelta) {
          bestDelta = delta;
          bestJ = j;
          j++;
          continue; // 继续看下一行是否更接近
        }
        // 翻译行已超过主行+容差，后续只会更远，停止
        if (t.startTimeMs > mainLine.startTimeMs + alignToleranceMs) break;
        // 翻译行早于主行-容差，跳过
        if (t.startTimeMs < mainLine.startTimeMs - alignToleranceMs) {
          j++;
          continue;
        }
        // 在容差外但未触发上述边界（理论上不会到这里，保险 break）
        break;
      }
      if (bestJ >= 0) {
        final tText = trans[bestJ].text;
        if (_isMeaningfulTranslation(tText)) {
          result[i] = isRoman
              ? mainLine.copyWith(roman: tText)
              : mainLine.copyWith(translation: tText);
        }
      }
    }
    return result;
  }

  /// 过滤无效翻译文本。
  static bool _isMeaningfulTranslation(String text) {
    final t = text.trim();
    if (t.isEmpty || t == '//') return false;
    if (t.contains('作品的著作权')) return false;
    return true;
  }

  // ── 当前行定位 ─────────────────────────────────────────────

  /// 二分查找当前时间对应的行索引。
  ///
  /// 返回最后一个 `startTimeMs <= timeMs` 的行索引；
  /// 空列表返回 -1，时间早于首行返回 0。
  static int findCurrentLineIndex(List<LyricLine> lines, int timeMs) {
    if (lines.isEmpty) return -1;
    var low = 0;
    var high = lines.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      if (lines[mid].startTimeMs <= timeMs) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  // ── 行内进度 ───────────────────────────────────────────────

  /// 计算当前行内播放进度 0..1。
  ///
  /// - 逐字行：累加已完成字符数，当前字内插值
  /// - 行级行：整句线性推进
  static double calculateLineProgress(LyricLine line, int timeMs) {
    if (timeMs <= line.startTimeMs) return 0;
    if (timeMs >= line.endTimeMs) return 1;

    final words = line.words;
    if (words == null || words.isEmpty) {
      final dur = line.endTimeMs - line.startTimeMs;
      return dur <= 0 ? 0 : ((timeMs - line.startTimeMs) / dur).clamp(0.0, 1.0);
    }

    var totalChars = 0;
    for (final w in words) {
      totalChars += w.charCount;
    }
    if (totalChars == 0) return 0;

    var completed = 0;
    for (final w in words) {
      if (timeMs < w.startTimeMs) {
        return (completed / totalChars).clamp(0.0, 1.0);
      }
      if (timeMs < w.endTimeMs) {
        final wordDur = w.endTimeMs - w.startTimeMs;
        final partial = wordDur <= 0 ? 0 : (timeMs - w.startTimeMs) / wordDur;
        final partialChars = partial * w.charCount;
        return ((completed + partialChars) / totalChars).clamp(0.0, 1.0);
      }
      completed += w.charCount;
    }
    return 1;
  }
}

/// LRC 解析中间态。
class _LrcEntry {
  final int timeMs;
  final String text;
  _LrcEntry(this.timeMs, this.text);
}
