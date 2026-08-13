/// 逐行歌词（LRC，无逐字时间轴）当前行的揭示方式。
///
/// 仅影响 LRC 行级歌词；逐字 YRC 歌词恒走逐字动画，不受此设置影响。
enum LineLyricRevealMode {
  /// 线性扫过：整行单一颜色渐变，随播放进度线性前移。
  linearSweep,

  /// 纯静态：整行固定 active 色，无渐变、无逐字。
  staticLine;

  /// 展示名（设置页选项标签）。
  String get label => switch (this) {
    LineLyricRevealMode.linearSweep => '线性扫过',
    LineLyricRevealMode.staticLine => '纯静态（整行固定色）',
  };
}
