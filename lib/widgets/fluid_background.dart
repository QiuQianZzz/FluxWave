import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../core/color_readability.dart';
import '../core/cover_color_extractor.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';

/// 全屏播放页流体背景。
///
/// 用自定义 GLSL fragment shader（`shaders/fluid.frag`）渲染"伪流体"：
/// fbm 噪声 + 域扭曲 + 地形重塑生成流动的等高线场，从当前歌曲封面的
/// 主色板（[CoverColorExtractor.extractPalette]）查色，得到随封面变化的
/// 连续渐变流体（网易云 RefinedNowPlaying 风格）。
///
/// - 切歌防抖取色（300ms），最多取 [kMaxColors] 个主色直接作为 uniform
///   float 数组传给 shader（不经过纹理采样，兼容 Impeller/mobile GPU）；
/// - 动画：内部 Ticker，切后台（[TickerMode]）/ 关闭开关时自动停止；
/// - 开关：读 [SettingsProvider.fluidBackground]，关闭时零开销。
class FluidBackground extends StatefulWidget {
  const FluidBackground({super.key});

  /// shader 支持的最大色板颜色数（uColors[6] 数组）。
  static const int kMaxColors = 6;

  /// 当前封面强调色（经可读性修正，深色背景可用）。由色板稳定后发布，
  /// 播放页据此渲染控件/歌词强调色（null = 未就绪，回退主题 primary）。
  static final ValueNotifier<Color?> accentColor = ValueNotifier<Color?>(null);

  @override
  State<FluidBackground> createState() => _FluidBackgroundState();
}

