import 'package:flutter/material.dart';

/// 主 Tab 页共用的「大标题 → 钉顶小标题」单行塌缩标题
/// （LargeTopAppBar 风格：展开态大字号、顶部留白充足；滚动后缩为稍小一档并常驻顶部，
/// 不会缩到 toolbar 那档过小字号）。
///
/// 两种接入方式：
/// - **[SliverAppBar] 模式（Home / 设置）**：作为 `flexibleSpace` 传入，高度由
///   SliverAppBar 自动在 [expandedHeight] ↔ [collapsedHeight] 间动画；内部
///   `LayoutBuilder` 读实时高度算进度，不依赖 `FlexibleSpaceBarSettings`。
/// - **固定区块模式（搜索页）**：[progress] 非空，按外部换算的滚动进度在
///   [expandedHeight] ↔ [collapsedHeight] 间改自身高度（结果列表滚动驱动）。
class CollapsingPinnedTitle extends StatelessWidget {
  final String text;

  /// 标题行尾随组件（如首页的 Dev 角标），展开/钉顶两态都在。
  final Widget? trailing;

  /// 展开态总高（含顶部留白）。
  final double expandedHeight;

  /// 钉顶态高，默认 toolbar 高度（56）。
  final double collapsedHeight;

  /// 非空 = 固定区块模式（自身高度按进度收缩）；null = SliverAppBar 模式
  /// （高度由 flexibleSpace 约束自动给，用 LayoutBuilder 读实时高度）。
  final double? progress;

  const CollapsingPinnedTitle({
    super.key,
    required this.text,
    this.trailing,
    required this.expandedHeight,
    this.collapsedHeight = kToolbarHeight,
    this.progress,
  }) : assert(expandedHeight > collapsedHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bigStyle = theme.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
    );
    final pinnedStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );

    Widget content(double t) {
      return Row(
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle.lerp(bigStyle, pinnedStyle, t),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      );
    }

    if (progress != null) {
      // 固定区块模式：自身高度按进度收缩，文字底部锚定贴着下方搜索框。
      final t = progress!.clamp(0.0, 1.0);
      final height = expandedHeight + (collapsedHeight - expandedHeight) * t;
      return SizedBox(
        height: height,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned(left: 20, right: 20, bottom: 12, child: content(t)),
            ],
          ),
        ),
      );
    }

    // SliverAppBar 模式：flexibleSpace 高度随滚动在 expandedHeight↔collapsedHeight
    // 间变化，LayoutBuilder 读实时高度。ClipRect 兜底超大字号不抛溢出。
    return LayoutBuilder(
      builder: (context, constraints) {
        final t =
            ((expandedHeight - constraints.maxHeight) /
                    (expandedHeight - collapsedHeight))
                .clamp(0.0, 1.0);
        return ClipRect(
          child: Stack(
            children: [
              Positioned(left: 20, right: 20, bottom: 16, child: content(t)),
            ],
          ),
        );
      },
    );
  }
}
