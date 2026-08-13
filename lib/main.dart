import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/audio_cache/audio_cache.dart';
import 'core/cover_color_extractor.dart';
import 'core/logging/app_crash.dart';
import 'core/logging/app_log.dart';
import 'core/localizations/zh.dart';
import 'core/player/playback_migration.dart';
import 'core/player/playback_storage.dart';
import 'core/playback_stats/database_helper.dart';
import 'models/song.dart';
import 'pages/login/qr_login_page.dart';
import 'pages/main_scaffold.dart';
import 'providers/netease_provider.dart';
import 'providers/player_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/home_provider.dart';
import 'providers/radar_provider.dart';
import 'providers/daily_provider.dart';
import 'providers/liked_songs_provider.dart';
import 'providers/search_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/theme_provider.dart';
import 'widgets/player_persistence_guard.dart';
import 'widgets/theme_switch_diff.dart';
import 'widgets/title_bar.dart';

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // 日志系统：滚动文件落盘，best-effort，失败静默不影响主流程。
      await AppLog.init();
      // 崩溃日志系统：与 AppLog 解耦，不受「记录日志」开关影响。
      await AppCrash.init();
      // 挂 Flutter/引擎未处理错误钩子（保留框架默认行为，仅追加落盘）。
      AppCrash.installHandlers();
      // 音频磁盘缓存：本地代理 + store，best-effort，失败静默走 CDN。
      await AudioCache.init();

      // 播放记录数据库初始化（Windows 需要 FFI）
      DatabaseHelper.init();

      // 网络/风控配置必须先于任何请求就绪：NeteaseProvider.init → registerAnon
      // 会立即发网络请求并读取 NeteaseConfig 静态值。因此在 runApp 前 await init，
      // 而不是依赖 MultiProvider 的懒加载顺序。
      final settings = SettingsProvider();
      await settings.init();
      // 用户可能在设置里关闭了日志落盘：把持久化开关同步到 AppLog（默认开启）。
      // 必须先于任何日志写入，否则关闭状态下启动日志仍会落盘。
      AppLog.setUserEnabled(settings.logEnabled);
      AppLog.info('FluxWave 启动', tag: 'app');

      // 播放器状态（队列/进度）持久化：先迁移最早的单键快照，之后恢复交给
      // PlayerProvider 在首帧后异步执行 —— 不再在 runApp 前同步 load()，
      // 大队列的读盘 + 解析都在后台 isolate（见 PlayerPlaybackStorage.load）。
      final playbackStorage = await PlayerPlaybackStorage.init();
      await migrateLegacy(playbackStorage);

      // 桌面端：隐藏系统标题栏，由自定义 TitleBar 接管
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        try {
          await windowManager.ensureInitialized();
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          // 调试包在窗口标题上带 "Dev" 标识，肉眼可辨（不比 Android 那样
          // 分包名/应用名，Windows 不做产物拆分，这里的标题即区分手段）。
          await windowManager.setTitle(
            kDebugMode ? 'FluxWave Dev' : 'FluxWave',
          );
          TitleBar.enabled = true;
        } catch (_) {
          // window_manager 初始化失败，回退到系统标题栏
        }
      }

      runApp(FluxWaveApp(settings: settings, playbackStorage: playbackStorage));
    },
    (error, stack) {
      // Zone 内未捕获异步异常 → 崩溃留痕。
      AppCrash.reportZoneError(error, stack);
    },
  );
}

class FluxWaveApp extends StatefulWidget {
  final SettingsProvider settings;
  final PlayerPlaybackStorage? playbackStorage;
  const FluxWaveApp({super.key, required this.settings, this.playbackStorage});

  @override
  State<FluxWaveApp> createState() => _FluxWaveAppState();
}

