import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_icon.dart';
import '../core/audio_cache/cache_store.dart';
import '../core/logging/app_log.dart';
import '../core/lyric/line_lyric_reveal_mode.dart';
import '../core/netease/netease_config.dart';

/// 应用级设置 Provider（仿 ThemeProvider）：持久化网络/风控开关，
/// 并同步写入 [NeteaseConfig] 供纯 Dart 请求层读取。
///
/// 初始化顺序很关键：必须先于任何网络请求（含 NeteaseProvider 的 registerAnon）
/// 完成 init，见 main.dart（runApp 前 await settings.init()）。
class SettingsProvider extends ChangeNotifier {
  static const _kRealIp = 'netease_real_ip';
  static const _kBypassProxy = 'bypass_system_proxy';
  static const _kHapticFeedback = 'haptic_feedback';
  static const _kQuality = 'playback_quality';
  static const _kWindowsVolumePercent = 'windows_volume_percent';
  static const _kLauncherIconId = 'launcher_icon_id';
  static const _kAutoPlayOnOpen = 'auto_play_on_open';
  static const _kLogEnabled = 'log_enabled';
  static const _kCacheMaxMB = 'audio_cache_max_mb';
  static const _kLineLyricRevealMode = 'line_lyric_reveal_mode';
  static const _kLyricDepthBlur = 'lyric_depth_blur';
  static const _kGlassBlur = 'glass_blur';
  static const _kCheckUpdateOnStart = 'check_update_on_start';

  /// 音质档位表（值 = 网易云 song/url v1 的 level 参数，label = 展示名）。
  /// 标准→较高→...→超清母带。
  static const qualityOptions = <(String, String)>[
    ('standard', '标准'),
    ('higher', '较高'),
    ('exhigh', '极高'),
    ('lossless', '无损'),
    ('hires', 'Hi-Res'),
    ('jyeffect', '高清环绕声'),
    ('sky', '沉浸环绕声'),
    ('jymaster', '超清母带'),
  ];

  /// 默认音质档：standard 最兼容（全端可解码 + 拿完整版概率最高）。
  static const defaultQuality = 'standard';

  /// Windows 音量（界面百分比 0~100）默认值。实际写入 just_audio 的音量按
  /// `percent/100 * 0.5` 映射（0~0.5）：媒体音量给到过大数值可能让某些耳机端
  /// （2.4G/蓝牙 DAC 增益高）过响，0.5 为实测较合适的上限。
  static const defaultWindowsVolumePercent = 60.0;

  /// Windows 实际音量的上限（0~1），界面 100% 映射到该值。
  static const windowsVolumeCap = 0.5;

  /// 音频缓存上限（MB，MiB 语义）默认值：3072 MiB = 3 GiB 整，
  /// 单一真源在 [AudioCacheStore.defaultCacheMaxMB]，此处引用避免两处漂移。
  static const int defaultCacheMaxMB = AudioCacheStore.defaultCacheMaxMB;

  /// 音频缓存上限（MB）可调范围。
  static const cacheMaxMBMin = 128;
  static const cacheMaxMBMax = 8192;

  bool _neteaseRealIp = false;
  bool _bypassSystemProxy = true;
  bool _hapticFeedback = true;
  String _qualityLevel = defaultQuality;
  double _windowsVolumePercent = defaultWindowsVolumePercent;
  String _launcherIconId = appIconOptions.first.id;
  bool _autoPlayOnOpen = false;
  bool _initialized = false;

  bool _logEnabled = true;

  int _cacheMaxMB = defaultCacheMaxMB;

  /// 行级歌词（LRC）揭示方式。默认纯静态（整行固定 active 色、无渐变），
  /// 与用户最新要求一致；可在设置页切回"线性扫过"。
  LineLyricRevealMode _lineLyricRevealMode = LineLyricRevealMode.staticLine;

  /// 歌词景深模糊开关。默认开（部分人不喜欢该效果，可在设置页关闭）。
  bool _lyricDepthBlur = true;

  /// 全局界面毛玻璃开关（导航栏 / 侧边栏 / 迷你播放器等）。默认开。
  bool _glassBlur = true;

  /// 启动时检查更新（默认开）。
  bool _checkUpdateOnStart = true;

  bool get initialized => _initialized;

  /// 触感反馈开关（tab 切换等交互触发震动），默认开。
  bool get hapticFeedback => _hapticFeedback;

  /// 播放首选音质（首选档）；降级兜底固定 `standard` 见 PlayerProvider。
  String get qualityLevel => _qualityLevel;

