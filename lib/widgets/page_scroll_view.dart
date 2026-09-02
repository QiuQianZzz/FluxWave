import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/window_utils.dart';

/// 悬浮底部导航高度（M3 NavigationBar 默认高）。MainScaffold 与 [PageScrollView] 共用，
/// 避免两处各自写死漂移。
///
/// 注意：小窗模式下应使用 [WindowUtils.floatingNavHeight] 获取动态值。
const double kFloatingNavHeight = 80;

/// 迷你播放器悬浮于导航上方，额外占用的高度（卡片高 + 底部内边距 + 间距）。
/// 由 MainScaffold 在播放时计入注入的留白值，页面滚动容器自动读取。
///
/// 注意：小窗模式下应使用 [WindowUtils.miniPlayerClearance] 获取动态值。
const double kMiniPlayerClearance = 100;

/// 页面滚动内容底部留白（不含小播放器）：导航高度 + 系统底部手势区 inset + 间距。
/// 键盘弹出时导航被键盘遮挡，留白归零。
///
/// 仅在 MainScaffold 未注入留白值时的兜底（测试 / 页面独立渲染场景）；
/// 真实应用中 MainScaffold 会通过 `Provider<double>` 注入播放中额外叠加的小播放器高度。
///
/// 小窗模式下自动缩减留白高度。
double _baseClearance(BuildContext context) {
  final mq = MediaQuery.of(context);
  if (mq.viewInsets.bottom > 0) return 0;
  // 小窗模式使用动态高度
  if (WindowUtils.isSmallWindow(context)) {
    return WindowUtils.floatingNavHeight(context) + mq.padding.bottom + 4;
  }
  return kFloatingNavHeight + mq.padding.bottom + 16;
}

/// 读取滚动底部留白：MainScaffold 注入值（含小播放器动态加成），兜底读
/// [_baseClearance]。供 [PageScrollView]、[PageListView] 及
/// `ListView.builder` 等非标准滚动场景直接使用。
double scrollBottomClearance(BuildContext context) =>
    Provider.of<double?>(context, listen: false) ?? _baseClearance(context);

/// 页面内容滚动容器（CustomScrollView）：自动在滚动内容底部预留留白，让列表最后一项
/// 能滚到悬浮导航上方完全露出；播放时再额外叠加小播放器高度。
///
/// 留白值由 MainScaffold 通过 `Provider<double>` 注入（含小播放器动态加成），
/// 兜底读 [_baseClearance]（无注入 / 测试 / 页面独立渲染），不依赖 PlayerProvider。
///
/// 未来新页面一律使用本组件（或 [PageListView]），无需再手动适配悬浮导航。
class PageScrollView extends StatelessWidget {
  final List<Widget> slivers;
  final ScrollPhysics? physics;
  final Key? scrollKey;

  const PageScrollView({
    super.key,
    required this.slivers,
    this.physics,
    this.scrollKey,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: scrollKey,
      physics: physics,
      slivers: [
        ...slivers,
        SliverToBoxAdapter(
          child: SizedBox(height: scrollBottomClearance(context)),
        ),
      ],
    );
  }
}

/// 页面内容滚动容器（ListView）：同 [PageScrollView]，用于 ListView 型页面。
class PageListView extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets? padding;
  final ScrollPhysics? physics;

  const PageListView({
    super.key,
    required this.children,
    this.padding,
    this.physics,
  });

  @override
  Widget build(BuildContext context) {
    final base = padding ?? EdgeInsets.zero;
    return ListView(
      physics: physics,
      padding: base + EdgeInsets.only(bottom: scrollBottomClearance(context)),
      children: children,
    );
  }
}
