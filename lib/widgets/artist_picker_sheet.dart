import 'package:flutter/material.dart';

import '../models/artist.dart';
import 'predictive_back_gesture.dart';

/// 歌手选择底部抽屉。
///
/// 当歌曲有多位歌手时弹出，供用户选择要跳转的歌手。
/// 返回选中的 [ArtistSummary]，取消返回 null。
class ArtistPickerSheet extends StatelessWidget {
  final List<ArtistSummary> artists;
  const ArtistPickerSheet({super.key, required this.artists});

  /// 静态方法：弹出并返回选中歌手。
  static Future<ArtistSummary?> show(
    BuildContext context, {
    required List<ArtistSummary> artists,
  }) {
    return showPredictiveBackSheet<ArtistSummary>(
      context,
      builder: (_) => ArtistPickerSheet(artists: artists),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 拖拽手柄 ──
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // ── 标题栏 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
            child: Row(
              children: [
                Text(
                  '选择歌手',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // ── 歌手列表（可滚动） ──
          if (artists.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text('暂无歌手', style: TextStyle(fontSize: 14)),
              ),
            )
          else
            Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: artists.map(
                  (a) => InkWell(
                    onTap: () => Navigator.of(context).pop(a),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  cs.primaryContainer,
                                  cs.primaryContainer.withValues(alpha: 0.6),
                                ],
                              ),
                            ),
                            child: Center(
                              child: Text(
                                a.name.isNotEmpty
                                    ? a.name.characters.first
                                    : '?',
                                style: TextStyle(
                                  color: cs.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              a.name,
                              style: Theme.of(context).textTheme.bodyLarge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: cs.outline,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
