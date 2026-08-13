import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import 'cover_image.dart';
import 'predictive_back_gesture.dart';

/// 队列单行固定高度：`_QueueTile` 的行高与 `ListView.itemExtent` 共用，
/// 保证滚动偏移（尤其「定位当前项」）精确可算、不随文本换行漂移。
const double _kQueueTileExtent = 58;

/// 播放队列面板：从底部弹出的 BottomSheet，展示当前播放队列。
///
/// 列表项：封面 + 标题/歌手 + 时长 + 删除按钮；当前播放项高亮并显示均衡器图标。
/// 顶部：标题"播放列表" + 共 N 首 + 清空按钮。点击项跳转播放（不替换队列）。
/// 打开时自动滚动到当前播放项。
class QueueSheet extends StatefulWidget {
  const QueueSheet({super.key});

  /// 弹出播放队列面板。
  ///
  /// 复用 [showPredictiveBackSheet] 提供的底部面板 + 预测性返回：
  /// 打开/正常关闭为纯底部滑入/滑出（无缩放），边缘 back 手势期间整块面板
  /// 等比缩小预览，松手确认后以下滑动画关闭。
  static Future<void> show(BuildContext context) {
    return showPredictiveBackSheet<void>(
      context,
      barrierColor: Colors.black54,
      barrierLabel: '关闭播放列表',
      // 预测性返回跟随设置开关：关闭时退回普通返回（无预览动画）。
      enabled: context.read<ThemeProvider>().predictiveBack,
      builder: (_) => const QueueSheet(),
    );
  }

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  final ScrollController _scrollController = ScrollController();

  /// 是否展示「随机列表」视图（仅随机开启时可切换；播放顺序不受影响）。
  bool _viewShuffled = false;