  /// Windows 音量百分比（0~100），供设置页滑杆展示与调节。
  double get windowsVolumePercent => _windowsVolumePercent;

  /// Windows 实际音量（0~[_windowsVolumeCap]），PlayerProvider 据此 setVolume。
  double get windowsVolume => _windowsVolumePercent / 100 * windowsVolumeCap;

  /// 桌面图标 id（见 [AppIconOption]），持久化；仅 Android 运行时切换，
  /// Windows 等平台固定默认（= [appIconOptions] 首项）。
  String get launcherIconId => _launcherIconId;

  /// 打开应用时自动播放：纯开关语义（不依存退出时的播放状态）。
  /// 开启 → 启动恢复队列后自动开始播放；关闭 → 打开后始终处于暂停态。
  bool get autoPlayOnOpen => _autoPlayOnOpen;

  /// 日志落盘总开关（默认开启）。关闭后不再写新日志，历史文件仍可查。
  bool get logEnabled => _logEnabled;

  /// 音频缓存上限（MB）：设置页滑块调节，persist；经 [setCacheMaxMB] 同步
  /// 到 [AudioCacheStore]（运行时即时生效，改小立即驱逐）。
  int get cacheMaxMB => _cacheMaxMB;

  /// 行级歌词（LRC）揭示方式（仅影响 LRC；逐字 YRC 恒走逐字动画）。
  LineLyricRevealMode get lineLyricRevealMode => _lineLyricRevealMode;

  /// 歌词景深模糊开关：开启时按"距当前行的归一化距离"曲线计算模糊，靠近
  /// 当前行几乎清晰、往可视区顶部/底部边缘渐强；滑动/自动滚动期间自动解除。
  bool get lyricDepthBlur => _lyricDepthBlur;

  /// 全局界面毛玻璃开关（导航栏 / 侧边栏 / 迷你播放器等）。
  bool get glassBlur => _glassBlur;

  /// 启动时检查更新。
  bool get checkUpdateOnStart => _checkUpdateOnStart;

  /// 生效的 IP 注入开关：Android 硬门控（永不自动注入）。
  /// 显式 [NeteaseRequestContext.realIp] 仍恒生效（开发者/调试意图，不受此门控）。
  bool get realIpInjectionEnabled => _neteaseRealIp && !isAndroid;

  /// 是否绕过系统/环境代理（默认 true=直连）。
  bool get bypassSystemProxy => _bypassSystemProxy;

