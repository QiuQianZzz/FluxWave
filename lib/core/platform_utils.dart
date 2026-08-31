import 'dart:io';

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

  /// 获取当前 Android 设备的 ABI。
  ///
  /// 通过读取 `/proc/self/maps` 的前几行判断 CPU 架构。
  /// 返回如 `arm64-v8a`、`armeabi-v7a`、`x86_64`、`x86`。
  /// 非 Android 或无法判断时返回 `arm64-v8a`（主流默认值）。
  static Future<String> getAndroidAbi() async {
    if (!isAndroid) return '';
    try {
      final result = await Process.run('getprop', ['ro.product.cpu.abi']);
      final abi = (result.stdout as String).trim();
      if (abi.isNotEmpty) return abi;
    } catch (_) {}
    try {
      final maps = await File('/proc/self/maps').readAsLines();
      if (maps.isNotEmpty) {
        final firstLine = maps.first;
        if (firstLine.contains('/arm64')) return 'arm64-v8a';
        if (firstLine.contains('/arm')) return 'armeabi-v7a';
        if (firstLine.contains('/x86_64')) return 'x86_64';
        if (firstLine.contains('/x86')) return 'x86';
      }
    } catch (_) {}
    return 'arm64-v8a';
  }
}
