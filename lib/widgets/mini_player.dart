import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../pages/player_page.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import 'cover_image.dart';
import 'glass_surface.dart';
import 'queue_sheet.dart';

/// 底部迷你播放器（悬浮圆角卡片，覆盖在页面底部）。
///
/// 无歌曲播放时隐藏（SizedBox.shrink）。四周留白透明、露出页面内容，独立悬浮；
/// 顶部一条圆角进度条，下方封面/歌名/歌手 + 控制按钮（按钮与进度条固定）。
///
/// 左右滑动切换歌曲（对齐网易云）：手势作用于整卡，但只有**封面+歌名歌手**
/// 那一块滑动，目标歌曲的封面与信息从侧边进入；松手过阈值后平滑归正并完成
/// 切换。窄屏不显示上一曲/下一曲按钮；宽屏保留按钮（滑动同样可用）。
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  /// 判定切换的位移阈值（松手时信息块净位移超过该值即切歌）。
  static const _kDragSwitchThreshold = 60.0;

  /// 判定切换的速度阈值（px/s，慢速拖但没拖够距离时也能切换）。
  static const _kDragSwitchVelocity = 300.0;

  /// 预览死区：位移小于该值不显示目标歌曲（避免起手抖动误判方向）。
  static const _kDragDeadZone = 10.0;

  /// 滑动区（封面+标题）宽度缓存，由 LayoutBuilder 更新；兼作滑动位移上限。
  double _slideWidth = 300;

  /// 手指拖动中的位移（仅作用于信息块）。
  double _dragDx = 0;

  /// 松手归正动画：把信息块平滑滑到目标（切歌）或滑回原位（未过阈值）。
  /// 可空字段 + 惰性 getter：热重载不重跑 initState，旧 State 里可能为 null，
  /// 首次手势访问 [settleCtrl] 时自动重建，避免松手不归正。
  AnimationController? _settle;
  double _settleFrom = 0;
  double _settleTo = 0;

  /// 归正结束后是否切歌：-1=上一曲，1=下一曲，0=不切。
  int _pendingSwitch = 0;

  AnimationController get settleCtrl {
    final existing = _settle;
    if (existing != null) return existing;
    final c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addStatusListener(_onSettleStatus);
    _settle = c;
    return c;
  }

  @override
  void initState() {
    super.initState();
    settleCtrl; // 预创建，保证首帧即有控制器。
  }

  @override
  void dispose() {
    _settle?.dispose();
    super.dispose();
  }

  /// 信息块当前水平位移：拖动中跟随手指；归正动画中走缓动曲线。
  double get _infoOffset {
    final s = _settle;
    if (s != null && s.isAnimating) {
      final t = Curves.easeOutCubic.transform(s.value);
      return _settleFrom + (_settleTo - _settleFrom) * t;
    }
    return _dragDx;
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;
    final pending = _pendingSwitch;
    setState(() {
      _dragDx = 0;
      _settleFrom = 0;
      _settleTo = 0;
      _pendingSwitch = 0;
    });
    if (pending < 0) {
      context.read<PlayerProvider>().previous();
    } else if (pending > 0) {
      context.read<PlayerProvider>().next();
    }
  }

  void _onHorizontalDragStart() {
    if (settleCtrl.isAnimating) return;
    setState(() => _dragDx = 0);
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (settleCtrl.isAnimating) return;
    final player = context.read<PlayerProvider>();
    var next = _dragDx + d.delta.dx;
    // 队首/队尾边界：该方向无歌时不允许滑出。
    if (!player.hasNext) next = math.max(next, 0);
    if (!player.hasPrevious) next = math.min(next, 0);
    next = next.clamp(-_slideWidth, _slideWidth);
    if (next != _dragDx) setState(() => _dragDx = next);
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (settleCtrl.isAnimating) return;
    final player = context.read<PlayerProvider>();
    final dx = _dragDx;
    final v = d.primaryVelocity ?? 0;

    // 滑动方向（信息块位移符号）：-1 = 左滑(看下一首)，+1 = 右滑(看上一首)。
    var slideDir = 0;
    if (dx < -_kDragSwitchThreshold || (v < -_kDragSwitchVelocity && dx < 0)) {
      if (player.hasNext) slideDir = -1; // 左滑 → 下一首
    } else if (dx > _kDragSwitchThreshold ||
        (v > _kDragSwitchVelocity && dx > 0)) {
      if (player.hasPrevious) slideDir = 1; // 右滑 → 上一首
    }

    _settleFrom = _dragDx;
    if (slideDir != 0) {
      _settleTo = slideDir * _slideWidth; // 目标歌曲信息块完全进入后归正
      _pendingSwitch = -slideDir; // 左滑(-1)→下一首(1)，右滑(+1)→上一首(-1)
    } else {
      _settleTo = 0; // 未过阈值：滑回原位
      _pendingSwitch = 0;
    }
    settleCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final blur = context.watch<SettingsProvider>().glassBlur;
    final theme = Theme.of(context);

    final song = player.currentSong;
    if (song == null) return const SizedBox.shrink();

    // 与 MainScaffold 的宽/窄断点一致：窄屏滑动切换，宽屏保留按钮。
    final isWide = MediaQuery.sizeOf(context).width >= 600;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: GestureDetector(
        onTap: () => _openPlayer(context),
        onHorizontalDragStart: (_) => _onHorizontalDragStart(),
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        child: Container(
          // 立体感：柔和投影（非 Material 生硬 elevation）。
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          // 玻璃语言统一走 [GlassSurface]（sigma/描边统一，小播放器偏透），
          // 跟随全局毛玻璃开关（关闭时回退实色卡）。
          child: GlassSurface(
            enabled: blur,
            borderRadius: BorderRadius.circular(22),
            topAlpha: 0.66,
            bottomAlpha: 0.5,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部圆角进度条（固定）。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _buildProgress(player),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      // 滑动区：封面 + 歌名/歌手（只有这块滑动）。归正动画
                      // 期间仅此区域随动画重建，避免整卡（含 BackdropFilter）
                      // 逐帧重绘。
                      Expanded(
                        child: AnimatedBuilder(
                          animation:
                              _settle ??
                              const AlwaysStoppedAnimation<double>(0),
                          builder: (context, _) =>
                              _buildSlideArea(theme, player, song),
                        ),
                      ),
                      if (isWide)
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded),
                          tooltip: player.hasPrevious ? '上一曲' : '',
                          onPressed: player.hasPrevious
                              ? player.previous
                              : null,
                          visualDensity: VisualDensity.compact,
                        ),
                      IconButton(
                        icon: Icon(
                          player.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        tooltip: player.playing ? '暂停' : '播放',
                        onPressed: player.toggle,
                        visualDensity: VisualDensity.compact,
                      ),
                      if (isWide)
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded),
                          tooltip: player.hasNext ? '下一曲' : '',
                          onPressed: player.hasNext ? player.next : null,
                          visualDensity: VisualDensity.compact,
                        ),
                      IconButton(
                        icon: const Icon(Icons.queue_music_rounded),
                        tooltip: '播放列表',
                        onPressed: () => QueueSheet.show(context),
                        visualDensity: VisualDensity.compact,
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

  /// 滑动区：当前歌曲信息 + 拖动方向的目标歌曲信息从侧边进入。
  Widget _buildSlideArea(ThemeData theme, PlayerProvider player, Song song) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _slideWidth = constraints.maxWidth;
        final width = _slideWidth;
        final offset = _infoOffset;

        // 显示方向（位移符号）：拖拽中按净位移 + 死区；归正动画中按目标方向
        // （回弹用起点方向，保证已预览的目标歌曲平滑滑出）。
        int dir;
        final s = _settle;
        if (s != null && s.isAnimating) {
          dir = _settleTo != 0
              ? _settleTo.sign.toInt()
              : _settleFrom.sign.toInt();
        } else {
          dir = offset.abs() < _kDragDeadZone ? 0 : offset.sign.toInt();
        }

        final Song? neighbor;
        final double neighborPos;
        if (dir < 0) {
          neighbor = player.nextSong; // 左滑 → 下一首从右侧进入
          neighborPos = offset + width;
        } else if (dir > 0) {
          neighbor = player.previousSong; // 右滑 → 上一首从左侧进入
          neighborPos = offset - width;
        } else {
          neighbor = null;
          neighborPos = 0;
        }

        return ClipRect(
          child: Stack(
            children: [
              Transform.translate(
                offset: Offset(offset, 0),
                child: _buildInfo(theme, player, song, isTrial: player.isTrial),
              ),
              if (neighbor != null)
                Transform.translate(
                  offset: Offset(neighborPos, 0),
                  child: _buildInfo(theme, player, neighbor),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 单块信息：封面 + 歌名/歌手（作为滑动的一整块）。
  Widget _buildInfo(
    ThemeData theme,
    PlayerProvider player,
    Song song, {
    bool isTrial = false,
  }) {
    final cs = theme.colorScheme;
    return Row(
      children: [
        _buildCover(cs, song.coverSmall),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                isTrial ? '${song.artistsLabel} · 试听片段' : song.artistsLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: isTrial ? cs.error : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 打开全屏播放页：从底部滑入；返回时反向滑出（向下方收起）。
  static void _openPlayer(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, _, _) => const PlayerPage(),
        transitionsBuilder: (_, animation, _, child) {
          final offset = Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation);
          return SlideTransition(position: offset, child: child);
        },
      ),
    );
  }

  /// 细圆角进度条：position/duration 走流（StreamBuilder），不触发全树重建。
  Widget _buildProgress(PlayerProvider player) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: StreamBuilder<Duration?>(
          stream: player.durationStream,
          builder: (context, durSnap) {
            final duration = durSnap.data ?? Duration.zero;
            return StreamBuilder<Duration>(
              stream: player.positionStream,
              builder: (context, posSnap) {
                final position = posSnap.data ?? Duration.zero;
                final t = duration.inMilliseconds <= 0
                    ? 0.0
                    : (position.inMilliseconds / duration.inMilliseconds).clamp(
                        0.0,
                        1.0,
                      );
                return LinearProgressIndicator(
                  value: t,
                  minHeight: 3,
                  backgroundColor: cs.surfaceContainerHighest,
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildCover(ColorScheme cs, String? cover) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 48,
        height: 48,
        child: cover != null && cover.isNotEmpty
            ? CoverImage(url: cover, placeholder: _coverFallback(cs))
            : _coverFallback(cs),
      ),
    );
  }

  Widget _coverFallback(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Icon(
        Icons.music_note_rounded,
        color: cs.onSurfaceVariant,
        size: 24,
      ),
    );
  }
}
