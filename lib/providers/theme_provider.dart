import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题 Provider：管理主题模式 + 种子色 + 自定义色，持久化到 SharedPreferences。
///
/// 在 ColorScheme.fromSeed 基础上统一覆盖 AppBar / Card / ListTile /
/// NavigationBar / Divider / IconButton 等组件主题，
/// 让全应用视觉一致、更贴近 MD3 规范。
class ThemeProvider extends ChangeNotifier {
  static const _kThemeMode = 'theme_mode'; // system / light / dark
  static const _kSeedColor = 'seed_color'; // ARGB int
  static const _kCustomColors = 'custom_colors'; // JSON list of int
  static const _kPredictiveBack = 'predictive_back';
  static const _kDynamicColor = 'theme_dynamic_color';

  ThemeMode _themeMode = ThemeMode.system;
  Color _seedColor = const Color(0xFF9C27B0);
  List<int> _customSeedColors = <int>[];
  bool _predictiveBack = true;
  bool _initialized = false;

  /// 动态取色开关：开启时主题种子跟随当前歌曲封面自动变化（默认开），
  /// 无封面/解析前回退到手动 [_seedColor]。
  bool _dynamicColor = true;

  /// 当前歌曲封面解析出的种子色；null = 未取到/关闭动态取色。
  Color? _coverSeedColor;

  // 缓存 light/dark 两套 ThemeData，避免每次 build 重算（主题扩散逐帧 build
  // 时省去 _buildTheme 的开销）。任一影响配色的字段变化时失效。
  ThemeData? _cachedLight;
  ThemeData? _cachedDark;

  void _invalidateThemes() {
    _cachedLight = null;
    _cachedDark = null;
  }

  ThemeMode get themeMode => _themeMode;
  Color get seedColor => _seedColor;
  int get seedColorValue => _seedColor.toARGB32();
  List<int> get customSeedColors => List.unmodifiable(_customSeedColors);
  bool get initialized => _initialized;

  /// 动态取色（跟随当前歌曲封面）开关。
  bool get dynamicColor => _dynamicColor;

  /// 当前封面解析出的种子色；null = 未取到。
  Color? get coverSeedColor => _coverSeedColor;

  /// 实际生效的种子色：动态开启且有封面色时用封面色，否则用手动色。
  Color get effectiveSeedColor =>
      _dynamicColor ? (_coverSeedColor ?? _seedColor) : _seedColor;

  /// 预测性返回（Predictive Back）开关，默认开。仅 Android + 系统支持时有效。
  bool get predictiveBack => _predictiveBack;