class _FluxWaveAppState extends State<FluxWaveApp>
    with TickerProviderStateMixin {
  static const _revealDuration = Duration(milliseconds: 720);

  final GlobalKey _boundaryKey = GlobalKey();

  /// 切换主题前的旧画面快照（作为下层背景，不裁剪）。
  ui.Image? _oldSnapshot;
  Offset? _revealOrigin;
  double _revealStartRadius = 0;

  late final AnimationController _revealController;

  @override
  void initState() {
    super.initState();
    // 初始停在 1.0（不裁剪）；切换时从 0 向外扩散到 1。
    _revealController = AnimationController(
      vsync: this,
      duration: _revealDuration,
      value: 1.0,
    )..addStatusListener(_onRevealStatus);
  }

  @override
  void dispose() {
    _oldSnapshot?.dispose();
    _revealController.dispose();
    super.dispose();
  }

  void _onRevealStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    _oldSnapshot?.dispose();
    setState(() {
      _oldSnapshot = null;
      _revealOrigin = null;
      _revealStartRadius = 0;
    });
  }

  /// 截取当前（旧主题）画面作为背景，切换主题后新主题从点击点向外扩散。
  ///
  /// [setThemeMode] 由调用侧（外层 `Consumer<ThemeProvider>`）注入，避免在此
  /// 通过跨层 `context.read` 耦合 Provider，也无需依赖 `_boundaryKey.currentContext`。
  Future<void> startReveal({
    required Offset origin,
    required double startRadius,
    required ThemeMode newMode,
    required Future<void> Function(ThemeMode) setThemeMode,
  }) async {
    if (_revealController.isAnimating) return;

    ui.Image? snapshot;
    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary != null) {
      try {
        snapshot = await boundary.toImage(
          pixelRatio: math.min(
            View.of(_boundaryKey.currentContext!).devicePixelRatio,
            1.5,
          ),
        );
      } catch (_) {
        snapshot = null;
      }
    }

    if (!mounted) return;
    setState(() {
      _oldSnapshot = snapshot;
      _revealOrigin = origin;
      _revealStartRadius = startRadius;
    });

    try {
      await setThemeMode(newMode);
    } finally {
      // 无论 setThemeMode 是否成功，都要启动扩散或收尾清理快照，
      // 避免异常路径下 _oldSnapshot 永不释放。
      if (mounted && snapshot != null) {
        _revealController.forward(from: 0);
      } else {
        _revealController.value = 1.0;
        _oldSnapshot?.dispose();
        _oldSnapshot = null;
        _revealOrigin = null;
        _revealStartRadius = 0;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = RepaintBoundary(
      key: _boundaryKey,
      child: Consumer<ThemeProvider>(
        builder: (context, tp, _) {
          // Android：系统底部导航栏（手势区「小白条」）设为透明 + 图标亮度跟随主题，
          // 让悬浮毛玻璃导航无缝延伸到屏幕底边；AnnotatedRegion 随主题切换自动更新。
          final platform = MediaQuery.platformBrightnessOf(context);
          final brightness = tp.resolveBrightness(tp.themeMode, platform);
          final uiStyle = SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: brightness,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
          );
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: uiStyle,
            child: MaterialApp(
              title: 'FluxWave',
              debugShowCheckedModeBanner: false,
              theme: tp.lightTheme,
              darkTheme: tp.darkTheme,
              themeMode: tp.themeMode,
              // 轻量本地化：仅把文本选择菜单的「复制/全选」译为中文，体积零成本。
              // WidgetsLocalizations 由框架自动兜底（DefaultWidgetsLocalizations）。
              localizationsDelegates: const [ZhLocalizationsDelegate()],
              home: const MainScaffold(),
              routes: {'/login/qr': (context) => const QrLoginPage()},
            ),
          );
        },
      ),
    );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.settings),
        ChangeNotifierProvider(create: (_) => ThemeProvider()..init()),
        ChangeNotifierProvider(create: (_) => NeteaseProvider()..init()),
        // 我喜欢的音乐：本地收藏集合（SQLite liked_song 表），播放器切歌/
        // 通知栏收藏都依赖它，故置于 PlayerProvider 之前。
        ChangeNotifierProvider(create: (_) => LikedSongsProvider()..load()),
        // 播放器在 NeteaseProvider 之后创建；api 在播放时才解析（init 异步完成）。
        ChangeNotifierProvider(
          create: (ctx) => PlayerProvider(
            netease: ctx.read<NeteaseProvider>(),
            settings: ctx.read<SettingsProvider>(),
            liked: ctx.read<LikedSongsProvider>(),
            storage: widget.playbackStorage,
          )..init(),
        ),
        // 搜索状态跨 Tab 存活（页面切换 dispose 不丢结果/关键词）。
        ChangeNotifierProvider(create: (_) => SearchProvider()),
        // 我的歌单状态：同 uid 缓存拉取结果，切换账号/登出时清空。
        ChangeNotifierProvider(create: (_) => PlaylistProvider()),
        // 首页推荐歌单：匿名可用，整树存续期内仅拉一次（下拉/重试再拉）。
        ChangeNotifierProvider(create: (_) => HomeProvider()),
        // 雷达歌单合集：登录后进入雷达页时才预取（显式触发，见 RadarPage）。
        ChangeNotifierProvider(create: (_) => RadarProvider()),
        // 每日推荐：登录后进入每日推荐页时才预取（显式触发，见 DailyPage）。
        ChangeNotifierProvider(create: (_) => DailyProvider()),
      ],
      // 退出/退后台前的落盘兜底（桌面拦截关闭 await flush；移动端退后台即 flush）。
      child: PlayerPersistenceGuard(
        // 从本层 Provider 注入 setThemeMode，startReveal 不再跨层 read。
        child: Consumer<ThemeProvider>(
          builder: (context, tp, _) {
            return ThemeRevealScope(
              startReveal:
                  ({required origin, required startRadius, required newMode}) =>
                      startReveal(
                        origin: origin,
                        startRadius: startRadius,
                        newMode: newMode,
                        setThemeMode: tp.setThemeMode,
                      ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final screenSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        // 背景：旧主题整屏画面（静态，不裁剪）。
                        if (_oldSnapshot != null)
                          Positioned.fill(
                            child: RawImage(
                              image: _oldSnapshot,
                              fit: BoxFit.cover,
                            ),
                          ),
                        // 前景：新主题，从点击点向外放大的圆形裁剪 + 边缘光晕。
                        AnimatedBuilder(
                          animation: _revealController,
                          // 监听当前歌曲封面，动态取色后更新主题种子（切歌保留旧色，
                          // 新色解析成功后替换）。
                          child: _CoverSeedWatcher(child: app),
                          builder: (context, child) {
                            final t = Curves.fastOutSlowIn.transform(
                              _revealController.value,
                            );
                            final origin = _revealOrigin ?? Offset.zero;
                            final radius = revealRadiusAt(
                              origin: origin,
                              screenSize: screenSize,
                              startRadius: _revealStartRadius,
                              progress: t,
                            );
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipPath(
                                  clipper: CircleRevealClipper(
                                    origin: origin,
                                    progress: t,
                                    startRadius: _revealStartRadius,
                                    screenSize: screenSize,
                                  ),
                                  child: child!,
                                ),
                                // 扩散边缘一圈白色光晕，
                                // 随扩散结束淡出，让新旧主题交界更柔和。
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _RevealHaloPainter(
                                        center: origin,
                                        innerRadius: radius,
                                        outerRadius: radius * 1.12,
                                        alpha: (1 - t) * 0.08,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 扩散边缘的白色光晕：
/// 在新主题圆形外再画一圈径向渐变白，随进度淡出，让新旧主题交界更柔和。
class _RevealHaloPainter extends CustomPainter {
  final Offset center;
  final double innerRadius;
  final double outerRadius;
  final double alpha;

  _RevealHaloPainter({
    required this.center,
    required this.innerRadius,
    required this.outerRadius,
    required this.alpha,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (alpha <= 0.001 || outerRadius <= innerRadius) return;
    // 外层大圆减去内层实心圆 = 圆环，光晕只出现在新主题边缘一圈。
    final ring = Path()
      ..addOval(Rect.fromCircle(center: center, radius: outerRadius))
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: center, radius: innerRadius));
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Color.lerp(Colors.transparent, Colors.white, alpha)!,
          Colors.transparent,
        ],
        stops: const [0.82, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: outerRadius));
    canvas.drawPath(ring, paint);
  }

  @override
  bool shouldRepaint(_RevealHaloPainter oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.innerRadius != innerRadius ||
      oldDelegate.outerRadius != outerRadius ||
      oldDelegate.alpha != alpha;
}

/// 监听当前歌曲封面，动态取色后把种子色喂给 [ThemeProvider]。
///
/// - 只在切歌 / 动态取色开关变化时触发（用 context.select，不随播放进度重建）；
/// - 切歌后**保留旧色**，新封面颜色解析成功后替换（用户要求解析前沿用旧色）；
/// - 关闭动态取色时清空封面色，回到手动种子。
class _CoverSeedWatcher extends StatefulWidget {
  final Widget child;
  const _CoverSeedWatcher({required this.child});

  @override
  State<_CoverSeedWatcher> createState() => _CoverSeedWatcherState();
}

class _CoverSeedWatcherState extends State<_CoverSeedWatcher> {
  static const _kDebounce = Duration(milliseconds: 180);

  String? _startedUrl;
  bool? _startedEnabled;
  Timer? _debounce;

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);
    final enabled = context.select<ThemeProvider, bool>((t) => t.dynamicColor);
    final theme = context.read<ThemeProvider>();
    final url = song?.coverFor(300);

    if (url != _startedUrl || enabled != _startedEnabled) {
      _startedUrl = url;
      _startedEnabled = enabled;
      // 延迟到帧末执行，避免 build 期间调用 notifyListeners。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(theme, url, enabled);
      });
    }
    return widget.child;
  }

  void _sync(ThemeProvider theme, String? url, bool enabled) {
    _debounce?.cancel();
    if (!enabled) {
      // 关闭动态取色：清空封面色，回到手动种子。
      theme.setCoverSeedColor(null);
      return;
    }
    if (url == null) return; // 无封面：保留旧色。
    // 预热防抖：快速切歌时不反复下载/解码，稳定后才取色。
    _debounce = Timer(_kDebounce, () async {
      final color = await CoverColorExtractor.extract(url);
      if (!mounted) return;
      if (_startedUrl == url && theme.dynamicColor && color != null) {
        theme.setCoverSeedColor(color);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