class _FluidBackgroundState extends State<FluidBackground>
    with SingleTickerProviderStateMixin {
  ui.FragmentProgram? _program;
  late final Ticker _ticker;
  final _time = ValueNotifier<double>(0);

  /// shader 程序全局缓存：播放页每次打开都会重建 [FluidBackground]，
  /// 复用已编译的程序可省去每次进页的重新编译（asset 加载 + GLSL 编译）。
  static Future<ui.FragmentProgram>? _programCache;

  /// 色板未就绪时的内置兜底色（深蓝紫，贴合播放页深色基调）。
  /// 进页即用它渲染流体，取色完成后无缝替换，避免空白帧。
  static const List<Color> _fallbackPalette = [
    Color(0xFF123052),
    Color(0xFF1B3B6F),
    Color(0xFF263A6E),
    Color(0xFF37286B),
    Color(0xFF4A2B66),
  ];

  /// 当前应用的色板颜色（≤6）；null = 未就绪。
  List<Color>? _palette;

  /// 色板过渡（取色/切歌完成时从旧色渐入新色）。
  /// [_transitionStart]/[_transitionEnd] 为起止色板，
  /// [_paletteTransitionBlend] 0→1，由 ticker 逐帧推进，避免色板突变闪烁。
  List<Color> _transitionStart = _fallbackPalette;
  List<Color> _transitionEnd = _fallbackPalette;
  double _paletteTransitionBlend = 1;
  static const Duration _paletteTransitionDuration =
      Duration(milliseconds: 400);

  /// 当前实际渲染的色板（含过渡插值）；驱动 painter 重绘。
  final _displayPalette = ValueNotifier<List<Color>>(_fallbackPalette);

  /// 已取色的封面 key（`source_id`），切歌后重新取色。
  String? _paletteSongKey;
  Timer? _paletteDebounce;

  /// 律动状态（仅 [fluidBeat] 开启时使用）。
  StreamSubscription<Duration>? _positionSub;
  bool _beatEnabled = false;
  final _pulse = ValueNotifier<double>(0);

  /// BPM 估算（无音频数据，取流行乐常见节奏）。
  static const double _bpm = 120;

  /// 律动强度低通滤波系数（攻/释不对称）。
  static const double _pulseAttack = 0.35;
  static const double _pulseDecay = 0.06;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _loadShader();
    // 首帧后发布兜底色板的强调色，播放页无需等待取色完成。
    // 延迟到 post-frame：避免父级 build 期间监听者被通知。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _publishAccent(_fallbackPalette);
    });
  }

  Future<void> _loadShader() async {
    try {
      // 复用全局编译好的程序：首个调用编译，之后所有播放页实例直接复用。
      final program = await (_programCache ??=
          ui.FragmentProgram.fromAsset('shaders/fluid.frag'));
      if (!mounted) return;
      setState(() => _program = program);
      _syncTicker();
    } catch (_) {
      // shader 加载失败（如驱动不支持）：保持空白背景，静默降级。
    }
  }

  /// 上一帧 tick 时间（微秒），用于计算帧增量推进过渡。
  int _lastTickUs = 0;

  void _onTick(Duration elapsed) {
    _time.value = elapsed.inMicroseconds / 1e6;
    // 暂停/停止时 positionStream 不再发射，pulse 会冻结在最后值；
    // 每帧向 0 衰减，避免暂停后背景仍在"呼吸律动"。
    if (_beatEnabled && !context.read<PlayerProvider>().playing) {
      _pulse.value *= 0.9;
    }
    _advancePaletteTransition(elapsed.inMicroseconds - _lastTickUs);
    _lastTickUs = elapsed.inMicroseconds;
  }

  /// 推进色板渐变过渡：每帧把 blend 按时长推进一步，
  /// 用插值色板驱动 painter 重绘；完成后固化目标色板。
  void _advancePaletteTransition(int deltaUs) {
    if (_paletteTransitionBlend >= 1) return;
    _paletteTransitionBlend +=
        deltaUs / _paletteTransitionDuration.inMicroseconds;
    if (_paletteTransitionBlend >= 1) {
      _paletteTransitionBlend = 1;
      _displayPalette.value = List.of(_transitionEnd);
      _publishAccent(_transitionEnd);
    } else {
      _displayPalette.value =
          _lerpPalettes(_transitionStart, _transitionEnd, _paletteTransitionBlend);
    }
  }

  /// 从稳定色板挑选强调候选：饱和度最高且明度居中（接近 vibrant），
  /// 经可读性修正后发布到 [FluidBackground.accentColor]。
  void _publishAccent(List<Color> palette) {
    if (palette.isEmpty) {
      FluidBackground.accentColor.value = null;
      return;
    }
    Color? best;
    var bestScore = -1.0;
    for (final c in palette) {
      final hsl = HSLColor.fromColor(c);
      // 跳过过暗/过亮（对强调贡献低），饱和度 + 明度居中得分。
      if (hsl.lightness < 0.18 || hsl.lightness > 0.85) continue;
      final score = hsl.saturation - (hsl.lightness - 0.5).abs() * 0.6;
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    final candidate = best ?? palette.first;
    FluidBackground.accentColor.value =
        ReadableAccentResolver.resolve(candidate);
  }

  /// 是否应运行动画：开关开 + 前台 + shader 就绪。
  /// 单一启停源：`_syncTicker` 据此决定 start/stop。
  bool get _shouldAnimate {
    if (_program == null) return false;
    if (!settingsProvider.fluidBackground) return false;
    // ignore: deprecated_member_use
    return TickerMode.of(context);
  }

  SettingsProvider get settingsProvider =>
      context.read<SettingsProvider>();

  void _syncTicker() {
    if (_shouldAnimate && !_ticker.isActive) {
      // 重置帧增量基准：ticker 重新 start 后 elapsed 从 0 累计，
      // 若保留旧 _lastTickUs，首帧 delta 会算成负值，过渡 blend 回退。
      _lastTickUs = 0;
      _ticker.start();
    } else if (!_shouldAnimate && _ticker.isActive) {
      _ticker.stop();
    }
  }

  /// 律动开关变化：开→订阅 positionStream 推算节拍；关→取消订阅并清零脉冲。
  void _syncBeat() {
    final enabled =
        settingsProvider.fluidBeat && settingsProvider.fluidBackground;
    if (enabled == _beatEnabled) return;
    _beatEnabled = enabled;
    if (enabled) {
      _positionSub ??= context
          .read<PlayerProvider>()
          .positionStream
          .listen(_onPosition);
    } else {
      _positionSub?.cancel();
      _positionSub = null;
      _pulse.value = 0;
    }
  }

  /// 根据播放进度推算节拍相位 → 脉冲强度（0..1）。
  void _onPosition(Duration position) {
    // 每拍时长（BPM 120 → 500ms）。
    final beatMs = 60000 / _bpm;
    final phase = (position.inMilliseconds % beatMs) / beatMs; // 0..1
    // 每拍开始最强、指数衰减，模拟打击感。
    final raw = (1 - phase) * (1 - phase);
    // 攻快释慢的不对称平滑（避免突变，保留鼓点起伏）。
    final current = _pulse.value;
    final rate = raw > current ? _pulseAttack : _pulseDecay;
    _pulse.value = current + (raw - current) * rate;
  }

  /// 当前歌曲 key（`source_id`）；无歌曲返回 null。
  String? _currentSongKey() {
    final song = context.read<PlayerProvider>().currentSong;
    return song != null ? '${song.source}_${song.id}' : null;
  }

  /// 当前歌曲封面 url；无歌曲返回 null。
  String? _coverUrl() {
    final song = context.read<PlayerProvider>().currentSong;
    return song?.coverFor(300);
  }

  /// 切歌/封面色变化时防抖重新取色板。
  void _maybeRefreshPalette() {
    final key = _currentSongKey();
    if (key == _paletteSongKey) return;
    final isFirstLoad = _paletteSongKey == null;
    _paletteSongKey = key;
    _paletteDebounce?.cancel();
    // 测试环境跳过取色（避免 pending timer 与假封面网络请求）。
    if (_inTest) return;
    if (isFirstLoad) {
      // 首次进入立即取色（不等待防抖），尽快用真实封面色替换兜底色。
      _loadPalette();
    } else {
      // 切歌才防抖，避免连续切歌时的重复取色。
      _paletteDebounce = Timer(const Duration(milliseconds: 300), _loadPalette);
    }
  }

  /// 是否运行在 flutter test 环境（flutter test 总会设置 FLUTTER_TEST=true）。
  static bool get _inTest =>
      // ignore: avoid_web_libraries_in_flutter
      Platform.environment.containsKey('FLUTTER_TEST');

  Future<void> _loadPalette() async {
    final url = _coverUrl();
    final key = _currentSongKey();
    if (url == null) {
      // 无歌曲/封面：回退兜底色板。仅当状态变化且仍挂载时才重建。
      if (_palette == null) return;
      setState(() {
        _palette = null;
        _transitionStart = _displayPalette.value;
        _transitionEnd = _fallbackPalette;
        _paletteTransitionBlend = 0;
      });
      return;
    }
    final colors = await CoverColorExtractor.extractPalette(url, count: 6);
    if (!mounted) return;
    // 取色期间可能已切歌：仅当 key 仍一致才应用。
    if (_currentSongKey() != key) return;
    // 过亮封面（白/超浅色）压暗背景色板，保证白字可读；深色封面原样通过。
    final palette = colors == null
        ? const <Color>[]
        : colors.map(ReadableAccentResolver.darkenForBackground).toList();
    setState(() {
      _palette = palette;
      // 从当前显示色板渐入新色板（无过渡时 blend 已 =1，直接显示目标）。
      _transitionStart = _displayPalette.value;
      _transitionEnd =
          (palette.isNotEmpty) ? palette : _fallbackPalette;
      _paletteTransitionBlend = 0;
    });
  }

  /// 按索引逐色插值两个色板；长度不同时缺失槽位取对端该槽（平滑收尾）。
  List<Color> _lerpPalettes(List<Color> a, List<Color> b, double t) {
    final len = max(a.length, b.length);
    return List<Color>.generate(len, (i) {
      final ca = i < a.length ? a[i] : b[i];
      final cb = i < b.length ? b[i] : a[i];
      return Color.lerp(ca, cb, t)!;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void dispose() {
    _paletteDebounce?.cancel();
    _positionSub?.cancel();
    _ticker.dispose();
    _time.dispose();
    _pulse.dispose();
    _displayPalette.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    // watch player：切歌/currentSong 变化触发 rebuild，进而刷新色板。
    context.watch<PlayerProvider>();
    _maybeRefreshPalette();
    // 单一启停源：开关/前台/shader 就绪任一变化，这里都同步 ticker。
    _syncTicker();
    // 律动：开关变化时订阅/取消 positionStream。
    _syncBeat();

    final program = _program;

    if (!settings.fluidBackground) {
      return const SizedBox.shrink();
    }
    if (program == null) {
      // shader 尚未编译好：只能回退纯色背景。
      return Container(
        color: Theme.of(context).colorScheme.surface,
      );
    }

    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          willChange: true,
          painter: _FluidShaderPainter(
            program: program,
            palette: _displayPalette,
            time: _time,
            pulse: _pulse,
          ),
        ),
      ),
    );
  }
}