  /// 预设种子色（ARGB int）。
  static const seedColors = <int>[
    0xFF5B8DEF,
    0xFF006D40,
    0xFF7C5800,
    0xFF9C27B0,
    0xFFD81B60,
    0xFFD32F2F,
    0xFFE64A19,
    0xFF5D4037,
    0xFF455A64,
    0xFF00897B,
    0xFF43A047,
    0xFF3949AB,
  ];

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeIndex = prefs.getInt(_kThemeMode);
      if (modeIndex != null &&
          modeIndex >= 0 &&
          modeIndex < ThemeMode.values.length) {
        _themeMode = ThemeMode.values[modeIndex];
      }
      final colorValue = prefs.getInt(_kSeedColor);
      if (colorValue != null) {
        _seedColor = Color(colorValue);
      }
      final custom = prefs.getString(_kCustomColors);
      if (custom != null) {
        final list = jsonDecode(custom);
        if (list is List) {
          _customSeedColors = list.whereType<int>().toList();
        }
      }
      _predictiveBack = prefs.getBool(_kPredictiveBack) ?? true;
      _dynamicColor = prefs.getBool(_kDynamicColor) ?? true;
    } catch (_) {
      // 使用默认值
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  /// 强制从 SharedPreferences 重新载入（备份恢复后调用）。
  Future<void> reload() async {
    _initialized = false;
    await init();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _invalidateThemes();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kThemeMode, mode.index);
  }

  Future<void> setSeedColor(Color color) => setSeedColorValue(color.toARGB32());

  Future<void> setSeedColorValue(int argb) async {
    if (_seedColor.toARGB32() == argb) return;
    _seedColor = Color(argb);
    _invalidateThemes();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeedColor, argb);
  }

  Future<void> addCustomColor(int argb) async {
    if (_customSeedColors.contains(argb)) return;
    _customSeedColors = [..._customSeedColors, argb];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCustomColors, jsonEncode(_customSeedColors));
  }

  Future<void> removeCustomColor(int argb) async {
    if (!_customSeedColors.contains(argb)) return;
    _customSeedColors = _customSeedColors.where((c) => c != argb).toList();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCustomColors, jsonEncode(_customSeedColors));
  }

  Future<void> setPredictiveBack(bool v) async {
    if (_predictiveBack == v) return;
    _predictiveBack = v;
    _invalidateThemes();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPredictiveBack, v);
  }

  /// 切换动态取色（持久化）。关闭时清空封面色，回到手动种子。
  Future<void> setDynamicColor(bool v) async {
    if (_dynamicColor == v) return;
    _dynamicColor = v;
    if (!v) _coverSeedColor = null;
    _invalidateThemes();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDynamicColor, v);
  }

  /// 设置当前封面解析出的种子色（不持久化，切换歌曲后由 _CoverSeedWatcher 更新）。
  void setCoverSeedColor(Color? color) {
    if (_coverSeedColor == color) return;
    _coverSeedColor = color;
    _invalidateThemes();
    notifyListeners();
  }

  /// 平台字体：桌面端用各自系统 CJK 字体（同时含中英文字形），
  /// 确保中英文混排时字重一致，避免 Roboto 与系统 CJK 粗细不匹配；
  /// 移动端用默认（Android Roboto + Noto CJK，iOS/iPadOS 系统字体）。
  static String? get _platformFontFamily {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'Microsoft YaHei UI';
      case TargetPlatform.macOS:
        return 'PingFang SC';
      case TargetPlatform.linux:
        return 'Noto Sans CJK SC';
      default:
        return null;
    }
  }

  /// 预测性返回关闭时的路由过渡：仅 Android 换回旧 Zoom，其余平台保留默认。
  static const _legacyPageTransitionsTheme = PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      TargetPlatform.linux: ZoomPageTransitionsBuilder(),
    },
  );

  ThemeData _buildTheme(Brightness brightness) {
    final cs = ColorScheme.fromSeed(
      seedColor: effectiveSeedColor,
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      fontFamily: _platformFontFamily,
    );

    // 统一 TextTheme：MD3 Typography 规范为基础，
    // 标题层加粗并收紧字距，正文用 onSurface，辅助文字用 onSurfaceVariant。
    // 字体家族见 _platformFontFamily，桌面端中英文统一用同一字体避免粗细不一致。
    final t = base.textTheme;
    final textTheme = t.copyWith(
      headlineLarge: t.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: cs.onSurface,
      ),
      headlineMedium: t.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: cs.onSurface,
      ),
      headlineSmall: t.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: cs.onSurface,
      ),
      titleLarge: t.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: cs.onSurface,
      ),
      titleMedium: t.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      titleSmall: t.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      bodyLarge: t.bodyLarge?.copyWith(color: cs.onSurface),
      bodyMedium: t.bodyMedium?.copyWith(color: cs.onSurface),
      bodySmall: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      labelLarge: t.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      labelMedium: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
      labelSmall: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
    );

    return base.copyWith(
      textTheme: textTheme,
      // 开关开→沿用默认（Android 用 PredictiveBackPageTransitionsBuilder）；
      // 关→覆盖为 legacy map（Android 换 Zoom，预测性返回失效）。
      pageTransitionsTheme: _predictiveBack
          ? null
          : _legacyPageTransitionsTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // 标题使用 textTheme.titleLarge（w700 / -0.2 / onSurface）
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surfaceContainer,
        elevation: 0,
        height: 72,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? cs.onSurface : cs.onSurfaceVariant,
          );
        }),
      ),
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant.withValues(alpha: 0.5),
        space: 1,
        thickness: 1,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  // 缓存命中：仅在配色相关字段变化后由 _invalidateThemes 失效。
  ThemeData get lightTheme => _cachedLight ??= _buildTheme(Brightness.light);
  ThemeData get darkTheme => _cachedDark ??= _buildTheme(Brightness.dark);

  /// 按亮度取对应主题（与 MaterialApp 的 resolved theme 一致）。
  ThemeData themeFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkTheme : lightTheme;

  /// 解析某个 [mode] 在给定系统亮度下最终生效的亮度。
  ///
  /// system 模式跟随系统；light/dark 固定。供主题切换动画判断「亮度是否真的
  /// 变化」以及取目标主题使用。
  Brightness resolveBrightness(ThemeMode mode, Brightness platformBrightness) {
    switch (mode) {
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.system:
        return platformBrightness;
    }
  }
}
