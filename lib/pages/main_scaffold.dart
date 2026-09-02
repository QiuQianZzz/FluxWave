import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:provider/provider.dart';

import '../constants/nav_thresholds.dart';
import '../core/navigation/album_navigation.dart';
import '../core/navigation/artist_navigation.dart';
import '../core/platform_utils.dart';
import '../core/update_service.dart';
import '../core/window_utils.dart';
import '../pages/album/album_detail_page.dart';
import '../pages/artist/artist_detail_page.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mini_player.dart';
import '../widgets/title_bar.dart';
import '../widgets/update_dialog.dart';
import 'home_page.dart';
import 'profile_page.dart';
import 'search_page.dart';
import 'settings/settings_page.dart';
import 'tab_navigator.dart';

const _kLogTag = '[TOAST]';

/// 主框架：响应式导航 + 迷你播放栏。
///
/// - 窄屏 (<600px, 手机)：BottomNavigationBar
/// - 宽屏 (>=600px, 桌面/平板)：可折叠侧边栏（72px ↔ 200px 动画切换）
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;
  bool _sidebarExpanded = true;
  bool _settingsDetailVisible = false;
  bool _profileDetailVisible = false;

  /// 每个 tab 的栈顶歌手路由 name（如 'artist/123'），null 表示该 tab 栈顶不是歌手页。
  /// 用于去重：避免从播放页多次点击同一歌手时重复 push。
  final List<String?> _tabArtistRoute = List.filled(4, null);

  static const _transitionDuration = Duration(milliseconds: 300);

  /// 每个 tab 的嵌套导航栈（切换 tab 后各栈独立存活，见 _PageSwitcher 常驻）。
  final List<GlobalKey<NavigatorState>> _tabNavKeys = List.generate(
    4,
    (_) => GlobalKey<NavigatorState>(),
  );

  /// 每个 tab 独立的 observer（NavigatorObserver 不能跨 Navigator 共享）。
  late final List<NavigatorObserver> _tabObservers = List.generate(
    4,
    (i) => _ArtistPopObserver(
      tabIndex: i,
      onRouteChanged: (routeName) => _tabArtistRoute[i] = routeName,
    ),
  );

  /// tab 根页列表。包 [TabNavigator]：tab 内 push（歌单详情/雷达页）不盖住
  /// 迷你播放栏与导航栏。[enabled] 只对当前 tab 打开——Offstage 常驻的非当前
  /// tab 不接管系统返回。
  ///
  /// 使用固定 ValueKey 确保 Flutter 按 key 匹配 TabNavigator State，
  /// 避免切换 tab 时 NavigatorPopHandler 内部 PopScope 重新注册。
  List<Widget> get _pages => [
    TabNavigator(
      key: const ValueKey('tab-0'),
      navigatorKey: _tabNavKeys[0],
      enabled: _currentIndex == 0,
      observer: _tabObservers[0],
      child: const HomePage(),
    ),
    TabNavigator(
      key: const ValueKey('tab-1'),
      navigatorKey: _tabNavKeys[1],
      enabled: _currentIndex == 1,
      observer: _tabObservers[1],
      child: const SearchPage(),
    ),
    TabNavigator(
      key: const ValueKey('tab-2'),
      navigatorKey: _tabNavKeys[2],
      enabled: _currentIndex == 2,
      observer: _tabObservers[2],
      child: ProfilePage(
        onDetailChanged: (visible) =>
            setState(() => _profileDetailVisible = visible),
      ),
    ),
    TabNavigator(
      key: const ValueKey('tab-3'),
      navigatorKey: _tabNavKeys[3],
      enabled: _currentIndex == 3,
      observer: _tabObservers[3],
      child: SettingsPage(
        onDetailChanged: (visible) =>
            setState(() => _settingsDetailVisible = visible),
      ),
    ),
  ];

  /// PlayerProvider 引用，用于 addListener/removeListener 监听跳过/试听提示。
  PlayerProvider? _playerRef;

  /// 是否已执行过启动更新检查（避免重复）。
  bool _updateChecked = false;

  /// Toast 消息队列：仅用于「同一帧内多条消息防覆盖」（点 A→K 弹出 A 的
  /// 根因）。用户快速切歌时新消息会清空队列 + 立即替换当前显示，避免
  /// 过时提示累积（否则 N 首歌会累积 N×3.2s 才消费完）。
  final Queue<String> _toastQueue = Queue<String>();
  Timer? _toastTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 设置静态回调（仅一次）
    ArtistNavigation.onNavigateToArtist = _navigateToArtistFromPlayer;
    AlbumNavigation.onNavigateToAlbum = _navigateToAlbumFromPlayer;
    final player = context.read<PlayerProvider>();
    if (_playerRef != player) {
      _playerRef?.removeListener(_onPlayerChanged);
      _playerRef = player;
      _playerRef?.addListener(_onPlayerChanged);
    }
    // 启动时检查更新（仅一次，设置开启时）
    if (!_updateChecked) {
      _updateChecked = true;
      final settings = context.read<SettingsProvider>();
      if (settings.checkUpdateOnStart) {
        // 延迟一帧，确保 UI 构建完成后再弹窗
        WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
      }
    }
  }

  @override
  void dispose() {
    _playerRef?.removeListener(_onPlayerChanged);
    _playerRef = null;
    _toastTimer?.cancel();
    // 避免 MainScaffold 重建后回调持有过期的 State 引用。
    ArtistNavigation.onNavigateToArtist = null;
    AlbumNavigation.onNavigateToAlbum = null;
    super.dispose();
  }

  /// 显示一条 Toast 消息。
  ///
  /// **策略**：替换式 + 防同帧覆盖。
  /// - 新消息立即清空队列 + 中断当前显示，立即显示新消息
  /// - 用户快速切歌时旧歌的过时提示不会累积
  /// - 同一帧内多条消息：第一条立即显示，后续进入 _toastQueue
  ///   在下一帧依次显示（但通常下一帧就会被新消息清空）
  void _enqueueToast(String msg) {
    debugPrint('$_kLogTag enqueue: $msg (queueSize=${_toastQueue.length + 1})');
    // 清空过时消息：用户已切歌，旧歌的试听/跳过提示无意义
    _toastQueue.clear();
    _toastQueue.add(msg);
    // 中断当前显示：立即显示新消息（如果正在显示）
    _toastTimer?.cancel();
    _showNextToast();
  }

  /// 从队列取下一条并显示。
  void _showNextToast() {
    if (_toastQueue.isEmpty) return;
    final msg = _toastQueue.removeFirst();
    debugPrint('$_kLogTag show: $msg (remaining=${_toastQueue.length})');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.show(context, msg);
      // 3s 后 AppToast 自动清除，3.2s 后取下一条（留 200ms 过渡缓冲）
      _toastTimer = Timer(const Duration(milliseconds: 3200), () {
        if (!mounted) return;
        _showNextToast();
      });
    });
  }

  /// 启动时检查更新：静默检查，有更新弹窗，无更新不提示。
  Future<void> _checkUpdate() async {
    try {
      if (!mounted) return;
      // 启动时清理残留的旧 APK 文件
      await UpdateService.instance.cleanOldApks();

      if (!mounted) return;
      final settings = context.read<SettingsProvider>();
      final info = await UpdateService.instance.check(
        includeBeta: settings.updateIncludeBeta,
      );
      if (!mounted || info == null) return;
      await UpdateDialog.show(context, info);
    } catch (_) {
      // 静默失败，不影响启动
    }
  }

  /// 监听 PlayerProvider 变化：跳过/试听提示统一处理。
  /// 不依赖任何 `.then()` 回调，所有入口（搜索点击 / 队列自动跳过 / 恢复
  /// 会话 / 上下一首切歌）都能触发。
  ///
  /// **重入保护**：_inPlayerListener 标志 + 入队时 addPostFrameCallback 异步，
  /// 避免在 Provider listener 回调中直接调用 setState/notifyListeners 触发
  /// Windows 端重入崩溃。
  bool _inPlayerListener = false;

  void _onPlayerChanged() {
    if (_inPlayerListener) return;
    _inPlayerListener = true;
    try {
      final player = _playerRef;
      if (player == null) return;
      _handleSkipNotice(player);
      _handleTrialNotice(player);
    } finally {
      _inPlayerListener = false;
    }
  }

  void _handleSkipNotice(PlayerProvider player) {
    if (!player.hasSkipNotice) return;
    final count = player.skipCount;
    final origin = player.skipOrigin ?? '';
    final stopReason = player.skipStopReason;
    final kind = player.skipKind;
    final current = player.currentSong;
    debugPrint(
      '$_kLogTag skipNotice: count=$count, origin=$origin, '
      'reason=$stopReason, kind=$kind, current=${current?.name}',
    );
    player.consumeSkipNotice();

    final failureLabel = kind == 'source' ? '源加载/网络失败' : '无版权或需会员';
    final String msg;
    if (stopReason != null) {
      final why = stopReason == 'overLimit' ? '已达最大自动跳过次数' : '已无可用后续歌曲';
      msg = count == 1
          ? '「$origin」$failureLabel，$why'
          : '「$origin」等 $count 首$failureLabel，$why';
    } else {
      final next = current?.name ?? '下一首';
      msg = count == 1
          ? '「$origin」$failureLabel，已跳至「$next」'
          : '「$origin」等 $count 首$failureLabel，已跳至「$next」';
    }
    _enqueueToast(msg);
  }

  void _handleTrialNotice(PlayerProvider player) {
    final trial = player.pendingTrialSongName;
    if (trial == null) return;
    debugPrint('$_kLogTag trialNotice: song=$trial');
    player.consumeTrialNotice();
    _enqueueToast('正在播放「$trial」试听片段（完整版需会员/付费）');
  }

  static const _navItems = <_NavItem>[
    _NavItem(
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
      label: '首页',
    ),
    _NavItem(
      icon: Icons.search_outlined,
      activeIcon: Icons.search_rounded,
      label: '搜索',
    ),
    _NavItem(
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      label: '我的',
    ),
    _NavItem(
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
      label: '设置',
    ),
  ];

  void _toggleSidebar() {
    setState(() => _sidebarExpanded = !_sidebarExpanded);
  }

  void _onTabSelected(int index) {
    if (index == _currentIndex) return;
    if (context.read<SettingsProvider>().hapticFeedback) {
      HapticFeedback.selectionClick();
    }
    setState(() => _currentIndex = index);
  }

  /// 从播放页跳转歌手页：pop 播放页（根 Navigator）→ push 歌手页到当前 tab Navigator。
  ///
  /// 若当前 tab 栈顶已是歌手页面，用 pushReplacement 替换，保证栈里最多只有一个歌手页。
  void _navigateToArtistFromPlayer(int id, String name) {
    final rootNav = Navigator.of(context);
    if (rootNav.canPop()) rootNav.pop();

    final tabNav = _tabNavKeys[_currentIndex].currentState;
    if (tabNav == null) return;

    final routeName = 'artist/$id';
    final page = MaterialPageRoute(
      builder: (_) => ArtistDetailPage(artistId: id, artistName: name),
      settings: RouteSettings(name: routeName),
    );

    final hasArtistOnTop = _tabArtistRoute[_currentIndex] != null;
    if (hasArtistOnTop) {
      // 先 pop 旧歌手页，再 push 新的，避免 pushReplacement 在边界条件下空栈。
      tabNav.pop();
      tabNav.push(page);
    } else {
      tabNav.push(page);
    }
    _tabArtistRoute[_currentIndex] = routeName;
  }

  void _navigateToAlbumFromPlayer(int id, String name) {
    final rootNav = Navigator.of(context);
    if (rootNav.canPop()) rootNav.pop();

    final tabNav = _tabNavKeys[_currentIndex].currentState;
    if (tabNav == null) return;

    final routeName = 'album/$id';
    final page = MaterialPageRoute(
      builder: (_) => AlbumDetailPage(albumId: id, albumName: name),
      settings: RouteSettings(name: routeName),
    );
    tabNav.push(page);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final blur = context.select<SettingsProvider, bool>((s) => s.glassBlur);
    final isCompact = width < 600;
    // 歌曲启停时更新滚动内容底部留白（含小播放器高度动态加成），
    // 通过 Provider<double> 注入给所有页面的 PageScrollView / PageListView；
    // 页面用 Provider.of<double>(listen:false) 读取，测试无此 Provider 时自动兜底基础值。
    final hasSong = context.select<PlayerProvider, bool>(
      (p) => p.currentSong != null,
    );
    final mq = MediaQuery.of(context);
    // 键盘弹出时导航/小播放器被键盘遮挡（固定在屏幕底部），页面无需为它们预留留白。
    final keyboardOpen = mq.viewInsets.bottom > 0;
    // 小窗模式使用动态高度
    final clearance = keyboardOpen
        ? 0.0
        : WindowUtils.pageBottomClearance(
            context,
            hasSong: hasSong,
            keyboardOpen: keyboardOpen,
          );
    return Provider<double?>.value(
      value: clearance,
      child: Stack(
        children: [
          if (isCompact)
            _buildCompact(context)
          else
            _buildExtended(context, blur: blur),
          // 浮动导航 + 小播放器放在 Scaffold 外层 Stack，固定在屏幕底部，
          // 完全与键盘无联动（键盘弹出时两者都不上浮，由 Scaffold body 内的
          // 页面内容自行调整）。
          if (isCompact) ...[
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildCompactNavBar(blur: blur),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: WindowUtils.floatingNavHeight(context) + mq.padding.bottom,
                ),
                child: const MiniPlayer(),
              ),
            ),
          ],
          const _ToastOverlay(),
        ],
      ),
    );
  }

  // ── 窄屏：页面内容 ──
  // 浮动导航 + 小播放器由 build() 放在 Scaffold 外层 Stack（固定，键盘无联动），
  // 本方法只管页面内容。
  Widget _buildCompact(BuildContext context) {
    return Scaffold(
      body: _PageSwitcher(
        index: _currentIndex,
        duration: _transitionDuration,
        onSwiped: _onTabSelected,
        dragEnabled: !_settingsDetailVisible && !_profileDetailVisible,
        children: _pages,
      ),
    );
  }

  /// 窄屏底部导航：贴边全宽悬浮在内容上方，玻璃向下延伸覆盖系统手势区
  /// （配合系统导航栏透明）。开启毛玻璃时半透明玻璃，关闭时实色。
  ///
  /// 关键：必须先剥掉 NavigationBar 内部 SafeArea 按系统 inset 垫高的高度（否则
  /// 整条比设计高一大截、悬浮时向上顶到小播放器），再包 SafeArea(top:false) 让
  /// 玻璃只向下延伸覆盖手势区。
  Widget _buildCompactNavBar({required bool blur}) {
    final cs = Theme.of(context).colorScheme;
    final bar = NavigationBar(
      selectedIndex: _currentIndex,
      onDestinationSelected: _onTabSelected,
      labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
      backgroundColor: Colors.transparent,
      elevation: 0,
      destinations: [
        for (final item in _navItems)
          NavigationDestination(
            icon: Icon(item.icon),
            selectedIcon: Icon(item.activeIcon),
            label: item.label,
            // 禁用长按悬浮提示（SDK 默认以 label 作 tooltip）
            tooltip: '',
          ),
      ],
    );
    final strippedBar = MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      child: bar,
    );
    // 玻璃语言统一走 [GlassSurface]（sigma/描边统一，导航偏实保证图标可读）。
    return GlassSurface(
      enabled: blur,
      topAlpha: 0.78,
      bottomAlpha: 0.6,
      solidColor: cs.surface,
      border: Border(
        top: BorderSide(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.6,
        ),
      ),
      child: SafeArea(top: false, child: strippedBar),
    );
  }

  // ── 宽屏：可折叠侧边栏 ──
  Widget _buildExtended(BuildContext context, {required bool blur}) {
    final theme = Theme.of(context);
    final isDesktop = PlatformUtils.isDesktop && TitleBar.enabled;

    return Scaffold(
      body: Column(
        children: [
          // 桌面端自定义标题栏（全宽）
          if (isDesktop) const TitleBar(),
          Expanded(
            child: Row(
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(
                    begin: _sidebarExpanded ? 0 : 1,
                    end: _sidebarExpanded ? 1 : 0,
                  ),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOutCubic,
                  builder: (context, t, child) {
                    final sidebarWidth = 72 + 128 * t; // 72 ↔ 200
                    final showText = t > 0.5;
                    // 侧边栏玻璃：开启毛玻璃时半透明渐变 + 真模糊，关闭时实色。
                    // GlassSurface 内部 ClipRRect 已负责按宽度裁剪。
                    return SizedBox(
                      width: sidebarWidth,
                      child: GlassSurface(
                        enabled: blur,
                        topAlpha: 0.72,
                        bottomAlpha: 0.55,
                        baseColor: theme.colorScheme.surfaceContainerLow,
                        solidColor: theme.colorScheme.surfaceContainerLow,
                        border: Border(
                          right: BorderSide(
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                        child: Column(
                          children: [
                            // 桌面端无 Logo（标题栏已含），非桌面端保留侧边栏 Logo
                            if (!isDesktop) ...[
                              _buildLogo(theme, showText),
                              const SizedBox(height: 8),
                            ] else
                              const SizedBox(height: 8),
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                children: [
                                  for (int i = 0; i < _navItems.length; i++)
                                    _buildNavTile(theme, i, showText),
                                ],
                              ),
                            ),
                            _buildToggle(theme, showText),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                Expanded(
                  // 迷你播放器悬浮覆盖在内容区底部（与窄屏一致），周围透明。
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _FadeTabStack(
                          index: _currentIndex,
                          children: _pages,
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: const MiniPlayer(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Logo：简约 primaryContainer 方块图标 + 文字，去渐变。
  Widget _buildLogo(ThemeData theme, bool showText) {
    final cs = theme.colorScheme;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: showText
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.graphic_eq_rounded,
              color: cs.onPrimaryContainer,
              size: 22,
            ),
          ),
          if (showText) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'FluxWave',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
                overflow: TextOverflow.clip,
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNavTile(ThemeData theme, int index, bool showText) {
    final item = _navItems[index];
    final selected = _currentIndex == index;
    final cs = theme.colorScheme;
    final color = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    final bg = selected ? cs.secondaryContainer : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _onTabSelected(index),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: showText ? 16 : 0,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: showText
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Icon(
                  selected ? item.activeIcon : item.icon,
                  color: color,
                  size: 22,
                ),
                if (showText) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      item.label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: color,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      overflow: TextOverflow.clip,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToggle(ThemeData theme, bool showText) {
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _toggleSidebar,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: showText ? 16 : 0,
              vertical: 10,
            ),
            child: Row(
              mainAxisAlignment: showText
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                if (showText) ...[
                  Flexible(
                    child: Text(
                      '收起',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.clip,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Icon(
                  showText ? Icons.chevron_left_rounded : Icons.menu_rounded,
                  color: cs.onSurfaceVariant,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

/// 桌面端 tab 切换容器：与移动端 [_PageSwitcher] 对齐的「全 tab 常驻」语义。
///
/// 取代旧的 [AnimatedSwitcher]（其过渡结束后会把旧 tab 从树上卸下，导致切走
/// 的 tab 丢失详情/返回栈）。这里所有 tab 常驻树上（非当前页 Offstage），
/// 切 tab 时旧页淡出 + 新页淡入并轻微滑入（0.03 偏移），观感贴近原实现。
class _FadeTabStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const _FadeTabStack({required this.index, required this.children});

  @override
  State<_FadeTabStack> createState() => _FadeTabStackState();
}

class _FadeTabStackState extends State<_FadeTabStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _current = 0;

  /// 过渡起始页（过渡完成后重置为 null）。
  int? _from;

  @override
  void initState() {
    super.initState();
    _current = widget.index;
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
          value: 1.0,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _from = null);
          }
        });
  }

  @override
  void didUpdateWidget(_FadeTabStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _from = _current;
      _current = widget.index;
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final from = _from;
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
    final children = <Widget>[];
    for (var i = 0; i < widget.children.length; i++) {
      Widget child = widget.children[i];
      if (i == _current && from != null) {
        // 过渡中：新页淡入 + 轻微滑入
        child = FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.03, 0),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          ),
        );
      } else if (i == from) {
        // 过渡中：旧页淡出
        child = FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0).animate(curve),
          child: child,
        );
      }
      children.add(
        Offstage(offstage: i != _current && i != from, child: child),
      );
    }
    return Stack(fit: StackFit.expand, children: children);
  }
}

/// 移动端页面切换器：tab 点击 + 左右拖动，共享同一套水平滑动渲染。
///
/// - Tab 点击：直接从当前页滑到目标页（仅渲染2页，不经过中间页）
/// - 左右拖动：跟随手指移动相邻页面，松手后完成或回弹
/// - GestureDetector 支持鼠标拖动（桌面窄窗）和触摸拖动（手机）
class _PageSwitcher extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Duration duration;
  final ValueChanged<int> onSwiped;
  final bool dragEnabled;

  const _PageSwitcher({
    required this.index,
    required this.children,
    required this.duration,
    required this.onSwiped,
    this.dragEnabled = true,
  });

  @override
  State<_PageSwitcher> createState() => _PageSwitcherState();
}

class _PageSwitcherState extends State<_PageSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 当前完全显示的页面索引
  int _current = 0;

  /// 过渡起始页（过渡中 _current 是目标页；idle 时 == _current）
  int _from = 0;

  /// 回弹动画的目标邻接页（null 表示非回弹状态）
  int? _snapBack;

  /// 拖动进度：正=向右拖(看上一页)，负=向左拖(看下一页)，0=未拖动
  double _drag = 0;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _current = widget.index;
    _from = widget.index;
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..value = 1.0
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          // 正向过渡完成（tab 点击 / 拖动完成）
          _from = _current;
          _snapBack = null;
          _controller.value = 1.0;
          setState(() {});
        } else if (status == AnimationStatus.dismissed && _snapBack != null) {
          // 回弹动画完成（仅 _snapBack 非空时才清理，
          // tab 点击设 value=0.0 触发的 dismissed 不处理）
          _snapBack = null;
          _controller.value = 1.0;
          setState(() {});
        }
      });
  }

  @override
  void didUpdateWidget(_PageSwitcher old) {
    super.didUpdateWidget(old);
    // Tab 点击触发的程序化切换（拖动中忽略）
    if (widget.index != _current && !_isDragging) {
      _from = _current;
      _current = widget.index;
      _snapBack = null;
      _drag = 0;
      _controller.value = 0.0;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── 拖动手势 ──

  void _onDragStart(DragStartDetails _) {
    _isDragging = true;
    _controller.stop();
    _drag = 0;
    _snapBack = null;
    _from = _current;
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails d, double width) {
    final delta = d.primaryDelta! / width;
    var next = _drag + delta;
    // 边界：第一页不能向右拖(无上一页)，最后一页不能向左拖(无下一页)
    if (_current == 0 && next > 0) next = 0;
    if (_current == widget.children.length - 1 && next < 0) next = 0;
    // 限制在同一屏内：避免过度拖拽超过完整页宽，导致邻近页完全移出而失真
    _drag = next.clamp(-1.0, 1.0);
    setState(() {});
  }

  void _onDragEnd(DragEndDetails d) {
    _isDragging = false;
    if (_drag == 0) {
      setState(() {});
      return;
    }

    final velocity = d.primaryVelocity ?? 0;
    final absDrag = _drag.abs();
    final dir = _drag.sign; // +1=右(上一页), -1=左(下一页)

    // 判定是否完成切换：拖动超过阈值或快速 fling（统一 NavThresholds）
    final shouldComplete = NavThresholds.shouldComplete(
      dragRatio: absDrag,
      velocity: velocity,
      drag: _drag,
    );

    if (shouldComplete) {
      final target = _current - dir.toInt();
      if (target >= 0 && target < widget.children.length) {
        _from = _current;
        _current = target;
        _drag = 0;
        _snapBack = null;
        _controller.value = absDrag;
        _animateTo(1.0, absDrag);
        widget.onSwiped(target);
        setState(() {});
        return;
      }
    }

    // 回弹
    _snapBack = _current - dir.toInt();
    _from = _current;
    _drag = 0;
    if (_snapBack! >= 0 && _snapBack! < widget.children.length) {
      _controller.value = absDrag;
      // 回弹：固定舒适时长（不随距离缩水），从松开位置平滑滑回原页，
      // 修复此前 300ms×拖拽比例 导致小拖动"瞬弹"的问题。
      // 固定时长下拖得越远滑回越快、拖得越近越从容，符合物理直觉。
      _controller.animateTo(
        0.0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _snapBack = null;
      _controller.value = 1.0;
    }
    setState(() {});
  }

  /// 按剩余距离缩放时长的动画，速度与完整过渡一致。
  void _animateTo(double target, double fromProgress) {
    final remaining = (target - fromProgress).abs();
    final ms = (widget.duration.inMilliseconds * remaining).round().clamp(
      50,
      widget.duration.inMilliseconds,
    );
    _controller.animateTo(
      target,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
  }

  // ── 渲染 ──

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        return GestureDetector(
          onHorizontalDragStart: widget.dragEnabled ? _onDragStart : null,
          onHorizontalDragUpdate: widget.dragEnabled
              ? (d) => _onDragUpdate(d, width)
              : null,
          onHorizontalDragEnd: widget.dragEnabled ? _onDragEnd : null,
          behavior: HitTestBehavior.translucent,
          child: ClipRect(child: _buildContent(width)),
        );
      },
    );
  }

  Widget _buildContent(double width) {
    // 拖动中：当前页 + 邻接页
    if (_isDragging && _drag != 0) {
      final adjacent = _current - _drag.sign.toInt();
      if (adjacent >= 0 && adjacent < widget.children.length) {
        return _buildStack(width, _current, adjacent, _drag.abs());
      }
    }

    // 回弹中：当前页 + 邻接页，进度从 absDrag → 0
    if (_snapBack != null) {
      final t = _controller.value;
      if (t > 0) return _buildStack(width, _current, _snapBack!, t);
    }

    // 过渡中（tab 点击或拖动完成）：起始页 + 目标页
    if (_from != _current) {
      final t = _controller.value;
      if (t < 1.0) return _buildStack(width, _from, _current, t);
    }

    // 静态态：全 tab 常驻，非当前页 Offstage（保住各自嵌套导航栈 State，
    // 切走后返回仍显示原详情页；发送给 find 的默认 skipOffstage 不影响）。
    return _buildSettled();
  }

  /// 常驻渲染：所有 tab 都挂在树上，仅当前页可见。
  ///
  /// 每个 tab 统一包在 `Offstage → Transform.translate` 里，与 [_buildStack]
  /// 的结构完全一致——切换动画只改 Transform 偏移，不改变 Offstage/Transform
  /// 的包装类型，从而保证 tab 内嵌套 Navigator（及其路由栈）不被销毁重建。
  Widget _buildSettled() {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != _current,
            child: Transform.translate(
              offset: Offset.zero,
              child: widget.children[i],
            ),
          ),
      ],
    );
  }

  /// 两页并排滑动渲染。
  /// [fromIdx] 起始页（t=0 时居中），[toIdx] 目标页（t=1 时居中）。
  /// 方向自动由索引大小决定，永不反转。所有 tab 统一 `Offstage → Transform`
  /// 包装（同 [_buildSettled]），仅非参与页 offstage、参与页平移——
  /// 不改变包装类型，Navigator State 跨动画保留。
  Widget _buildStack(double width, int fromIdx, int toIdx, double t) {
    final dir = toIdx > fromIdx ? 1.0 : -1.0;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != fromIdx && i != toIdx,
            child: Transform.translate(
              offset: i == fromIdx
                  ? Offset(-dir * t * width, 0)
                  : i == toIdx
                      ? Offset(dir * (1 - t) * width, 0)
                      : Offset.zero,
              child: widget.children[i],
            ),
          ),
      ],
    );
  }
}

