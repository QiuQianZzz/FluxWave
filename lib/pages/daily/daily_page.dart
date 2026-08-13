import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../providers/daily_provider.dart';
import '../../providers/netease_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/page_scroll_view.dart';
import '../../widgets/song_tile.dart';

/// 「每日推荐」页：登录后每日 30 首专属歌曲（weapi recommend/songs）。
///
/// 与歌单详情同款歌曲列表：序号 + 封面 + 歌名/歌手 + 时长 + 付费角标，
/// 点击播放整单、长按/右键菜单（下一首播放/追加末尾）。顶部展示逻辑日
  /// （每日 6 点翻新）与「播放全部」。
///
/// 进入即预取一次（进页 postFrame 显式触发，对齐雷达页纪律）；下拉刷新/重试
/// 走 [DailyProvider.reload]，重复进入不重拉。
class DailyPage extends StatefulWidget {
  const DailyPage({super.key});

  @override
  State<DailyPage> createState() => _DailyPageState();
}

class _DailyPageState extends State<DailyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final netease = context.read<NeteaseProvider>();
      // 只在 api 就绪时预取（对齐 HomePage._bootstrap 的 apiReady 门控）；
      // 未登录由入口页拦截，这里兜底避免走到未初始化 api。
      if (!netease.apiReady) return;
      final provider = context.read<DailyProvider>();
      if (!provider.loaded) {
        provider.load(netease.api);
      }
    });
  }

  void _playAll(List<Song> songs) {
    if (songs.isEmpty) return;
    context.read<PlayerProvider>().playAt(songs, 0);
  }

  void _playAt(List<Song> songs, int index) {
    context.read<PlayerProvider>().playAt(songs, index);
  }

  void _playNext(Song song) {
    context.read<PlayerProvider>().playNext(song);
    AppToast.show(context, '已添加到下一首播放「${song.name}」');
  }

  void _addToQueue(Song song) {
    context.read<PlayerProvider>().addToQueue(song);
    AppToast.show(context, '已添加到播放列表「${song.name}」');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('每日推荐')),
      body: SafeArea(
        child: Consumer<DailyProvider>(
          builder: (context, daily, _) {
            return RefreshIndicator(
              onRefresh: () => context.read<DailyProvider>().reload(
                context.read<NeteaseProvider>().api,
              ),
              child: _buildBody(daily),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(DailyProvider daily) {
    final songs = daily.songs;
    if (!daily.loaded && daily.error == null) {
      return const PageScrollView(
        // 加载中锁死滚动（对齐首页/雷达页：loading 期不响应下拉）。
        physics: NeverScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }
    if (daily.error != null && songs.isEmpty) {
      return PageScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _DailyError(
              onRetry: () => context.read<DailyProvider>().reload(
                context.read<NeteaseProvider>().api,
              ),
            ),
          ),
        ],
      );
    }
    if (songs.isEmpty) {
      return const PageScrollView(
        physics: AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('今天还没有每日推荐')),
          ),
        ],
      );
    }
    return PageScrollView(
      physics: daily.loading
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
      slivers: [
        SliverToBoxAdapter(
          child: _DailyHeader(songs: songs, onPlayAll: () => _playAll(songs)),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: SliverFixedExtentList(
            itemExtent: SongTile.kTileExtent,
            delegate: SliverChildBuilderDelegate(
              (context, i) => SongTile(
                song: songs[i],
                index: i,
                onTap: () => _playAt(songs, i),
                onPlayNext: () => _playNext(songs[i]),
                onAddToQueue: () => _addToQueue(songs[i]),
              ),
              childCount: songs.length,
            ),
          ),
        ),
      ],
    );
  }
}

/// 每日推荐头部：逻辑日（每日 6:00 翻新）+ 曲目数 + 播放全部。
class _DailyHeader extends StatelessWidget {
  final List<Song> songs;
  final VoidCallback onPlayAll;
  const _DailyHeader({required this.songs, required this.onPlayAll});

  static const int _refreshHour = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 逻辑日：今日 6 点前仍算前一天。
    final now = DateTime.now();
    final logical = now.hour < _refreshHour
        ? now.subtract(const Duration(days: 1))
        : now;
    final dayLabel = '${logical.month}月${logical.day}日';
    final weekday = _weekday(logical);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '今天听点什么',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$dayLabel $weekday · 每日专属 ${songs.length} 首',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: songs.isEmpty ? null : onPlayAll,
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            label: const Text('播放全部'),
          ),
        ],
      ),
    );
  }

  static String _weekday(DateTime d) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[d.weekday - 1];
  }
}

/// 失败占位：提示 + 重试。
class _DailyError extends StatelessWidget {
  final VoidCallback onRetry;
  const _DailyError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 40, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('每日推荐加载失败', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
