import 'package:flutter/material.dart';

import '../../../core/playback_stats/playback_stats_models.dart';
import '../../../widgets/cover_image.dart';

/// 播放时间排行（支持按播放次数 / 播放时间排序）
class PlayRanking extends StatefulWidget {
  final List<RankingItem> items;

  const PlayRanking({super.key, required this.items});

  @override
  State<PlayRanking> createState() => _PlayRankingState();
}

class _PlayRankingState extends State<PlayRanking> {
  bool _sortByPlayCount = false;

  List<RankingItem> get _sortedItems {
    final list = List<RankingItem>.from(widget.items);
    if (_sortByPlayCount) {
      list.sort((a, b) => b.playCount.compareTo(a.playCount));
    } else {
      list.sort((a, b) => b.totalListenMs.compareTo(a.totalListenMs));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.items.isEmpty) return const SizedBox.shrink();

    final sorted = _sortedItems;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 排序切换
          Row(
            children: [
              Text(
                '播放排行',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('播放时间', style: TextStyle(fontSize: 12)),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('播放次数', style: TextStyle(fontSize: 12)),
                  ),
                ],
                selected: {_sortByPlayCount},
                onSelectionChanged: (v) =>
                    setState(() => _sortByPlayCount = v.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity(horizontal: -2, vertical: -2),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...List.generate(sorted.length, (i) {
            final item = sorted[i];
            return _RankingTile(rank: i + 1, item: item);
          }),
        ],
      ),
    );
  }
}

class _RankingTile extends StatelessWidget {
  final int rank;
  final RankingItem item;

  const _RankingTile({required this.rank, required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          // 序号（左侧主题色数字）
          SizedBox(
            width: 28,
            child: Text(
              '$rank',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          // 封面
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 48,
              height: 48,
              child: item.coverUrl != null && item.coverUrl!.isNotEmpty
                  ? CoverImage(url: item.coverUrl!)
                  : Container(
                      color: cs.surfaceContainerHigh,
                      child: Icon(
                        Icons.music_note_rounded,
                        size: 20,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          // 歌曲信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.artist ?? '未知歌手',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // 统计：播放次数 + 时长
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${item.playCount}次',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              Text(
                _formatDuration(item.totalListenMs),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.outlineVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 60) return '$minutes分钟';
    final hours = minutes ~/ 60;
    final remainMinutes = minutes % 60;
    if (remainMinutes == 0) return '$hours小时';
    return '$hours小时$remainMinutes分钟';
  }
}