  /// 当前是否 Android（IP 注入硬门控）。
  static bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// 从 SharedPreferences 恢复设置并写入 [NeteaseConfig]。
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _neteaseRealIp = prefs.getBool(_kRealIp) ?? false;
      _bypassSystemProxy = prefs.getBool(_kBypassProxy) ?? true;
      _hapticFeedback = prefs.getBool(_kHapticFeedback) ?? true;
      _qualityLevel = prefs.getString(_kQuality) ?? defaultQuality;
      _windowsVolumePercent =
          (prefs.getDouble(_kWindowsVolumePercent) ??
                  defaultWindowsVolumePercent)
              .clamp(0.0, 100.0)
              .toDouble();
      _launcherIconId = _resolveIconId(prefs.getString(_kLauncherIconId));
      _autoPlayOnOpen = prefs.getBool(_kAutoPlayOnOpen) ?? false;
      _logEnabled = prefs.getBool(_kLogEnabled) ?? true;
      _cacheMaxMB = (prefs.getInt(_kCacheMaxMB) ?? defaultCacheMaxMB).clamp(
        cacheMaxMBMin,
        cacheMaxMBMax,
      );
      _lineLyricRevealMode = _resolveLineLyricRevealMode(
        prefs.getString(_kLineLyricRevealMode),
      );
      _lyricDepthBlur = prefs.getBool(_kLyricDepthBlur) ?? true;
      _glassBlur = prefs.getBool(_kGlassBlur) ?? true;
      _checkUpdateOnStart = prefs.getBool(_kCheckUpdateOnStart) ?? true;
    } catch (_) {
      // 读取失败使用默认值
    }
    _apply();
    // 把持久化的缓存上限同步到 store（在 AudioCache.init 之前/之后均可：store
    // 未初始化时仅记录字段，待 init 生效；此处保证上限在首次播放前就已就位）。
    AudioCacheStore.instance.setMaxBytes(_cacheMaxMB * 1024 * 1024);
    _initialized = true;
    notifyListeners();
  }

  void _apply() {
    NeteaseConfig.enableRealIpInjection = realIpInjectionEnabled;
    NeteaseConfig.bypassSystemProxy = _bypassSystemProxy;
  }

  Future<void> setNeteaseRealIp(bool v) async {
    _neteaseRealIp = v;
    _apply();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRealIp, v);
  }

  Future<void> setBypassSystemProxy(bool v) async {
    _bypassSystemProxy = v;
    _apply();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBypassProxy, v);
  }

  Future<void> setHapticFeedback(bool v) async {
    _hapticFeedback = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHapticFeedback, v);
  }

  /// 切换播放音质（持久化）；下一次播放生效。
  Future<void> setQualityLevel(String v) async {
    if (v == _qualityLevel) return;
    _qualityLevel = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQuality, v);
  }

  /// 设置 Windows 音量百分比（0~100，持久化）。仅改设置值，实际生效由
  /// PlayerProvider.syncWindowsVolume() 在调用方即时重施加。
  Future<void> setWindowsVolumePercent(double v) async {
    final clamped = v.clamp(0.0, 100.0).toDouble();
    if (clamped == _windowsVolumePercent) return;
    _windowsVolumePercent = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kWindowsVolumePercent, clamped);
  }

  /// 设置音频缓存上限（MB，clamp 到 [cacheMaxMBMin]~[cacheMaxMBMax]，持久化）。
  /// 同步到 [AudioCacheStore]：改小立即按新上限驱逐腾空间，改大仅放宽。
  Future<void> setCacheMaxMB(int mb) async {
    final clamped = mb.clamp(cacheMaxMBMin, cacheMaxMBMax);
    if (clamped == _cacheMaxMB) return;
    _cacheMaxMB = clamped;
    notifyListeners();
    AudioCacheStore.instance.setMaxBytes(clamped * 1024 * 1024);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCacheMaxMB, clamped);
  }

  /// 切换行级歌词（LRC）揭示方式（持久化）。仅影响 LRC；逐字 YRC 不受影响。
  Future<void> setLineLyricRevealMode(LineLyricRevealMode v) async {
    if (v == _lineLyricRevealMode) return;
    _lineLyricRevealMode = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLineLyricRevealMode, v.name);
  }

  /// 把任意字符串解析为合法的揭示方式；未知值回退到纯静态（默认）。
  LineLyricRevealMode _resolveLineLyricRevealMode(String? v) {
    if (v == null) return LineLyricRevealMode.staticLine;
    for (final mode in LineLyricRevealMode.values) {
      if (mode.name == v) return mode;
    }
    return LineLyricRevealMode.staticLine;
  }

  /// 切换歌词景深模糊开关（持久化）。立即作用于歌词页。
  Future<void> setLyricDepthBlur(bool v) async {
    if (v == _lyricDepthBlur) return;
    _lyricDepthBlur = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLyricDepthBlur, v);
  }

  /// 切换全局界面毛玻璃开关（持久化）。立即作用于导航栏 / 侧边栏 / 迷你播放器等。
  Future<void> setGlassBlur(bool v) async {
    if (v == _glassBlur) return;
    _glassBlur = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGlassBlur, v);
  }

  /// 切换启动时检查更新（持久化）。
  Future<void> setCheckUpdateOnStart(bool v) async {
    if (v == _checkUpdateOnStart) return;
    _checkUpdateOnStart = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCheckUpdateOnStart, v);
  }

  /// 桌面图标 id（持久化）。仅记录用户选择；实际调用 LauncherIconSwitcher
  /// 由设置页触发（非 Android 平台无副作用）。非法 id 忽略。
  Future<void> setLauncherIconId(String id) async {
    if (id == _launcherIconId) return;
    final resolved = _resolveIconId(id);
    if (resolved != id) return; // 不在可选列表内，忽略
    _launcherIconId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLauncherIconId, id);
  }

  /// 打开时自动播放（持久化）。纯开关语义：打开应用是否自动播放
  /// 仅由该选项决定，与用户退出时的播放状态无关。
  Future<void> setAutoPlayOnOpen(bool v) async {
    if (v == _autoPlayOnOpen) return;
    _autoPlayOnOpen = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoPlayOnOpen, v);
  }

  /// 切换日志落盘开关（持久化 + 同步 AppLog.userEnabled）。
  Future<void> setLogEnabled(bool v) async {
    if (v == _logEnabled) return;
    _logEnabled = v;
    AppLog.setUserEnabled(v);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLogEnabled, v);
  }

  /// 把任意字符串解析为合法图标 id；未知值回退到默认图标。
  String _resolveIconId(String? id) {
    if (id == null) return appIconOptions.first.id;
    return appIconOptions.any((o) => o.id == id) ? id : appIconOptions.first.id;
  }
}
