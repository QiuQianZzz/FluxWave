import 'package:flutter/material.dart';

import '../../core/platform_utils.dart';
import '../../widgets/collapsing_title.dart';
import '../../widgets/page_scroll_view.dart';
import '../backup_page.dart';
import 'sections/about_section.dart';
import 'sections/account_section.dart';
import 'sections/network_section.dart';
import 'sections/play_section.dart';
import 'sections/storage_section.dart';
import 'sections/theme_section.dart';

/// 设置页：导航第 4 项。
///
/// 使用状态切换（非 Navigator.push）在列表 ↔ 详情间切换，
/// 详情页仅替换内容区域，侧边栏和迷你播放栏保持可见。
/// 列表 ↔ 详情过渡动画：移动端水平平移，桌面端淡入淡出 + 轻微滑入。
class SettingsPage extends StatefulWidget {
  final ValueChanged<bool>? onDetailChanged;

  const SettingsPage({super.key, this.onDetailChanged});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  SettingsEntry? _selected;
  late final AnimationController _controller;

  static const _duration = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        // 移动端回弹完成：清除详情页，通知父级恢复拖动
        if (status == AnimationStatus.dismissed && _selected != null) {
          setState(() => _selected = null);
          widget.onDetailChanged?.call(false);
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isCompact => MediaQuery.sizeOf(context).width < 600;

  void _select(SettingsEntry entry) {
    setState(() => _selected = entry);
    if (_isCompact) _controller.forward();
    widget.onDetailChanged?.call(true);
  }

  void _back() {
    if (_isCompact) {
      _controller.reverse(); // 完成后由 statusListener 清除 _selected 并通知父级
    } else {
      setState(() => _selected = null); // 桌面端由 AnimatedSwitcher 处理过渡
      widget.onDetailChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 详情态拦截系统返回（手势/按键）：回设置列表而非直接退出应用。
    // canPop: 列表态允许常规 pop（等价退出应用）；详情态拒绝 pop 并转 _back()。
    return PopScope<Object?>(
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: _isCompact ? _buildCompact() : _buildExtended(),
    );
  }

  // ── 移动端：水平平移切换（详情从右侧滑入，列表向左滑出）──
  Widget _buildCompact() {
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        final t = _controller.value;
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            Transform.translate(
              offset: Offset(-t * width, 0),
              child: _SettingsList(onSelected: _select),
            ),
            if (_selected != null)
              Transform.translate(
                offset: Offset((1 - t) * width, 0),
                child: _SettingsDetail(entry: _selected!, onBack: _back),
              ),
          ],
        );
      },
    );
  }

  // ── 桌面端：淡入淡出 + 轻微滑入（同路由动画）──
  Widget _buildExtended() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeInOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      transitionBuilder: _detailTransition,
      layoutBuilder: _stackLayoutBuilder,
      child: KeyedSubtree(
        key: ValueKey(_selected != null ? 'detail' : 'list'),
        child: _selected != null
            ? _SettingsDetail(entry: _selected!, onBack: _back)
            : _SettingsList(onSelected: _select),
      ),
    );
  }

  /// 桌面端过渡：incoming 页面淡入 + 3% 滑入，outgoing 仅淡出。
  Widget _detailTransition(Widget child, Animation<double> animation) {
    final isIncoming =
        child.key == ValueKey(_selected != null ? 'detail' : 'list');
    if (isIncoming) {
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.03, 0.0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      );
    }
    return FadeTransition(opacity: animation, child: child);
  }

  static Widget _stackLayoutBuilder(
    Widget? currentChild,
    List<Widget> previousChildren,
  ) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: <Widget>[...previousChildren, ?currentChild],
    );
  }
}

/// 设置列表页。
class _SettingsList extends StatelessWidget {
  final ValueChanged<SettingsEntry> onSelected;
  const _SettingsList({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: PageScrollView(
          slivers: [
            // ── 「设置」大标题（常驻钉顶）──
            // 主 Tab 的 LargeTopAppBar 折叠：展开态大字标题随滚动
            // 塌缩成稍小一档的标题常驻顶部（跨页共享 CollapsingPinnedTitle）。
            SliverAppBar(
              pinned: true,
              primary: false,
              automaticallyImplyLeading: false,
              backgroundColor: cs.surface,
              expandedHeight: 128,
              flexibleSpace: const CollapsingPinnedTitle(
                text: '设置',
                expandedHeight: 128,
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  for (final e in _kEntries)
                    if (!e.androidOnly || PlatformUtils.isAndroid)
                      ListTile(
                        leading: Icon(e.icon, color: cs.onSurfaceVariant),
                        title: Text(e.title),
                        subtitle: Text(
                          e.subtitle,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => onSelected(e),
                      ),
                  const SizedBox(height: 16),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置详情页：返回按钮 + 标题 + section 内容。
///
/// 渲染在内容区域内（非全屏路由），侧边栏和迷你播放栏保持可见。
class _SettingsDetail extends StatelessWidget {
  final SettingsEntry entry;
  final VoidCallback onBack;
  const _SettingsDetail({required this.entry, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 返回按钮 + 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 20, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: onBack,
                  ),
                  Flexible(
                    child: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // section 内容
            Expanded(child: entry.builder(context)),
          ],
        ),
      ),
    );
  }
}

/// 设置项定义。
class SettingsEntry {
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  /// 是否仅 Android 平台显示该入口（如将来的运行时功能/权限类设置项）。
  ///
  /// 当前没有入口使用此开关（桌面图标已并入「外观」），列表渲染逻辑仍保留
  /// 该分支，供后续新增 Android-only 设置项时直接置 true 使用。
  final bool androidOnly;

  const SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
    this.androidOnly = false,
  });
}

const _kEntries = <SettingsEntry>[
  SettingsEntry(
    icon: Icons.palette_outlined,
    title: '外观',
    subtitle: '主题模式、种子颜色、桌面图标',
    builder: ThemeSection.builder,
  ),
  SettingsEntry(
    icon: Icons.play_circle_outlined,
    title: '播放',
    subtitle: '音质、均衡器',
    builder: PlaySection.builder,
  ),
  SettingsEntry(
    icon: Icons.storage_outlined,
    title: '存储',
    subtitle: '缓存、下载路径',
    builder: StorageSection.builder,
  ),
  SettingsEntry(
    icon: Icons.wifi_rounded,
    title: '网络与风控',
    subtitle: 'IP 注入、系统代理',
    builder: NetworkSection.builder,
  ),
  SettingsEntry(
    icon: Icons.backup_outlined,
    title: '备份与恢复',
    subtitle: '导出/导入用户数据',
    builder: BackupPage.builder,
  ),
  SettingsEntry(
    icon: Icons.person_outline_rounded,
    title: '账号',
    subtitle: '登录管理',
    builder: AccountSection.builder,
  ),
  SettingsEntry(
    icon: Icons.info_outline_rounded,
    title: '关于',
    subtitle: '版本、开源协议',
    builder: AboutSection.builder,
  ),
];
