import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_build_info.dart';
import '../core/navigation/app_nav.dart';
import '../core/window_utils.dart';
import '../models/playlist.dart';
import '../providers/home_provider.dart';
import '../providers/netease_provider.dart';
import '../widgets/collapsing_title.dart';
import '../widgets/cover_image.dart';
import '../widgets/dev_badge.dart';
import '../widgets/page_scroll_view.dart';
import 'playlist/playlist_detail_page.dart';
import 'daily/daily_page.dart';
import 'radar/radar_page.dart';

/// 首页 Tab：欢迎信息 + 快捷入口 + 推荐歌单（真实数据，匿名可用）。
///
/// 推荐歌单在 Netease api 就绪后拉取一次（[HomeProvider] 内存态，重拉走
/// 下拉刷新/错误重试），点击卡片进 [PlaylistDetailPage]。下载中/失败/空
/// 均有明确占位，不显示假数据。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// 等 Netease 初始化流程走完、api 就绪后再拉推荐歌单（匿名即可用）。
  /// 启动错峰 300ms：避免与匿名注册/登录校验挤在同一瞬间打并发请求
  /// （风控友好；这里让首包延迟一拍无害）。
  Future<void> _bootstrap() async {
    final netease = context.read<NeteaseProvider>();
    await netease.initializedFuture;
    if (!mounted) return;
    if (!netease.apiReady) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    context.read<HomeProvider>().load(netease.api);
  }

  void _openPlaylist(Playlist p) {
    // 落在本 tab 的嵌套 Navigator 上：歌单详情不盖住导航栏/迷你播放栏。
    AppNav.push(context, PlaylistDetailPage(playlistId: p.id));
  }

  /// 雷达页入口：未登录引导扫码登录（雷达按账号生成），登录后进合集页。
  void _openRadar() {
    final netease = context.read<NeteaseProvider>();
    if (!netease.isLoggedIn) {
      AppNav.pushNamedGlobal(context, '/login/qr');
      return;
    }
    AppNav.push(context, const RadarPage());
  }

  /// 每日推荐入口：需登录（每日 30 首按账号生成），未登录引导扫码登录。
  void _openDaily() {
    final netease = context.read<NeteaseProvider>();
    if (!netease.isLoggedIn) {
      AppNav.pushNamedGlobal(context, '/login/qr');
      return;
    }
    AppNav.push(context, const DailyPage());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Consumer<HomeProvider>(
          builder: (context, home, _) {
            return ScrollConfiguration(
              // 桌面端也允许鼠标拖拽滚动，这样 Windows 上按住下拉能触发
              // RefreshIndicator（默认只响应触屏拖拽）；显式刷新按钮兜底。
              behavior: const _RefreshIndicatorScrollBehavior(),
              child: RefreshIndicator(
                onRefresh: () => context.read<HomeProvider>().reload(
                  context.read<NeteaseProvider>().api,
                ),
                child: PageScrollView(
                  // 用 bounce（iOS 语义）承载下拉刷新：下拉内容随指示器下移、
                  // 收回即回顶，不会像 clamping 那样「反向立即把内容正向滚入视口」。
                  // 刷新进行中（loading）直接锁死滚动。
                  physics: home.loading
                      ? const NeverScrollableScrollPhysics()
                      : const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                  slivers: [
                    // ── 欢迎标题（常驻钉顶）──
                    // 主 Tab 的 LargeTopAppBar 折叠：展开态大标题
                    // 「FluxWave」随滚动高度塌缩成稍小一档的标题常驻顶部。
                    // 用 Stack + ClipRect 而非 Flex 列实现交叉淡化：超大字号下内容
                    // 超高时被裁剪而非抛 RenderFlex overflow（布局测试兜底）。
                    // 小窗模式下减小展开高度。
                    SliverAppBar(
                      pinned: true,
                      primary: false,
                      automaticallyImplyLeading: false,
                      backgroundColor: theme.colorScheme.surface,
                      expandedHeight: WindowUtils.sliverAppBarHeight(context),
                      flexibleSpace: CollapsingPinnedTitle(
                        text: 'FluxWave',
                        expandedHeight: WindowUtils.sliverAppBarHeight(context),
                        trailing: AppBuildInfo.isDebug
                            ? const DevBadge()
                            : null,
                      ),
                    ),
                    // ── 快捷入口 ──
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            Expanded(
                              child: _QuickCard(
                                icon: Icons.trending_up_rounded,
                                label: '每日推荐',
                                sublabel: '根据口味精选',
                                onTap: _openDaily,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _QuickCard(
                                icon: Icons.radar,
                                label: '私人雷达',
                                sublabel: '每日专属雷达',
                                onTap: _openRadar,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ── 推荐歌单标题 ──
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                '推荐歌单',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                            // 显式刷新：桌面端无触屏下拉时也可靠；加载中显示菊花。
                            if (home.loading)
                              const Padding(
                                padding: EdgeInsets.all(8),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            else
                              IconButton(
                                tooltip: '刷新推荐歌单',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    context.read<HomeProvider>().reload(
                                      context.read<NeteaseProvider>().api,
                                    ),
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 20,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    // ── 推荐歌单内容（加载/失败/空/网格四态） ──
                    if (!home.loaded && home.error == null)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 40),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      )
                    else if (home.error != null && home.playlists.isEmpty)
                      _SlideError(
                        onRetry: () => context.read<HomeProvider>().reload(
                          context.read<NeteaseProvider>().api,
                        ),
                      )
                    else if (home.playlists.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: Text('暂无推荐歌单')),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 180,
                                mainAxisSpacing: 16,
                                crossAxisSpacing: 16,
                                childAspectRatio: 0.82,
                              ),
                          delegate: SliverChildBuilderDelegate((context, i) {
                            final p = home.playlists[i];
                            return _PlaylistCard(
                              playlist: p,
                              onTap: () => _openPlaylist(p),
                            );
                          }, childCount: home.playlists.length),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 失败占位：提示 + 重试。
class _SlideError extends StatelessWidget {
  final VoidCallback onRetry;
  const _SlideError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text('推荐歌单加载失败', style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 简约描边快捷卡片：surface 底 + outline 图标。
class _QuickCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final VoidCallback? onTap;
  const _QuickCard({
    required this.icon,
    required this.label,
    required this.sublabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 96),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: cs.primary, size: 24),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      sublabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 推荐歌单卡片：真实封面（[CoverImage] 处理 CDN 头）+ 歌单名 + 曲数。
class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onTap;
  const _PlaylistCard({required this.playlist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final url = playlist.coverSmall;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox.square(
                dimension: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: (url != null && url.isNotEmpty)
                      ? CoverImage(
                          url: url,
                          placeholder: CoverPlaceholder(
                            borderRadius: 14,
                            borderColor: cs.outlineVariant.withValues(alpha: 0.4),
                            iconColor: cs.onSurfaceVariant.withValues(alpha: 0.4),
                          ),
                        )
                      : CoverPlaceholder(
                          borderRadius: 14,
                          borderColor: cs.outlineVariant.withValues(alpha: 0.4),
                          iconColor: cs.onSurfaceVariant.withValues(alpha: 0.4),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            if (playlist.trackCount != null)
              Text(
                '${playlist.trackCount}首',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

}

/// 让鼠标也参与拖拽滚动，桌面端下拉即可触发 [RefreshIndicator]。
class _RefreshIndicatorScrollBehavior extends MaterialScrollBehavior {
  const _RefreshIndicatorScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
