import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/lyric/lyric_model.dart';
import '../core/lyric/lyric_provider.dart';
import '../core/platform_utils.dart';
import '../constants/nav_thresholds.dart';
import '../models/song.dart';
import '../providers/netease_provider.dart';
import '../providers/player_provider.dart';
import '../providers/liked_songs_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/cover_image.dart';
import '../widgets/fluid_background.dart';
import '../providers/settings_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/lyric/lyric_layout.dart';
import '../widgets/lyric/lyric_view.dart';
import '../widgets/queue_sheet.dart';

/// 进度条播放中的满振幅（**物理 px**，WAVE_AMPLITUDE=6）。
/// painter 内按 1/DPR 折算为逻辑 px，实现一致的视觉比例。
const kWaveAmplitude = 6.0;

/// 宽屏分栏断点：≥ 此宽时左侧播放器 + 右侧歌词常驻（去掉滑动切换）。
/// 对齐 mini_player 的 `width >= 600`，避免迷你栏已宽屏态但播放页仍是窄屏的割裂。
const kWidePlayerBreakpoint = 600.0;

/// 宽屏左栏控制行自然宽度：7 个紧凑按钮（24+8+24+8+30+12+52+12+30+8+24+8+24 = 264）。
/// 宽屏进度条以此为上限，避免轨道拉伸到整栏宽。
const kWideControlsWidth = 264.0;