  @override
  void initState() {
    super.initState();
    // 打开时自动定位到当前播放项
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  void _scrollToCurrent() {
    final player = context.read<PlayerProvider>();
    // 按当前视图（原始/随机）取列表与当前项位置。
    final viewLen = _viewShuffled
        ? player.displayQueue.length
        : player.queue.length;
    if (viewLen == 0) return;
    final index =
        (_viewShuffled ? player.displayIndex : (player.currentIndex ?? 0))
            .clamp(0, viewLen - 1);
    // itemExtent = 每行真实高度，偏移精确；往上留 2 行余量
    final target = (index - 2).clamp(0, viewLen - 1) * _kQueueTileExtent;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 清空队列前确认对话框。
  Future<void> _confirmClear(PlayerProvider player) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('清空播放列表'),
          content: const Text('确定清空当前播放列表吗？将停止播放。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.errorContainer,
                foregroundColor: cs.onErrorContainer,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await player.clearQueue();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final player = context.watch<PlayerProvider>();
    // _viewShuffled=false → 展示原始队列顺序（player.queue）；
    // true → 展示随机顺序（player.displayQueue）。列表渲染必须随视图，否则切换无效果。
    final queue = _viewShuffled ? player.displayQueue : player.queue;
    final currentIndex = _viewShuffled
        ? player.displayIndex
        : (player.currentIndex ?? 0);
    // 随机关闭时恢复原序视图（避免模态框存活期间模式变化残留随机视图）。
    if (!player.shuffleMode && _viewShuffled) {
      _viewShuffled = false;
      // 列表从随机序切回原始序，当前项位置随之变化，重建后重新定位。
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }

    // 取 85% 屏幕高度平衡可视区与沉浸感
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── drag handle ──
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // ── 标题行 ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.queue_music_rounded, size: 22, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  '播放列表',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '共 ${queue.length} 首',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (queue.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _confirmClear(player),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('清空'),
                    style: TextButton.styleFrom(
                      foregroundColor: cs.onSurfaceVariant,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          // ── 原始 / 随机顺序切换（仅随机开启时显示；单按钮来回切） ──
          if (player.shuffleMode) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '列表顺序',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  _ViewToggle(
                    switchToShuffled: !_viewShuffled,
                    onTap: () {
                      setState(() => _viewShuffled = !_viewShuffled);
                      // 切换视图后列表内容整体重排（随机序 ↔ 原始序），
                      // 需在重建完成后重新定位到当前项（initState 只做了首帧一次）。
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _scrollToCurrent(),
                      );
                    },
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          ],
          // ── 队列列表 ──
          if (queue.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text(
                '播放列表为空',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                controller: _scrollController,
                shrinkWrap: true,
                // 固定行高：滚动偏移精确计算（见 _scrollToCurrent 与 _QueueTile）。
                itemExtent: _kQueueTileExtent,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: queue.length,
                itemBuilder: (context, index) {
                  final song = queue[index];
                  final isCurrent = index == currentIndex;
                  return _QueueTile(
                    song: song,
                    isCurrent: isCurrent,
                    isPlaying: isCurrent && player.playing,
                    onTap: () {
                      if (!isCurrent) {
                        player.jumpTo(
                          _viewShuffled
                              ? player.originalIndexAtDisplay(index)
                              : index,
                        );
                      }
                    },
                    onRemove: () => player.removeAt(
                      _viewShuffled
                          ? player.originalIndexAtDisplay(index)
                          : index,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 队列中的单曲项。
///
/// 当前播放项高亮：用 `primaryContainer` 背景色（alpha 0.4）
/// 替代早期的封面半黑遮罩，视觉更柔和、与 MD3 主题色统一。
class _QueueTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueTile({
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 当前项 primaryContainer(0.4) 背景，其余透明
    final tileColor = isCurrent
        ? cs.primaryContainer.withValues(alpha: 0.4)
        : Colors.transparent;
    final titleColor = isCurrent ? cs.primary : cs.onSurface;
    final subtitleColor = isCurrent
        ? cs.primary.withValues(alpha: 0.8)
        : cs.onSurfaceVariant;

    return Material(
      color: tileColor,
      child: InkWell(
        onTap: onTap,
        // 固定行高（与 itemExtent 一致）：内容垂直居中，行高恒定。
        child: SizedBox(
          height: _kQueueTileExtent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // 封面 + 当前播放指示
                Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child:
                            song.coverSmall != null &&
                                song.coverSmall!.isNotEmpty
                            ? CoverImage(
                                url: song.coverSmall!,
                                placeholder: _coverFallback(cs),
                              )
                            : _coverFallback(cs),
                      ),
                    ),
                    if (isCurrent)
                      Icon(
                        isPlaying
                            ? Icons.equalizer_rounded
                            : Icons.pause_rounded,
                        size: 20,
                        color: Colors.white,
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 2),
                        ],
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                // 标题 + 歌手
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        song.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: titleColor,
                          fontWeight: isCurrent
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artistsLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 时长
                if (song.durationMs > 0)
                  Text(
                    song.durationLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                // 删除按钮
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: '从列表移除',
                  onPressed: onRemove,
                  visualDensity: VisualDensity.compact,
                  splashRadius: 14,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _coverFallback(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Icon(
        Icons.music_note_rounded,
        color: cs.onSurfaceVariant,
        size: 20,
      ),
    );
  }
}

/// 队列「原始顺序 ⇄ 随机顺序」单按钮切换。
///
/// 按钮文案始终表示「切到哪个视图」（点击后的目标），避免“选中态”歧义：
/// - 当前原始顺序 → 按钮「切换随机顺序」
/// - 当前随机顺序 → 按钮「切换原始顺序」
class _ViewToggle extends StatelessWidget {
  final bool switchToShuffled;
  final VoidCallback onTap;

  const _ViewToggle({required this.switchToShuffled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: switchToShuffled ? cs.secondaryContainer : cs.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                switchToShuffled
                    ? Icons.shuffle_rounded
                    : Icons.list_alt_rounded,
                size: 16,
                color: switchToShuffled
                    ? cs.onSecondaryContainer
                    : cs.onPrimaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                switchToShuffled ? '按随机顺序' : '按原始顺序',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: switchToShuffled
                      ? cs.onSecondaryContainer
                      : cs.onPrimaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
