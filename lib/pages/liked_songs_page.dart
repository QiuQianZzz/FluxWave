import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/liked_songs_provider.dart';
import '../providers/player_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/page_scroll_view.dart';
import '../widgets/song_tile.dart';

/// 我喜欢的音乐页：收藏列表（最新在前，实时跟随 provider）。
///
/// 数据不重新拉取，直接 watch [LikedSongsProvider.songs]——播放页/通知栏
/// 收藏后本页即时反映；「取消收藏」就地移除行。
class LikedSongsPage extends StatelessWidget {
  const LikedSongsPage({super.key});

  void _playAt(BuildContext context, List<Song> songs, int index) {
    if (songs.isEmpty) return;
    // 播放为异步启动，fire-and-forget：队列切到目标曲由 PlayerProvider 管理，
    // 无需等待 URL 解析完成再继续 UI。
    context.read<PlayerProvider>().playAt(songs, index);
  }

  void _playAll(BuildContext context, List<Song> songs) {
    if (songs.isEmpty) return;
    context.read<PlayerProvider>().playAt(songs, 0);
  }

  void _playNext(BuildContext context, Song song) {
    context.read<PlayerProvider>().playNext(song);
    AppToast.show(context, '已添加到下一首播放「${song.name}」');
  }

  void _addToQueue(BuildContext context, Song song) {
    context.read<PlayerProvider>().addToQueue(song);
    AppToast.show(context, '已添加到播放列表「${song.name}」');
  }

  Future<void> _removeFavorite(
    BuildContext context,
    LikedSongsProvider liked,
    Song song,
  ) async {
    // await 确保落盘成功后再提示；成功与否都由 provider 通知重建列表。
    await liked.toggle(song);
    if (!context.mounted) return;
    AppToast.show(context, '已取消收藏「${song.name}」');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final liked = context.watch<LikedSongsProvider>();
    final songs = liked.songs.map((s) => s.toSong()).toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: const Text('我喜欢的音乐')),
      body: SafeArea(
        child: songs.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.favorite_border_rounded,
                      size: 56,
                      color: cs.outlineVariant,
                    ),
                    const SizedBox(height: 16),
                    Text('还没有喜欢的音乐', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 8),
                    Text(
                      '播放页点击红心即可收藏',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            : PageScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _Header(
                      count: liked.count,
                      onPlayAll: songs.isEmpty
                          ? null
                          : () => _playAll(context, songs),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                    sliver: SliverFixedExtentList(
                      itemExtent: SongTile.kTileExtent,
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => SongTile(
                          song: songs[i],
                          index: i,
                          onTap: () => _playAt(context, songs, i),
                          onPlayNext: () => _playNext(context, songs[i]),
                          onAddToQueue: () => _addToQueue(context, songs[i]),
                          onRemoveFavorite: () =>
                              _removeFavorite(context, liked, songs[i]),
                        ),
                        childCount: songs.length,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 头部：标题 + 播放全部按钮。
class _Header extends StatelessWidget {
  final int count;
  final VoidCallback? onPlayAll;

  const _Header({required this.count, required this.onPlayAll});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Text(
            '共 $count 首',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          FilledButton.tonalIcon(
            onPressed: onPlayAll,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('播放全部'),
          ),
        ],
      ),
    );
  }
}