/// 全屏播放页：点迷你栏展开（自底部滑入）。
///
/// 沉浸式，集中展示：大封面 / 歌名 / 歌手 / 试听提示 / 带波浪的进度条 /
/// 上一曲·播放暂停·下一曲 / 当前音质。内容整体垂直居中，超屏时可滚动。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  /// 歌词页过渡（0..1）：0 = 播放页布局，1 = 歌词页布局。
  /// 驱动封面位置/尺寸、进度条/控件位置、歌词面板透明度/高度的插值。
  /// 300ms：避免按钮/松手切换显得拖沓。
  late final AnimationController _lyricsTransition;

  @override
  void initState() {
    super.initState();
    // 显式在 initState 初始化，而非 `late final` 惰性初始化：宽屏分栏下
    // `_lyricsTransition` 整页不引用，若留到 dispose() 首访会触发 flutter#153644
    // （AnimationController(vsync: this) → TickerMode ancestor lookup 在已
    // deactivated 的 element 上崩溃；SDK 3.44.2 未含官方 #185248 修复）。
    _lyricsTransition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  /// 拖动放大系数：手指移动 1px，页面移动 1.5px。让歌词切换更跟手灵敏，
  /// 不必滑到接近屏宽才有切换感。
  static const double _lyricsDragSensitivity = 1.5;

  /// 播放页歌词切换的拖动距离阈值（比例屏宽）：比外部 Tab 的 0.25 更灵敏。
  static const double _lyricsDragDistanceRatio = 0.18;

  /// 拖动起点的 value，用于 onHorizontalDragEnd 判定方向（对齐外部 Tab
  /// 的 _drag 符号语义：>0 向左拖进歌词页，<0 向右拖回播放页）。
  double _dragStartValue = 0;

  /// 当前是否处于歌词页（过渡完成态）。按钮图标/颜色据此切换。
  bool get _isLyricsMode => _lyricsTransition.value > 0.5;

  void _toggleLyrics() {
    if (_isLyricsMode) {
      _lyricsTransition.reverse();
    } else {
      _lyricsTransition.forward();
    }
    setState(() {});
  }

  static String _fmt(Duration d) {
    final t = d.inSeconds;
    final m = t ~/ 60;
    final s = t % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _lyricsTransition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.read<ThemeProvider>();
    final player = context.watch<PlayerProvider>();
    // 播放页固定深色主题（音乐播放页惯例）：流体背景始终压在近黑底色上，
    // 文字/控件用深色主题下的浅色（onSurface 白 / onSurfaceVariant 浅灰），
    // 保证任意封面下都清晰可读。亮色封面只影响背景点缀与强调色，不切换主题。
    final theme = themeProvider.darkTheme;
    final song = player.currentSong;
    final sysTopPad = MediaQuery.paddingOf(context).top;
    final topPad = sysTopPad + _extraTop(context);
    // 宽屏分栏（≥600）：左侧播放器 + 右侧歌词常驻，去掉滑动切换。
    final isWide = MediaQuery.sizeOf(context).width >= kWidePlayerBreakpoint;

    // 强调色覆盖：封面取色 → 可读性修正 → 作为 primary 注入主题，
    // 播放按钮/进度条/歌词高亮统一使用。未就绪回退深色主题 primary。
    return ValueListenableBuilder<Color?>(
      valueListenable: FluidBackground.accentColor,
      builder: (context, accent, _) {
        final resolvedAccent = accent ?? theme.colorScheme.primary;
        final accentTheme = theme.copyWith(
          colorScheme: theme.colorScheme.copyWith(primary: resolvedAccent),
        );
        final cs = accentTheme.colorScheme;
        return Theme(
      data: accentTheme,
      child: Scaffold(
      // Stack：内容区在底层，顶部栏在上层（透明背景，t=1 时封面移入其位置）
      body: Stack(
        children: [
          // ── 流体背景（全屏播放页底层，GPU shader，颜色跟随封面） ──
          const Positioned.fill(child: FluidBackground()),
          // ── 内容区 ──
          isWide
              ? _buildWideContent(theme, cs, player, song, topPad)
              : AnimatedBuilder(
                  animation: _lyricsTransition,
                  builder: (context, _) {
                    final t = _lyricsTransition.value;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (d) {
                        _dragStartValue = _lyricsTransition.value;
                      },
                      onHorizontalDragUpdate: (d) {
                        if (song == null) return;
                        final width = MediaQuery.sizeOf(context).width;
                        if (width <= 0) return;
                        // 放大系数映射（更跟手）：手指移动 = 1.5 倍页面移动，
                        // 松手后从当前位置补到目标态。
                        final delta = -d.delta.dx / width * _lyricsDragSensitivity;
                        // AnimatedBuilder 已监听 _lyricsTransition，value 赋值自动触发重建
                        _lyricsTransition.value = (_lyricsTransition.value + delta)
                            .clamp(0.0, 1.0);
                      },
                      onHorizontalDragEnd: (d) {
                        // 松手后按"拖动量 + fling 速度"决定最终态（与外部 Tab 逻辑一致）
                        // drag > 0 = 向左拖（进歌词页），drag < 0 = 向右拖（回播放页）
                        final v = _lyricsTransition.value;
                        final velocity = d.primaryVelocity ?? 0;
                        final drag = v - _dragStartValue;
                        final absDrag = drag.abs();
                        // velocity 与 drag 方向相反：向左拖 drag>0 但 velocity<0，
                        // 传入 shouldComplete 时反转 velocity 使两者同号对齐。
                        final shouldComplete = NavThresholds.shouldComplete(
                          dragRatio: absDrag,
                          velocity: -velocity,
                          drag: drag,
                          // 播放页歌词切换用更灵敏的阈值，避免拖太远才切换
                          dragDistanceRatio: _lyricsDragDistanceRatio,
                        );
                        if (shouldComplete) {
                          if (drag > 0) {
                            _lyricsTransition.forward();
                          } else {
                            _lyricsTransition.reverse();
                          }
                        } else {
                          // 未达阈值：回弹到最近态
                          if (v > 0.5) {
                            _lyricsTransition.forward();
                          } else {
                            _lyricsTransition.reverse();
                          }
                        }
                        // forward/reverse 会触发 AnimatedBuilder 重建，但顶部栏图标
                        // 不在 AnimatedBuilder 内，需 setState 触发整树重建
                        setState(() {});
                      },
                      child: song == null
                          ? const _NoNowPlaying()
                          : _buildPlaybackContent(
                              theme, cs, player, song, t, topPad,
                            ),
                    );
                  },
                ),
          // ── 顶部栏（透明背景，在最上层） ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: _extraTop(context),
                ),
                child: Row(
                  children: [
                    IconButton(
                      iconSize: 24,
                      visualDensity: VisualDensity.compact,
                      splashRadius: 14,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                      color: cs.onSurfaceVariant,
                    ),
                    const Spacer(),
                    // 窄屏：队列钮已挪入控制行，右上角仅保留歌词切换。
                    // 宽屏：歌词常驻右栏，无需歌词切换按钮（右上角留待菜单钮）。
                    if (song != null && !isWide)
                      IconButton(
                        iconSize: 22,
                        visualDensity: VisualDensity.compact,
                        splashRadius: 14,
                        tooltip: _isLyricsMode ? '关闭歌词' : '歌词',
                        icon: Icon(
                          _isLyricsMode
                              ? Icons.lyrics_rounded
                              : Icons.lyrics_outlined,
                        ),
                        onPressed: _toggleLyrics,
                        color: _isLyricsMode ? cs.primary : cs.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
      },
    );
  }
  /// 当前是否为移动平台（Android/iOS）。
  /// 按平台而非屏幕宽度判定，适配宽屏 Android 平板。
  bool _isMobile(BuildContext context) => PlatformUtils.isMobile;

  /// 平台额外顶边距：移动端已有系统状态栏，略加即可；
  /// 桌面端无系统 chrome，需稍多留白。
  double _extraTop(BuildContext context) => _isMobile(context) ? 4.0 : 16.0;

  /// 平台额外底边距：移动端有系统手势小白条，略加即可；
  /// 桌面端无手势条，需稍多留白。
  double _extraBottom(BuildContext context) => _isMobile(context) ? 8.0 : 20.0;

  /// 宽屏分栏布局（≥ [kWidePlayerBreakpoint]）：左侧播放器 + 右侧歌词常驻。
  ///
  /// 宽屏信息架构与窄屏（滑动切换）不同——两栏并存，无需 `_lyricsTransition`
  /// 插值，也无歌词切换按钮。左侧复用封面/标题/进度/控制组件，右侧歌词全高常显。
  Widget _buildWideContent(
    ThemeData theme,
    ColorScheme cs,
    PlayerProvider player,
    Song? song,
    double topPad,
  ) {
    final extraBottom = _extraBottom(context);
    final backBtnSize = 48.0;

    return SafeArea(
      bottom: true,
      top: false,
      child: song == null
          ? const _NoNowPlaying()
          : Padding(
              padding: EdgeInsets.fromLTRB(
                32,
                topPad + backBtnSize + 8,
                32,
                extraBottom + 8,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final bodyW = constraints.maxWidth;
                  final bodyH = constraints.maxHeight;
                  // 左栏封面：随可用高度走，宽屏更克制（比窄屏同比例小，避免过满）。
                  final coverSize = (bodyH * 0.42)
                      .clamp(160.0, math.min(bodyW * 0.36, 300.0))
                      .toDouble();
                  // 右栏歌词字号随列宽自适应（窄屏固定 20）：列宽 × 0.055，
                  // 落到 20..32 之间——宽屏列更宽时歌词字号更大。
                  final colW = (bodyW - 32) / 2;
                  final lyricFontSize = (colW * 0.055).clamp(20.0, 32.0);

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── 左栏：播放器（封面 / 标题 / 进度 / 控制行） ──
                      // 与右栏歌词等宽（各占 1 flex，中间留 32 gap）。
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildCover(cs, song.coverFor(1000), coverSize, 18),
                            const SizedBox(height: 24),
                            Text(
                              song.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              player.isTrial
                                  ? '${song.artistsLabel} · 试听片段'
                                  : song.artistsLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: player.isTrial
                                    ? cs.error
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 28),
                            _NowPlayingProgress(
                              player: player,
                              // 与下方控制行同宽，避免进度条拉伸整栏
                              maxWidth: kWideControlsWidth,
                            ),
                            const SizedBox(height: 8),
                            _buildQuality(cs),
                            const SizedBox(height: 14),
                            _buildControls(cs, player),
                          ],
                        ),
                      ),
                      const SizedBox(width: 32),
                      // ── 右栏：歌词全高常显 ──
                      Expanded(
                        child: _LyricPanel(
                          songId: song.id,
                          songKey: '${song.source}_${song.id}',
                          height: bodyH,
                          fontSize: lyricFontSize,
                          reloadToken: player.contentTick,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
    );
  }

  /// 播放页态封面尺寸（`maxWidth * 0.6`，略收窄防超高）。
  double _coverSizeLarge(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final h = MediaQuery.sizeOf(context).height;
    return math.min<double>(w * 0.6, h * 0.32).clamp(180.0, 280.0);
  }

  /// 歌词页态封面尺寸（`64 * coverScale ≈ 48`）。
  double _coverSizeCompact(BuildContext context) {
    return 48.0;
  }

  /// 构建播放/歌词混合内容，由过渡值 [t]（0..1）驱动布局插值。
  ///
  /// 核心方案：
  /// 封面、标题、歌词、控件全部用 Stack+Positioned 绝对定位，
  /// 按 [t] 线性插值坐标，实现单实例直线移动（非双标题交叉淡入淡出）。
  ///
  /// 歌词面板固定于歌词页最终位置与全高，切换仅透明度淡入淡出
  /// （不从中间展开）。
  ///
  /// - t=0：封面水平居中、标题在封面下方居中、控件居中
  /// - t=1：封面在返回按钮右侧（顶部栏内）、标题在封面右侧、歌词填中间、控件贴底
  Widget _buildPlaybackContent(
    ThemeData theme,
    ColorScheme cs,
    PlayerProvider player,
    Song song,
    double t,
    double topPad,
  ) {
    final coverLarge = _coverSizeLarge(context);
    final coverSmall = _coverSizeCompact(context);
    final coverSize = coverLarge + (coverSmall - coverLarge) * t;

    // 顶部栏：返回按钮在 SafeArea 下方，按钮高度 48，垂直居中 y = topPad + 24
    final backBtnLeft = 8.0; // 顶部栏 padding
    final backBtnSize = 48.0;
    final backBtnCenterY = topPad + backBtnSize / 2;

    // 控件区固定高度估算（进度条 + gap + 按钮行 + gap + 音质）
    const controlsH = 14 + 35 + 10 + 52 + 14 + 20.0;
    // 标题区高度：t=0 约 50（titleLarge+gap+bodyMedium），t=1 约 40（titleMedium+gap+bodySmall）
    const titleH0 = 50.0;
    const titleH1 = 40.0;
    final titleH = titleH0 + (titleH1 - titleH0) * t;

    // 歌词面板左右 padding（与进度条对齐）
    const sidePad = 28.0;
    // 歌词面板侧边距略微加宽：窄屏歌词区收窄一点，视觉上更聚拢
    // （进度条仍用 sidePad，二者解耦）。右侧直接用，左侧还需减 kLyricLeftBuffer。
    const lyricSidePad = 40.0;
    final extraBottom = _extraBottom(context);

    return SafeArea(
      bottom: true,
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;

          // ── t=0 时的坐标（播放页布局） ──
          // 内容区顶部留出顶部栏空间
          final contentTopPad0 = topPad + backBtnSize;
          // t=0 自由高度 = 总高 - 顶部栏 - 封面 - gap - 标题 - 控件
          final freeH0 =
              (maxH -
                      contentTopPad0 -
                      coverLarge -
                      12 -
                      titleH -
                      controlsH -
                      extraBottom)
                  .clamp(0.0, maxH);
          final edgePad0 = freeH0 / 2;
          // 封面 t=0 位置：水平居中，略上移（edgePad 的 40%）让上方留白少、
          // 下方与进度条分离更明显
          final coverLeft0 = (maxW - coverLarge) / 2;
          final coverTop0 = contentTopPad0 + edgePad0 * 0.6;
          // 标题 t=0 位置：封面下方，gap 略大
          final titleTop0 = coverTop0 + coverLarge + 16;
          // 控件 t=0 位置：底部 edgePad + extraBottom（预留底边距）
          final controlsBottom0 = edgePad0 + extraBottom;

          // ── t=1 时的坐标（歌词页布局） ──
          // 封面 t=1 位置：返回按钮右侧，与返回按钮垂直居中
          final coverLeft1 = backBtnLeft + backBtnSize + 8; // 按钮left+宽+spacer
          final coverTop1 = backBtnCenterY - coverSmall / 2;
          // 标题 t=1 位置：封面右侧，垂直居中
          final titleLeft1 = coverLeft1 + coverSmall + 10;
          final titleTop1 = coverTop1 + (coverSmall - titleH) / 2;
          // 控件 t=1 位置：贴底（留 extraBottom 底边距）
          final controlsBottom1 = extraBottom;

          // ── 线性插值 ──
          final coverLeft = coverLeft0 + (coverLeft1 - coverLeft0) * t;
          final coverTop = coverTop0 + (coverTop1 - coverTop0) * t;
          final titleLeft = 0.0 + (titleLeft1 - 0.0) * t;
          final titleTop = titleTop0 + (titleTop1 - titleTop0) * t;
          // 标题宽度：t=0 撑满（居中），t=1 封面右侧到屏幕右边缘
          final titleWidth0 = maxW;
          final titleWidth1 = maxW - titleLeft1 - sidePad;
          final titleWidth = titleWidth0 + (titleWidth1 - titleWidth0) * t;
          // 标题对齐：t=0 居中(0)，t=1 左对齐(-1)
          final alignX = -t;
          final controlsBottom =
              controlsBottom0 + (controlsBottom1 - controlsBottom0) * t;

          // ── 歌词面板：固定于歌词页最终位置与全高（不随过渡展开），
          // 切换仅靠 Opacity 淡入淡出——歌词区本来就在那里 ──
          final lyricsTop = titleTop1 + titleH1 + 12;
          final lyricsBottom = controlsBottom1 + controlsH + 12;
          final lyricsH = (maxH - lyricsTop - lyricsBottom).clamp(0.0, maxH);

          // ── 字号插值 ──
          final titleFontSize =
              22.0 + (16.0 - 22.0) * t; // titleLarge→titleMedium
          final artistFontSize =
              14.0 + (12.0 - 14.0) * t; // bodyMedium→bodySmall
          final titleGap = 6.0 + (2.0 - 6.0) * t;
          // 封面圆角插值：t=0 大圆角 18，t=1 小圆角 10
          final coverRadius = 18.0 + (10.0 - 18.0) * t;

          return Stack(
            children: [
              // ── 标题 + 歌手（单实例，位置/宽度/对齐/字号插值） ──
              // 对齐过渡：alignX 从 0（居中）→ -1（左对齐）
              // Align 控制 Text 在可用宽度内的水平位置，实现平滑过渡
              Positioned(
                left: titleLeft,
                top: titleTop,
                width: titleWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Align(
                      alignment: Alignment(alignX, 0),
                      child: Text(
                        song.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: titleFontSize,
                        ),
                      ),
                    ),
                    SizedBox(height: titleGap),
                    Align(
                      alignment: Alignment(alignX, 0),
                      child: Text(
                        player.isTrial
                            ? '${song.artistsLabel} · 试听片段'
                            : song.artistsLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: player.isTrial
                              ? cs.error
                              : cs.onSurfaceVariant,
                          fontSize: artistFontSize,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // ── 歌词面板（始终存在于 Stack children 列表，避免列表长度变化
              // 导致后续 Positioned 的 State 丢失。固定于最终位置与全高，切换
              // 仅透明度淡入淡出；t<0.5 时不命中指针，避免隐形歌词挡在中间。
              // 左边界扩展 kLyricLeftBuffer：逐字放大向左溢出时进入可见缓冲，
              // 不会被视口左缘裁掉） ──
              Positioned(
                left: lyricSidePad - kLyricLeftBuffer,
                right: lyricSidePad,
                top: lyricsTop,
                height: lyricsH > 0.1 ? lyricsH : 0.0,
                child: IgnorePointer(
                  ignoring: t < 0.5,
                  child: Opacity(
                    // 淡入滞后：easeInCubic 前半段歌词很淡，快到切换完成才明显
                    // 浮现；淡出同曲线先快后慢（t 从 1 走低时迅速淡去）。
                    opacity: Curves.easeInCubic.transform(t),
                    child: _LyricPanel(
                      songId: song.id,
                      songKey: '${song.source}_${song.id}',
                      height: lyricsH > 0.1 ? lyricsH : 0,
                      reloadToken: player.contentTick,
                    ),
                  ),
                ),
              ),
              // ── 进度条 + 控件（单实例，bottom 插值） ──
              Positioned(
                left: sidePad,
                right: sidePad,
                bottom: controlsBottom,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _NowPlayingProgress(player: player),
                    // 音质信息紧贴进度条下方，时间行之上的小字
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _buildQuality(cs),
                    ),
                    const SizedBox(height: 10),
                    _buildControls(cs, player),
                  ],
                ),
              ),
              // ── 封面（单实例，位置直线插值；放在 Stack 最后 = 最上层，
              // 避免标题移动时从封面图片上方扫过造成视觉遮挡） ──
              Positioned(
                left: coverLeft,
                top: coverTop,
                child: _buildCover(
                  cs,
                  song.coverFor(1000),
                  coverSize,
                  coverRadius,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCover(
    ColorScheme cs,
    String? cover,
    double size,
    double radius,
  ) {
    final song = context.read<PlayerProvider>().currentSong;
    final songKey = song != null ? '${song.source}_${song.id}' : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: cover != null && cover.isNotEmpty
            ? CoverImage(
                url: cover,
                songKey: songKey,
                // 断网加载失败后，随播放自愈成功（contentTick+1）重试封面。
                reloadToken: context.read<PlayerProvider>().contentTick,
                placeholder: _coverFallback(cs),
              )
            : _coverFallback(cs),
      ),
    );
  }

  Widget _coverFallback(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Icon(
        Icons.music_note_rounded,
        size: 72,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  Widget _buildControls(ColorScheme cs, PlayerProvider player) {
    final liked = context.watch<LikedSongsProvider>();
    final song = player.currentSong;
    // 极窄屏/超大字号下整行按比例缩放，避免两端模式按钮挤爆 Row。
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 收藏：本地「我喜欢的音乐」。实心=已收藏，空心=未收藏；点击切换。
          _compactButton(
            icon: (song != null && liked.isLiked(song))
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            iconSize: 24,
            enabled: song != null,
            onPressed: song == null
                ? () {}
                : () => _toggleFavorite(context, liked, player, song),
            color: (song != null && liked.isLiked(song))
                ? cs.error
                : cs.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 8),
          // 随机播放开关（与循环模式正交）：无背景、均用主题色——开启=实色、关闭=浅色。
          _compactButton(
            icon: Icons.shuffle_rounded,
            iconSize: 24,
            enabled: true,
            onPressed: player.toggleShuffle,
            color: player.shuffleMode
                ? cs.primary
                : cs.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 8),
          _compactButton(
            icon: Icons.skip_previous_rounded,
            iconSize: 30,
            enabled: player.hasPrevious,
            onPressed: player.previous,
            color: player.hasPrevious
                ? cs.primary
                : cs.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 12),
          if (player.buffering)
            SizedBox(
              width: 52,
              height: 52,
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: cs.primary,
                ),
              ),
            )
          else
            IconButton(
              iconSize: 52,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              splashRadius: 26,
              icon: Icon(
                player.playing
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_filled_rounded,
                size: 52,
                color: cs.primary,
              ),
              onPressed: player.toggle,
            ),
          const SizedBox(width: 12),
          _compactButton(
            icon: Icons.skip_next_rounded,
            iconSize: 30,
            enabled: player.hasNext,
            onPressed: player.next,
            color: player.hasNext
                ? cs.primary
                : cs.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 8),
          // 循环模式切换：列表循环 ⇄ 单曲循环 ⇄ 不循环。
          // 图标：单曲=repeat_one、列表/不循环=repeat；颜色：不循环=浅、循环=实色。
          _compactButton(
            icon: player.loopMode == LoopMode.single
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            iconSize: 24,
            enabled: true,
            onPressed: player.cycleLoopMode,
            color: player.loopMode == LoopMode.off
                ? cs.primary.withValues(alpha: 0.4)
                : cs.primary,
          ),
          const SizedBox(width: 8),
          // 队列：弹出播放列表 Sheet（从顶部栏挪入控制行，全屏页右上角腾位）。
          _compactButton(
            icon: Icons.queue_music_rounded,
            iconSize: 24,
            enabled: true,
            onPressed: () => QueueSheet.show(context),
            color: cs.primary.withValues(alpha: 0.85),
          ),
        ],
      ),
    );
  }

  /// 紧凑 IconButton：收敛到图标本身大小（无触控区最小约束），不悬浮提示。
  ///
  /// 状态差异靠 [color] 表达（无背景，主题色=开启），循环单曲/列表再用图标区分：
  /// 随机：开启=主题色、关闭=灰；单曲循环=repeat_one+主题色、列表循环=repeat。
  Widget _compactButton({
    required IconData icon,
    required double iconSize,
    required bool enabled,
    required VoidCallback onPressed,
    Color? color,
  }) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      splashRadius: iconSize / 2,
      constraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: iconSize, color: color ?? cs.onSurfaceVariant),
    );
  }

  /// 播放页红心：切换当前歌曲收藏。
  ///
  /// 通知栏收藏按钮图标由 PlayerProvider 的 liked 订阅统一同步，此处无需
  /// 手动调用 MediaSessionManager。
  Future<void> _toggleFavorite(
    BuildContext context,
    LikedSongsProvider liked,
    PlayerProvider player,
    Song song,
  ) async {
    final nowLiked = await liked.toggle(song);
    if (!context.mounted) return;
    AppToast.show(
      context,
      nowLiked ? '已收藏到「我喜欢的音乐」' : '已取消收藏',
    );
  }

  Widget _buildQuality(ColorScheme cs) {
    final player = context.watch<PlayerProvider>();
    final level = player.currentLevel;
    final br = player.currentBr;
    final type = player.currentType;
    final isTrial = player.isTrial;

    // 实际档位 → 中文标签（与 SettingsProvider.qualityOptions 对齐）
    String levelLabel = '未知';
    if (level != null) {
      for (final opt in SettingsProvider.qualityOptions) {
        if (opt.$1 == level) {
          levelLabel = opt.$2;
          break;
        }
      }
      if (levelLabel == '未知') levelLabel = level;
    }

    // 顺序：音质 → 格式 → kbps → 试听
    final parts = <String>[levelLabel];
    if (type != null && type.isNotEmpty) {
      parts.add(type.toUpperCase());
    }
    if (br > 0) {
      parts.add('${(br / 1000).round()}kbps');
    }
    if (isTrial) {
      parts.add('试听');
    }
    // 音质未解析（level 为 null）时整行只含「未知」，用透明度归零隐藏；
    // 保留占位避免解析后出现布局抖动。
    final resolved = level != null;

    return Opacity(
      opacity: resolved ? 1 : 0,
      child: Text(
        parts.join(' · '),
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 歌词面板：监听播放进度，加载歌词并驱动逐字揭示。
///
/// 复用封面区域高度，点击顶部"词"按钮后替代封面显示。
class _LyricPanel extends StatefulWidget {
  final int songId;
  final String? songKey;
  final double height;

  /// 歌词字号。窄屏默认 20；宽屏按列宽自适应传入更大值。
  final double fontSize;

  /// 内容重载信号：变化且当前歌词为空时重新加载（覆盖断网失败/真无歌词）。
  /// 配合 [PlayerProvider.contentTick] 在自愈续播成功后重试断网失败的歌词。
  final int? reloadToken;

  const _LyricPanel({
    required this.songId,
    this.songKey,
    required this.height,
    this.fontSize = 20,
    this.reloadToken,
  });

  @override
  State<_LyricPanel> createState() => _LyricPanelState();
}

class _LyricPanelState extends State<_LyricPanel> {
  /// 进程级 LyricProvider 单例（首次访问时从 NeteaseProvider 取 api 构造）。
  static LyricProvider? _provider;

  List<LyricLine> _lines = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  @override
  void didUpdateWidget(covariant _LyricPanel old) {
    super.didUpdateWidget(old);
    if (old.songId != widget.songId) {
      _loadLyrics();
    } else if (old.reloadToken != widget.reloadToken &&
        _lines.isEmpty &&
        !_loading) {
      // 当前显示为空（断网加载失败 / 真无歌词）时，随播放自愈成功
      // （contentTick+1）重新请求。不再依赖「load 抛异常」这一契约：
      // 即使将来 LyricProvider 吞回异常，这里仍能重试。
      _loadLyrics();
    }
  }

  Future<void> _loadLyrics() async {
    final netease = context.read<NeteaseProvider>();
    if (!netease.initialized) {
      setState(() {
        _loading = false;
        _lines = const [];
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final provider = _provider ??= LyricProvider(netease.api);
      final lines = await provider.load(widget.songId, songKey: widget.songKey);
      if (mounted) {
        setState(() {
          _lines = lines;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _lines = const [];
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.onSurfaceVariant,
                ),
              ),
            )
          : _lines.isEmpty
          ? Center(
              child: Text(
                '暂无歌词',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            )
          : StreamBuilder<Duration>(
              stream: context.read<PlayerProvider>().positionStream,
              builder: (context, snap) {
                final pos = snap.data?.inMilliseconds ?? 0;
                final settings = context.watch<SettingsProvider>();
                return LyricView(
                  lines: _lines,
                  currentTimeMs: pos,
                  activeColor: cs.primary,
                  inactiveColor: cs.onSurfaceVariant,
                  fontSize: widget.fontSize,
                  lineLyricRevealMode: settings.lineLyricRevealMode,
                  lyricDepthBlur: settings.lyricDepthBlur,
                  lyricSpringEnabled: settings.lyricSpringEnabled,
                  lyricSpringPreset: settings.lyricSpringPreset,
                  onSeekLine: (startMs) {
                    context.read<PlayerProvider>().seek(
                      Duration(milliseconds: startMs),
                    );
                  },
                  onLyricLongPress: (startMs) {
                    AppToast.show(context, '歌词截图分享：待实现');
                  },
                );
              },
            ),
    );
  }
}

/// 进度条：已播段略粗于未播段；播放中顶部有一道流动的波浪；支持点击/拖动跳转。
class _NowPlayingProgress extends StatefulWidget {
  final PlayerProvider player;

  /// 轨道最大宽度（可见线宽，不含两侧时间标签的 trackPad）。null = 不限制
  /// （窄屏全宽）；宽屏传入控制行宽，让轨道两端与控制行对齐。
  final double? maxWidth;

  const _NowPlayingProgress({required this.player, this.maxWidth});

  @override
  State<_NowPlayingProgress> createState() => _NowPlayingProgressState();
}

class _NowPlayingProgressState extends State<_NowPlayingProgress>
    with TickerProviderStateMixin {
  /// 波浪相位驱动（循环）。周期 = WAVE_ANIMATION_DURATION = 2s。
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );

  /// 波浪振幅（0..1）：播放中推进到满幅，暂停/拖动回归 0（变平线）。
  /// 拖动起止复用此控制器，与暂停过渡一致（500ms），避免瞬时切换。
  late final AnimationController _amp = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  /// 拖动中的临时进度（0..1）；null = 跟随实际播放。
  double? _drag;

  /// 实时位置（从 positionStream 手动订阅，避免 StreamBuilder builder 时序问题）。
  int _liveMs = 0;
  int _durMs = 0;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// 进度条 RenderBox 的 key，用于 globalToLocal 精确换算拖动位置。
  /// 不依赖 DragUpdateDetails.localPosition（其坐标系在某些场景下可能与
  /// GestureDetector 的 RenderBox 不一致，导致拖动位置归零）。
  final GlobalKey _trackKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // _wave/_amp 每帧变化 → setState（CustomPaint 重绘）
    _wave.addListener(_onAnimTick);
    _amp.addListener(_onAnimTick);
    // 手动订阅位置/时长流：_dragStart 等 setState 不会被 StreamBuilder 忽略。
    _subs.add(
      widget.player.durationStream.listen((d) {
        if (!mounted) return;
        setState(() => _durMs = d?.inMilliseconds ?? 0);
      }),
    );
    _subs.add(
      widget.player.positionStream.listen((p) {
        if (!mounted) return;
        setState(() => _liveMs = p.inMilliseconds);
      }),
    );
  }

  void _onAnimTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _wave.removeListener(_onAnimTick);
    _amp.removeListener(_onAnimTick);
    _wave.dispose();
    _amp.dispose();
    super.dispose();
  }

  void _syncWave() {
    final playing = widget.player.playing;
    if (playing) {
      if (!_wave.isAnimating) _wave.repeat();
      // 拖动期间 _amp 由 _dragStart/_dragEnd 控制，跳过避免冲突
      if (_drag == null && !_amp.isAnimating && _amp.value < 1) _amp.forward();
    } else {
      if (_wave.isAnimating) _wave.stop();
      if (_amp.value > 0) _amp.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncWave();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final durMs = _durMs;
    final liveMs = _liveMs;
    // _drag 已是 0..1 归一化比例；liveMs 是毫秒需除以 durMs。
    // 两者单位不同，必须分支处理，否则 _drag/durMs 恒≈0。
    final progress = _drag != null
        ? _drag!.clamp(0.0, 1.0)
        : (durMs <= 0 ? 0.0 : (liveMs / durMs).clamp(0.0, 1.0));
    final dpr = MediaQuery.devicePixelRatioOf(context);

    // 进度条与时间标签共享左右 padding，让时间标签内缩与进度条两端对齐
    const trackPad = 32.0;
    // 宽屏限定轨道最大宽度（可见线宽）时居中：组件总宽 = 轨道宽 + 两侧 trackPad，
    // 这样轨道（而非含 padding 的整体）与控制行同宽。
    final trackMaxW = widget.maxWidth ?? double.infinity;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: trackMaxW + 2 * trackPad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: trackPad),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackWidth = constraints.maxWidth;
              return GestureDetector(
                key: _trackKey,
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) => _dragStart(d, trackWidth),
                onHorizontalDragUpdate: (d) => _dragUpdate(d, trackWidth),
                onHorizontalDragEnd: (d) => _dragEnd(durMs),
                onTapUp: (d) => _tapSeek(d, durMs, trackWidth),
                child: CustomPaint(
                  painter: _WaveTrackPainter(
                    progress: progress,
                    phase: _wave.value * math.pi * 2,
                    // _amp 统一控制振幅：播放→1、暂停/拖动→0，过渡 500ms
                    amplitude: _amp.value * (kWaveAmplitude / dpr),
                    inactive: cs.onSurfaceVariant.withValues(alpha: 0.4),
                    active: cs.primary,
                    thumb: cs.primary,
                    dpr: dpr,
                  ),
                  child: const SizedBox(height: 35, width: double.infinity),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(
            top: 2,
            left: trackPad,
            right: trackPad,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  _PlayerPageState._fmt(
                    Duration(
                      milliseconds: _drag != null
                          ? (_drag! * durMs).round()
                          : liveMs,
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Flexible(
                child: Text(
                  _PlayerPageState._fmt(Duration(milliseconds: durMs)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
        ),
      ),
    );
  }

  /// 从拖动/点击详情中提取相对于进度条的归一化进度（0..1）。
  ///
  /// 使用 RenderBox.globalToLocal 而非 details.localPosition，因为
  /// localPosition 的坐标系在某些布局下（如嵌套 ScrollView）可能
  /// 不指向 GestureDetector 自身的 RenderBox，导致计算结果恒为 0。
  double _resolveProgress(Offset globalPosition) {
    final box = _trackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    final local = box.globalToLocal(globalPosition);
    final w = box.size.width;
    if (w <= 0) return 0;
    return (local.dx / w).clamp(0.0, 1.0).toDouble();
  }

  void _tapSeek(TapUpDetails d, int durMs, double trackWidth) {
    if (trackWidth <= 0) return;
    _seekTo(_resolveProgress(d.globalPosition), durMs);
  }

  void _dragStart(DragStartDetails d, double trackWidth) {
    if (trackWidth <= 0) return;
    _drag = _resolveProgress(d.globalPosition);
    // 复用 _amp：与暂停过渡一致的 500ms 平滑收敛到 0
    _amp.reverse();
    setState(() {});
  }

  void _dragUpdate(DragUpdateDetails d, double trackWidth) {
    if (trackWidth <= 0) return;
    _drag = _resolveProgress(d.globalPosition);
    setState(() {});
  }

  void _dragEnd(int durMs) {
    final v = _drag;
    _drag = null;
    // 播放中：_amp 平滑恢复到满幅；暂停态：_syncWave 会保持 reverse
    if (widget.player.playing) _amp.forward();
    if (v == null || durMs <= 0) {
      setState(() {});
      return;
    }
    widget.player.seek(Duration(milliseconds: (v * durMs).round()));
    setState(() {});
  }

  void _seekTo(double v, int durMs) {
    if (durMs <= 0) return;
    final target = (v * durMs).round();
    widget.player.seek(Duration(milliseconds: target));
  }
}

/// 进度条：
/// 整条为一根正弦波浪线。未播段画同一路径的细灰线；已播段用 clipRect 限定到
/// 进度点左侧，重画为较粗的主题色线（即"已播略粗于未播"）。播放中振幅放大到
/// [kWaveAmplitude] 且相位随时间流动（海浪向左推进），暂停/拖动时振幅归零变平线。
/// 圆形拇指贴合进度点所在的波形。
class _WaveTrackPainter extends CustomPainter {
  final double progress;
  final double phase;
  final double amplitude;
  final Color inactive;
  final Color active;
  final Color thumb;

  /// 目标设备像素比。常量基于**物理 px**，Flutter 的 Canvas 逻辑像素
  /// 必须除以 DPR 才能得到一致的视觉比例。见类文档。
  final double dpr;

  _WaveTrackPainter({
    required this.progress,
    required this.phase,
    required this.amplitude,
    required this.inactive,
    required this.active,
    required this.thumb,
    required this.dpr,
  });

  // ---- 原始物理 px 常量（Compose drawscope 单位）----
  static const _frequencyPx = 0.08; // 每物理 px 的弧度系数（WAVE_FREQUENCY）
  static const _spacingPx = 6.0; // 采样步进（WAVE_SAMPLE_SPACING_PX）
  static const _minSegments = 48; // MIN_WAVE_SEGMENTS
  static const _maxSegments = 180; // MAX_WAVE_SEGMENTS
  static const _inactiveWidthPx = 4.0; // 未播段线宽
  static const _activeWidthPx = 6.0; // 已播段线宽
  static const _thumbRadiusPx = 16.0; // 拇指半径
  static const _thumbInsetPx = 5.0; // 白芯半径（视觉收口）

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final progressPx = progress * size.width;
    final amp = amplitude;

    // 逻辑 px → 物理 px 折算系数（dpr 越大，每个视觉元素越"小"）。
    final k = 1 / dpr;
    final frequency = _frequencyPx / k; // ×dpr，波长按比例缩短
    final spacing = _spacingPx * k;
    final inactiveWidth = _inactiveWidthPx * k;
    final activeWidth = _activeWidthPx * k;
    final thumbRadius = _thumbRadiusPx * k;
    final thumbInset = _thumbInsetPx * k;

    final segmentCount = (size.width / spacing).ceil().clamp(
      _minSegments,
      _maxSegments,
    );
    final segmentWidth = size.width / segmentCount;

    // 一条正弦波浪路径（整条进度条就是这条线）。
    final wave = Path()..moveTo(0, centerY + math.sin(phase) * amp);
    for (var i = 1; i <= segmentCount; i++) {
      final x = i * segmentWidth;
      final angle = x * frequency + phase;
      wave.lineTo(x, centerY + math.sin(angle) * amp);
    }

    // 未播段：整条细灰线
    canvas.drawPath(
      wave,
      Paint()
        ..color = inactive
        ..style = PaintingStyle.stroke
        ..strokeWidth = inactiveWidth
        ..strokeCap = StrokeCap.round,
    );

    // 已播段：裁剪到 progress 左侧，用主题色较粗线重画同一条路径
    if (progressPx > 0) {
      canvas
        ..save()
        ..clipRect(Rect.fromLTRB(0, 0, progressPx, size.height));
      canvas.drawPath(
        wave,
        Paint()
          ..color = active
          ..style = PaintingStyle.stroke
          ..strokeWidth = activeWidth
          ..strokeCap = StrokeCap.round,
      );
      canvas.restore();
    }

    // 圆形拇指：贴合进度点对应波形
    final thumbY = centerY + math.sin(progressPx * frequency + phase) * amp;
    final thumbCenter = Offset(progressPx, thumbY);
    canvas
      ..drawCircle(thumbCenter, thumbRadius, Paint()..color = thumb)
      ..drawCircle(thumbCenter, thumbInset, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_WaveTrackPainter old) =>
      old.progress != progress ||
      old.phase != phase ||
      old.amplitude != amplitude ||
      old.inactive != inactive ||
      old.active != active ||
      old.dpr != dpr;
}

class _NoNowPlaying extends StatelessWidget {
  const _NoNowPlaying();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.music_off_rounded, size: 56, color: cs.outlineVariant),
          const SizedBox(height: 12),
          Text(
            '当前没有播放内容',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
