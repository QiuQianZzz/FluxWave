/// 歌词弹簧动画强度档位。
///
/// 档位只表达"阻尼系数"：阻尼越大越"沉"、越不容易回弹。实际弹簧参数由
/// [computeLinePosYSpringParams]（lyric_spring_state.dart）按档位阻尼系数
/// 计算——soft/standard 为过阻尼（无回弹，仅速度差异），bouncy 欠阻尼
/// （可见回弹）。posY 弹簧换句时按相邻间隔动态重算，缩放弹簧固定。
enum LyricSpringPreset {
  /// 轻弹：阻尼最大，过渡最柔和，无回弹。
  soft,

  /// 标准：默认档位，平稳顺滑，无回弹。
  standard,

  /// 强弹：阻尼最小，有明显回弹。
  bouncy;

  /// 展示名（设置页档位标签）。
  String get label => switch (this) {
    LyricSpringPreset.soft => '轻弹',
    LyricSpringPreset.standard => '标准',
    LyricSpringPreset.bouncy => '强弹',
  };
}