class _FluidShaderPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final ValueNotifier<List<Color>> palette;
  final ValueNotifier<double> time;
  final ValueNotifier<double> pulse;

  _FluidShaderPainter({
    required this.program,
    required this.palette,
    required this.time,
    required this.pulse,
  }) : super(repaint: Listenable.merge([palette, time, pulse]));

  /// 调优后的默认参数（原型滑杆确定的最佳观感）。
  /// 注意：deformSpeed / speed 不能太小，否则移动端动画近乎静止。
  static const double _speed = 1.5;
  static const double _noiseScale = 1.1;
  static const double _turbulence = 0.8;
  static const double _warping = 0.35;
  static const double _deformSpeed = 0.3;
  static const double _presence = 2.0;
  static const double _uniformity = 0.55;
  static const double _smoothness = 0.001;

  /// 音乐播放页惯例：无论系统深浅色，背景固定深色基调。
  static const double _darkness = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();

    shader.getUniformVec2('uResolution').set(size.width, size.height);
    shader.getUniformFloat('uTime').set(time.value);

    final palette = this.palette.value;
    final n = palette.length > FluidBackground.kMaxColors
        ? FluidBackground.kMaxColors
        : palette.length;
    shader.getUniformFloat('uColorCount').set(n.toDouble());
    for (var i = 0; i < FluidBackground.kMaxColors; i++) {
      // uColors 是 vec4[6] 数组：getUniformFloat(name, idx) 中 idx 是
      // "数组元素内浮点下标"，vec4 每元素占 4 个连续 float。
      final base = i * 4;
      if (i < n) {
        final c = palette[i];
        shader.getUniformFloat('uColors', base).set(c.r);
        shader.getUniformFloat('uColors', base + 1).set(c.g);
        shader.getUniformFloat('uColors', base + 2).set(c.b);
        shader.getUniformFloat('uColors', base + 3).set(1.0);
      } else {
        shader.getUniformFloat('uColors', base).set(0);
        shader.getUniformFloat('uColors', base + 1).set(0);
        shader.getUniformFloat('uColors', base + 2).set(0);
        shader.getUniformFloat('uColors', base + 3).set(0);
      }
    }

    final p = shader;
    p.getUniformFloat('uParams', 0).set(_speed);
    p.getUniformFloat('uParams', 1).set(_noiseScale);
    p.getUniformFloat('uParams', 2).set(_turbulence);
    p.getUniformFloat('uParams', 3).set(_warping);
    p.getUniformFloat('uParams', 4).set(_deformSpeed);
    p.getUniformFloat('uParams', 5).set(_presence);
    p.getUniformFloat('uParams', 6).set(_uniformity);
    p.getUniformFloat('uParams', 7).set(_smoothness);
    p.getUniformFloat('uParams', 8).set(_darkness);
    p.getUniformFloat('uParams', 9).set(pulse.value);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_FluidShaderPainter oldDelegate) =>
      oldDelegate.palette != palette ||
      oldDelegate.time != time ||
      oldDelegate.pulse != pulse;
}
