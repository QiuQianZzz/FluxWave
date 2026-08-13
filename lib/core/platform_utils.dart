import 'package:flutter/foundation.dart';

/// 平台判断工具类：统一管理所有平台相关的布尔判断。
///
/// 全部基于 [defaultTargetPlatform]（Flutter 风格），仅在必须使用 dart:io
/// 的场景（如 FFI 初始化）保留 `Platform.isXxx`。
class PlatformUtils {
  PlatformUtils._();

  /// 当前是否 Android。
  static bool get isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  /// 当前是否 iOS。
  static bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// 当前是否移动端（Android / iOS）。
  static bool get isMobile => isAndroid || isIOS;

  /// 当前是否桌面端（Windows / macOS / Linux）。
  static bool get isDesktop => isWindows || isMacOS || isLinux;

  /// 当前是否 Windows。
  static bool get isWindows =>
      defaultTargetPlatform == TargetPlatform.windows;

  /// 当前是否 macOS。
  static bool get isMacOS =>
      defaultTargetPlatform == TargetPlatform.macOS;

  /// 当前是否 Linux。
  static bool get isLinux =>
      defaultTargetPlatform == TargetPlatform.linux;
}
