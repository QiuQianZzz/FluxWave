import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import 'cover_image.dart';
import 'predictive_back_gesture.dart';

/// 队列单行固定高度：`_QueueTile` 的行高与 `ListView.itemExtent` 共用，
/// 保证滚动偏移（尤其「定位当前项」）精确可算、不随文本换行漂移。
/// 行结构 = 64 卡片 + 8 间距。
const double _kQueueTileExtent = 72;

/// 播放队列面板：从底部弹出的 BottomSheet，展示当前播放队列。
///
/// 顶部标题区：大标题「播放列表」+ 下方「共 N 首」小字，右侧为当前位置
/// 定位按钮（第 N 首，点击滚回当前项）。列表项：行首序号 + 封面 +
/// 标题/歌手 + 时长 + 删除按钮；当前项以 primaryContainer 底色 + 行尾
/// 播放指示图标高亮。右下角悬浮按钮收纳低频操作：清空队列、原始/随机
/// 顺序切换。点击项跳转播放（不替换队列）。
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

  /// 首次构建标记：跳过首帧的「当前项变化」自动滚回（首帧由 _scrollToCurrent 定位）。
  bool _firstBuild = true;

  /// 上次构建时的当前项位置（原/随机视图），用于检测变化触发自动滚回。
  int? _lastCurrentIndex;

  @override
  void initState() {
    super.initState();
    // 打开时自动定位到当前播放项
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 随机关闭时恢复原序视图（避免模态框存活期间模式变化残留随机视图）。
    // 在依赖变化后、build 前处理，避免在 build 中改状态。
    final player = context.read<PlayerProvider>();
    if (!player.shuffleMode && _viewShuffled) {
      _viewShuffled = false;
      // 列表从随机序切回原始序，当前项位置随之变化，重建后重新定位。
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
  }

  /// 当前项位置（原/随机视图）。
  int _currentViewIndex(bool shuffled, PlayerProvider player, int viewLen) {
    if (viewLen == 0) return 0;
    final index = shuffled ? player.displayIndex : (player.currentIndex ?? 0);
    return index.clamp(0, viewLen - 1);
  }

  /// 滚动到当前播放项（往上留 2 行余量，便于看清上下文）。
  void _scrollToCurrent() {
    final player = context.read<PlayerProvider>();
    final viewLen = _viewShuffled
        ? player.displayQueue.length
        : player.queue.length;
    if (viewLen == 0) return;
    final index = _currentViewIndex(_viewShuffled, player, viewLen);
    _animateToIndex(index, viewLen);
  }

  /// 当前项变化后：若已滑出可视区则自动滚回（itemExtent 固定，偏移精确可算）。
  void _relocateIfHidden(int viewLen, int index) {
    if (!_scrollController.hasClients || viewLen == 0) return;
    final pos = index * _kQueueTileExtent;
    final viewport = _scrollController.position.viewportDimension;
    final offset = _scrollController.offset;
    if (pos < offset || pos + _kQueueTileExtent > offset + viewport) {
      _animateToIndex(index, viewLen);
    }
  }

  void _animateToIndex(int index, int viewLen) {
    if (!_scrollController.hasClients) return;
    final target = (index - 2).clamp(0, viewLen - 1) * _kQueueTileExtent;
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// 切换原始/随机视图并重新定位到当前项。
  void _toggleView() {
    setState(() => _viewShuffled = !_viewShuffled);
    // 切换视图后列表内容整体重排（随机序 ↔ 原始序），
    // 需在重建完成后重新定位到当前项。
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
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

    // 当前项变化且滑出可视区时自动滚回（首帧跳过，由 _scrollToCurrent 负责）。
    if (!_firstBuild && _lastCurrentIndex != currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _relocateIfHidden(
          queue.length,
          currentIndex.clamp(0, queue.length - 1),
        ),
      );
    }
    _lastCurrentIndex = currentIndex;
    _firstBuild = false;

    // 取 85% 屏幕高度平衡可视区与沉浸感
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    // 面板底色实时取自当前主题（切歌换封面→主题变→这里重算），保持不透明
    final sheetColor = Color.alphaBlend(
      cs.primaryContainer.withValues(alpha: 0.45),
      cs.surface,
    );
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    // 底色用 HSL 插值做隐式过渡：切歌换色时绕开 ARGB 线性插值的灰色中点。
    return TweenAnimationBuilder<Color>(
      tween: _HslColorTween(begin: sheetColor, end: sheetColor),
      duration: kThemeAnimationDuration,
      builder: (context, color, child) =>
          ColoredBox(color: color, child: child),
      child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Stack(
          children: [
            Column(
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
                // ── 标题区：主色图标 + 大标题/数量，右侧定位当前项 ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 16, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 主色点缀：primaryContainer 圆角方块里的队列图标
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.queue_music_rounded,
                          size: 22,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '播放列表',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '共 ${queue.length} 首',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (queue.isNotEmpty && currentIndex < queue.length)
                        _LocateCurrentPill(
                          position: currentIndex + 1,
                          onTap: _scrollToCurrent,
                        ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
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
                      // 左右与行间距统一 8，底部留出悬浮按钮 + 导航栏空间。
                      padding: EdgeInsets.fromLTRB(8, 8, 8, 100 + bottomPadding),
                      itemCount: queue.length,
                      itemBuilder: (context, index) {
                        final song = queue[index];
                        final isCurrent = index == currentIndex;
                        return _QueueTile(
                          index: index,
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
            // ── 右下角悬浮按钮：收纳低频操作 ──
            if (queue.isNotEmpty)
              Positioned(
                right: 16,
                bottom: 16 + bottomPadding,
                child: _QuickActionsFab(
                  canClear: queue.isNotEmpty,
                  shuffleMode: player.shuffleMode,
                  viewShuffled: _viewShuffled,
                  onClear: () => _confirmClear(player),
                  onToggleView: _toggleView,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 用 HSL 空间做颜色插值，绕开 ARGB 线性插值跨色相时的灰色中点，
/// 供面板底色在切歌换主题色时平滑旋转色相。
class _HslColorTween extends Tween<Color> {
  _HslColorTween({super.begin, super.end});

  @override
  Color lerp(double t) {
    if (t == 0.0) return begin!;
    if (t == 1.0) return end!;
    return HSLColor.lerp(
      HSLColor.fromColor(begin!),
      HSLColor.fromColor(end!),
      t,
    )!.toColor();
  }
}

/// 队列中的单曲项。
///
/// 行首展示序号（当前视图下的位置）；当前播放项以实心 `primaryContainer`
/// 底色高亮、序号加粗着 `onPrimaryContainer`，行尾显示播放/暂停指示图标，
/// 封面保持干净。
class _QueueTile extends StatelessWidget {
  final int index;
  final Song song;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueTile({
    required this.index,
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
    // 当前项实心 primaryContainer；其余行浅灰底卡片
    final tileColor = isCurrent
        ? cs.primaryContainer.withValues(alpha: 0.85)
        : cs.surfaceContainerHighest.withValues(alpha: 0.45);
    // 当前行文字用 onPrimaryContainer 保证在实心底上的对比度
    final titleColor = isCurrent ? cs.onPrimaryContainer : cs.onSurface;
    final subtitleColor = isCurrent
        ? cs.onPrimaryContainer.withValues(alpha: 0.8)
        : cs.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: tileColor,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            // 卡片高 64 + 底部间距 8 = itemExtent 72，偏移计算精确。
            height: _kQueueTileExtent - 8,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  // ── 行首序号：当前项加粗用 onPrimaryContainer（实心底上对比度足够） ──
                  SizedBox(
                    width: 36,
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        maxLines: 1,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: isCurrent
                              ? cs.onPrimaryContainer
                              : cs.onSurfaceVariant,
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // ── 封面（当前项不再压指示图标，保持干净） ──
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child:
                          song.coverSmall != null && song.coverSmall!.isNotEmpty
                          ? CoverImage(
                              url: song.coverSmall!,
                              placeholder: _coverFallback(cs),
                            )
                          : _coverFallback(cs),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // ── 标题 + 歌手 ──
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
                  // ── 时长 ──
                  if (song.durationMs > 0)
                    Text(
                      song.durationLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  // ── 当前项播放指示 ──
                  if (isCurrent) ...[
                    const SizedBox(width: 8),
                    Icon(
                      isPlaying
                          ? Icons.graphic_eq_rounded
                          : Icons.pause_rounded,
                      size: 20,
                      color: cs.onPrimaryContainer,
                    ),
                  ],
                  // ── 删除按钮 ──
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

/// 标题区右侧的「当前播放位置」定位按钮：显示第 N 首，点击滚动回当前项。
class _LocateCurrentPill extends StatelessWidget {
  final int position;
  final VoidCallback onTap;

  const _LocateCurrentPill({required this.position, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '定位到当前播放',
      child: Material(
        color: cs.primaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 4),
                Text(
                  '第 $position 首',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
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

/// 右下角悬浮按钮：收纳低频操作（清空队列、原始/随机顺序切换）。
///
/// 点击主钮展开/收起快捷操作；每项为「文字药丸 + 圆形图标钮」组合，
/// 展开动画为淡入 + 缩放。
class _QuickActionsFab extends StatefulWidget {
  final bool canClear;
  final bool shuffleMode;
  final bool viewShuffled;
  final VoidCallback onClear;
  final VoidCallback onToggleView;

  const _QuickActionsFab({
    required this.canClear,
    required this.shuffleMode,
    required this.viewShuffled,
    required this.onClear,
    required this.onToggleView,
  });

  @override
  State<_QuickActionsFab> createState() => _QuickActionsFabState();
}

class _QuickActionsFabState extends State<_QuickActionsFab> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // ── 展开的快捷操作 ──
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(scale: anim, child: child),
          ),
          child: _expanded
              ? Column(
                  key: const ValueKey('open'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (widget.canClear) ...[
                      _QuickActionButton(
                        label: '清空队列',
                        icon: Icons.delete_outline_rounded,
                        onTap: () {
                          setState(() => _expanded = false);
                          widget.onClear();
                        },
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (widget.shuffleMode) ...[
                      _QuickActionButton(
                        label: widget.viewShuffled ? '按原始顺序' : '按随机顺序',
                        icon: Icons.swap_horiz_rounded,
                        // 切换视图保持展开，便于看到文案反转并可再切回。
                        onTap: widget.onToggleView,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                )
              : const SizedBox.shrink(key: ValueKey('closed')),
        ),
        const SizedBox(height: 10),
        // ── 主悬浮钮 ──
        FloatingActionButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          tooltip: _expanded ? '收起' : '更多操作',
          child: Icon(
            _expanded ? Icons.close_rounded : Icons.more_horiz_rounded,
            size: 26,
          ),
        ),
      ],
    );
  }
}

/// 快捷操作项：左侧文字药丸仅作提示（不可点），点击/涟漪只落在右侧圆形图标钮上。
class _QuickActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 提示文字：非交互
        Material(
          color: cs.surfaceContainerHighest,
          elevation: 2,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              label,
              maxLines: 1,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: cs.onSurface),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 真正的操作钮：涟漪与点击区域都限在圆形图标上
        Material(
          color: cs.secondaryContainer,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, size: 22, color: cs.onSecondaryContainer),
            ),
          ),
        ),
      ],
    );
  }
}
