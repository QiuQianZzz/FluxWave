import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/app_nav.dart';
import '../../models/playlist.dart';
import '../../providers/netease_provider.dart';
import '../../providers/radar_provider.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/page_scroll_view.dart';
import '../playlist/playlist_detail_page.dart';

/// 「雷达歌单」合集页：7 个账号专属雷达（私人/会员/时光/乐迷/宝藏/新歌/神秘）。
///
/// 与首页推荐网格区分：首项「私人雷达」通栏横幅 + 其余自适应横卡网格
/// （`maxCrossAxisExtent`，窄屏单列=横卡列表、宽屏自动多列），不用首页同款
/// 方片网格，避免「同布局另一个入口」的观感。仅从首页入口卡（登录后）进入；
/// 数据在进入本页时才预取，逐项容忍失败。
class RadarPage extends StatefulWidget {
  const RadarPage({super.key});

  @override
  State<RadarPage> createState() => _RadarPageState();
}

class _RadarPageState extends State<RadarPage> {
  @override
  void initState() {
    super.initState();
    // 等首帧后再拉：load 会同步 notifyListeners，start 帧内触发会打
    // "markNeedsBuild during build"；postFrame 后与首页错峰同理。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<RadarProvider>();
      if (!provider.loaded) {
        provider.load(context.read<NeteaseProvider>().api);
      }
    });
  }

  void _openPlaylist(Playlist p) {
    // 落在本 tab 的嵌套 Navigator上：雷达歌单详情不盖住导航栏/迷你播放栏。
    AppNav.push(context, PlaylistDetailPage(playlistId: p.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('雷达歌单')),
      body: Consumer<RadarProvider>(
        builder: (context, radar, _) {
          return RefreshIndicator(
            onRefresh: () => context.read<RadarProvider>().reload(
              context.read<NeteaseProvider>().api,
            ),
            child: PageScrollView(
              physics: radar.loading
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
              slivers: [
                if (!radar.loaded && radar.error == null)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 40),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  )
                else if (radar.error != null && radar.radars.isEmpty)
                  _RadarError(
                    onRetry: () => context.read<RadarProvider>().reload(
                      context.read<NeteaseProvider>().api,
                    ),
                  )
                else if (radar.radars.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('暂无雷达歌单')),
                  )
                else ...[
                  // 首项（私人雷达）通栏横幅
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: _RadarBanner(
                        radar: radar.radars.first,
                        onTap: () => _openPlaylist(radar.radars.first),
                      ),
                    ),
                  ),
                  // 其余雷达：自适应横卡网格
                  if (radar.radars.length > 1)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 420,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 2.9,
                            ),
                        delegate: SliverChildBuilderDelegate((context, i) {
                          final p = radar.radars[i + 1];
                          return _RadarCard(
                            radar: p,
                            onTap: () => _openPlaylist(p),
                          );
                        }, childCount: radar.radars.length - 1),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 首项雷达的通栏横幅：封面打底 + 渐变蒙层 + 名称/简介。
class _RadarBanner extends StatelessWidget {
  final Playlist radar;
  final VoidCallback onTap;
  const _RadarBanner({required this.radar, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final url = radar.coverSmall;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 148,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (url != null && url.isNotEmpty)
                  CoverImage(url: url)
                else
                  Container(color: cs.primaryContainer),
                // 渐变蒙层垫底，保证文字可读
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        cs.scrim.withValues(alpha: 0.75),
                        cs.scrim.withValues(alpha: 0.15),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.radar, size: 20, color: Colors.white),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              radar.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (radar.description != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            radar.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 横卡：左封面 + 右名称/简介，窄屏单列即「列表」观感，宽屏自动多列。
class _RadarCard extends StatelessWidget {
  final Playlist radar;
  final VoidCallback onTap;
  const _RadarCard({required this.radar, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final url = radar.coverSmall;
    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: SizedBox.square(
                dimension: 80,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: (url != null && url.isNotEmpty)
                      ? CoverImage(url: url, placeholder: _fallback(cs))
                      : _fallback(cs),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      radar.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Flexible 吞掉剩余高度：大字号下 2 行描述放不下时
                    // 由 Text 自身省略，避免 RenderFlex 溢出。
                    Flexible(
                      child: Text(
                        radar.description ??
                            (radar.trackCount != null
                                ? '${radar.trackCount}首'
                                : ''),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(
                Icons.chevron_right_rounded,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme cs) => Container(
    color: cs.surfaceContainerHigh,
    child: Center(
      child: Icon(
        Icons.radar,
        size: 32,
        color: cs.onSurfaceVariant.withValues(alpha: 0.4),
      ),
    ),
  );
}

/// 失败占位：提示 + 重试。
class _RadarError extends StatelessWidget {
  final VoidCallback onRetry;
  const _RadarError({required this.onRetry});

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
              Text('雷达歌单加载失败', style: theme.textTheme.titleSmall),
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
