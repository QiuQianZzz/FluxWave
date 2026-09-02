import 'package:flutter/material.dart';

import '../models/song.dart';
import 'page_scroll_view.dart';
import 'song_tile.dart';

/// 歌曲列表共享视图：加载态 / 错误态 / 空态 + Sliver 歌曲列表。
///
/// 专辑详情页和歌单详情页共用此组件，各自提供 Header 和加载逻辑。
class SongListView extends StatelessWidget {
  final List<Song> tracks;
  final bool loading;
  final Object? error;
  final String emptyText;
  final String errorPrefix;
  final VoidCallback? onRetry;
  final Widget? header;
  final void Function(int index) onPlayAt;
  final void Function(Song song) onPlayNext;
  final void Function(Song song) onAddToQueue;

  const SongListView({
    super.key,
    required this.tracks,
    required this.loading,
    this.error,
    this.emptyText = '还没有歌曲',
    this.errorPrefix = '加载失败',
    this.onRetry,
    this.header,
    required this.onPlayAt,
    required this.onPlayNext,
    required this.onAddToQueue,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (loading) return const Center(child: CircularProgressIndicator());

    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text(
              '$errorPrefix：$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      );
    }

    if (tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_off_rounded, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text(emptyText, style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    return PageScrollView(
      slivers: [
        if (header != null) SliverToBoxAdapter(child: header!),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: SliverFixedExtentList(
            itemExtent: SongTile.kTileExtent,
            delegate: SliverChildBuilderDelegate(
              (context, i) => SongTile(
                song: tracks[i],
                index: i,
                onTap: () => onPlayAt(i),
                onPlayNext: () => onPlayNext(tracks[i]),
                onAddToQueue: () => onAddToQueue(tracks[i]),
              ),
              childCount: tracks.length,
            ),
          ),
        ),
      ],
    );
  }
}
