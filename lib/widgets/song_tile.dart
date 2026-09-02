import 'package:flutter/material.dart';

import '../models/song.dart';
import 'cover_image.dart';

/// 歌曲行共享组件：搜索 / 歌单详情 / 每日推荐三处统一的行样式。
///
/// - 固定高 [kTileExtent]：配合 `SliverFixedExtentList` 精确滚动偏移。
/// - 可选序号列：[index] 非 null 时显示（用等宽数字纵向对齐不跳动）。
/// - 点击播放（调用方给 [onTap]）；长按 / 右键弹出「下一首播放 / 添加到播放列表」。
/// - 付费歌曲尾部显示宝石角标。
class SongTile extends StatelessWidget {
  /// 行固定高度，各调用方 `SliverFixedExtentList.itemExtent` 沿用同一常量。
  static const double kTileExtent = 72;

  final Song song;

  /// 0 起序号；展示为 index + 1。null 时不渲染序号列（如搜索结果）。
  final int? index;
  final VoidCallback onTap;
  final VoidCallback onPlayNext;
  final VoidCallback onAddToQueue;

  /// 长按菜单「取消收藏」项；null 时不显示（默认场景）。
  final VoidCallback? onRemoveFavorite;
  const SongTile({
    super.key,
    required this.song,
    this.index,
    required this.onTap,
    required this.onPlayNext,
    required this.onAddToQueue,
    this.onRemoveFavorite,
  });

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final items = <PopupMenuEntry<_SongAction>>[
      PopupMenuItem(
        value: _SongAction.playNext,
        child: Row(
          children: [
            Icon(Icons.queue_music_rounded, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Text('下一首播放', style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
      PopupMenuItem(
        value: _SongAction.addToQueue,
        child: Row(
          children: [
            Icon(Icons.playlist_add_rounded, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Text('添加到播放列表', style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
      if (onRemoveFavorite != null)
        PopupMenuItem(
          value: _SongAction.removeFavorite,
          child: Row(
            children: [
              Icon(Icons.favorite_border_rounded, size: 20, color: cs.error),
              const SizedBox(width: 12),
              Text('取消收藏', style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
    ];
    final selected = await showMenu<_SongAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        MediaQuery.sizeOf(context).width - position.dx,
        MediaQuery.sizeOf(context).height - position.dy,
      ),
      items: items,
    );
    if (selected == _SongAction.playNext) {
      onPlayNext();
    } else if (selected == _SongAction.addToQueue) {
      onAddToQueue();
    } else if (selected == _SongAction.removeFavorite) {
      onRemoveFavorite?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final cover = song.coverSmall;
    return GestureDetector(
      onLongPressStart: (details) => _showMenu(context, details.globalPosition),
      onSecondaryTapDown: (details) =>
          _showMenu(context, details.globalPosition),
      child: SizedBox(
        height: kTileExtent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                if (index != null) ...[
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${index! + 1}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: cover != null && cover.isNotEmpty
                        ? CoverImage(
                            url: cover,
                            placeholder: const CoverPlaceholder(size: 24),
                          )
                        : const CoverPlaceholder(size: 24),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${song.artistsLabel}${song.durationMs > 0 ? ' · ${song.durationLabel}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                if (song.isPaid) ...[
                  const SizedBox(width: 8),
                  const _PremiumBadge(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

}

enum _SongAction { playNext, addToQueue, removeFavorite }

/// 付费内容角标：金色宝石图标 + 浅金底小徽章。
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  static const _gold = Color(0xFFE6A23C);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.diamond_rounded, size: 13, color: _gold),
    );
  }
}
