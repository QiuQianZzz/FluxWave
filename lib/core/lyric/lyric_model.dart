/// 歌词数据模型。
///
/// `words == null` 表示行级 LRC（整行一个时间戳）；
/// `words` 非空表示逐字 YRC（每字带独立时间戳）。
library;

/// 逐字单元：单个字/词的时间片段。
class LyricWord {
  final String text;
  final int startTimeMs;
  final int endTimeMs;

  const LyricWord({
    required this.text,
    required this.startTimeMs,
    required this.endTimeMs,
  });

  int get charCount => text.length;
}

/// 一行歌词。
class LyricLine {
  /// 整行文本（= words 拼接，或 LRC 行原文）。
  final String text;

  /// 行起始毫秒。
  final int startTimeMs;

  /// 行结束毫秒（LRC 由倒序填充，YRC 由行头 start+dur 精确计算）。
  final int endTimeMs;

  /// 逐字时间片；null = 行级 LRC，非空 = 逐字 YRC。
  final List<LyricWord>? words;

  /// 翻译歌词（时间戳对齐后填入，可能为空字符串）。
  final String? translation;

  /// 罗马音歌词（时间戳对齐后填入）。
  final String? roman;

  const LyricLine({
    required this.text,
    required this.startTimeMs,
    required this.endTimeMs,
    this.words,
    this.translation,
    this.roman,
  });

  /// 是否逐字。
  bool get isWordLevel => words != null && words!.isNotEmpty;

  LyricLine copyWith({String? translation, String? roman}) {
    return LyricLine(
      text: text,
      startTimeMs: startTimeMs,
      endTimeMs: endTimeMs,
      words: words,
      translation: translation ?? this.translation,
      roman: roman ?? this.roman,
    );
  }
}
