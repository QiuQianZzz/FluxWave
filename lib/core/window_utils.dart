import 'package:flutter/material.dart';

/// 窗口布局工具类：检测小窗/自由窗口模式，提供自适应布局参数。
///
/// Android freeform/small window 模式下，窗口高度可能只有 300-400px，
/// 固定常量会挤占全部空间导致内容不可见。本工具类根据实际窗口尺寸
/// 动态调整布局参数。
///
/// 注意：Android小窗模式下MediaQuery.padding的异常问题已在main.dart的
/// _AndroidSmallWindowFix中全局修正，无需在此处处理。
class WindowUtils {
  WindowUtils._();

  /// 小窗模式高度阈值：低于此高度视为小窗模式。
  static const double _smallWindowHeightThreshold = 500.0;

  /// 紧凑模式高度阈值：低于此高度使用极度紧凑布局。
  static const double _compactHeightThreshold = 400.0;

  /// 是否为小窗模式（窗口高度 < 500px）。
  static bool isSmallWindow(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return height < _smallWindowHeightThreshold;
  }

  /// 是否为紧凑模式（窗口高度 < 400px）。
  static bool isCompactWindow(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return height < _compactHeightThreshold;
  }

  /// 获取自适应的悬浮导航高度。
  static double floatingNavHeight(BuildContext context) {
    if (isCompactWindow(context)) return 56.0;
    if (isSmallWindow(context)) return 68.0;
    return 80.0;
  }

  /// 获取自适应的迷你播放器占用高度。
  static double miniPlayerClearance(BuildContext context) {
    if (isCompactWindow(context)) return 64.0;
    if (isSmallWindow(context)) return 80.0;
    return 100.0;
  }

  /// 获取自适应的页面底部留白。
  static double pageBottomClearance(
    BuildContext context, {
    bool hasSong = false,
    bool keyboardOpen = false,
  }) {
    if (keyboardOpen) return 0.0;
    final mq = MediaQuery.of(context);
    final navH = floatingNavHeight(context);
    final playerH = hasSong ? miniPlayerClearance(context) : 0.0;
    return navH + mq.padding.bottom + 16 + playerH;
  }

  /// 获取自适应的播放页封面尺寸。
  static double playerCoverSize(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (isCompactWindow(context)) {
      return (w * 0.45).clamp(80.0, 140.0);
    }
    if (isSmallWindow(context)) {
      return (w * 0.5).clamp(100.0, 180.0);
    }
    return (w * 0.6).clamp(180.0, 280.0);
  }

  /// 获取自适应的 SliverAppBar 展开高度。
  static double sliverAppBarHeight(BuildContext context) {
    if (isCompactWindow(context)) return 80.0;
    if (isSmallWindow(context)) return 110.0;
    return 148.0;
  }

  /// 获取自适应的歌词面板最小高度。
  static double minLyricsHeight(BuildContext context) {
    if (isCompactWindow(context)) return 60.0;
    if (isSmallWindow(context)) return 80.0;
    return 100.0;
  }

  /// 获取自适应的控件区高度。
  static double controlsHeight(BuildContext context) {
    if (isCompactWindow(context)) return 100.0;
    if (isSmallWindow(context)) return 120.0;
    return 145.0;
  }
}