/// Toast 显示层：监听 AppToast.message，从顶部滑入。
///
/// 放在 MainScaffold 的 Stack 最顶层，确保不被 TitleBar / MiniPlayer /
/// NavigationBar 遮挡。不拦截下方交互（IgnorePointer）。
class _ToastOverlay extends StatefulWidget {
  const _ToastOverlay();

  @override
  State<_ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<_ToastOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  /// 上一条消息：用于判断 ValueNotifier 变化时是否需要重播动画。
  String? _lastMsg;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: AppToast.message,
      builder: (context, msg, _) {
        if (msg == null) {
          _lastMsg = null;
          return const SizedBox.shrink();
        }
        // 新消息到来时重播滑入动画
        if (msg != _lastMsg) {
          _lastMsg = msg;
          _ctrl.forward(from: 0.0);
        }
        return _buildToast(context, msg);
      },
    );
  }

  Widget _buildToast(BuildContext context, String msg) {
    final cs = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);
    final titleBarH = TitleBar.enabled ? 38.0 : 0.0;
    final top = mq.padding.top + titleBarH + 12;

    final slide = Tween<Offset>(
      begin: const Offset(0, -1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: SlideTransition(
          position: slide,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Material(
                color: cs.inverseSurface,
                borderRadius: BorderRadius.circular(12),
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    msg,
                    style: TextStyle(color: cs.onInverseSurface, fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 监听 tab Navigator 的 push/pop 事件，精确追踪栈顶歌手路由。
///
/// 用 `didPush` + `didPop` 双向追踪，比只靠 pop 更可靠：
/// - push 歌手页时记录 routeName
/// - pop 歌手页时清除（回退到 null）
/// - pop 非歌手页时不清除（歌手页还在栈里）
class _ArtistPopObserver extends NavigatorObserver {
  final int tabIndex;
  final void Function(String? routeName) onRouteChanged;
  _ArtistPopObserver({required this.tabIndex, required this.onRouteChanged});

  @override
  void didPush(Route route, Route? previousRoute) {
    final name = route.settings.name;
    if (name != null && name.startsWith('artist/')) {
      onRouteChanged(name);
    }
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    final name = route.settings.name;
    if (name != null && name.startsWith('artist/')) {
      // 歌手页被 pop，恢复到前一个路由的状态（可能是 null 或另一个歌手页）
      final prevName = previousRoute?.settings.name;
      onRouteChanged(
        (prevName != null && prevName.startsWith('artist/')) ? prevName : null,
      );
    }
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    final oldName = oldRoute?.settings.name;
    final newName = newRoute?.settings.name;
    final wasArtist = oldName?.startsWith('artist/') == true;
    final isArtist = newName?.startsWith('artist/') == true;
    if (wasArtist || isArtist) {
      onRouteChanged(isArtist ? newName : null);
    }
  }
}
