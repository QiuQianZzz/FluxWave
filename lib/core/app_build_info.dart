import 'package:flutter/foundation.dart' show kDebugMode;

/// 构建类型标识的集中出口。
///
/// debug（含 Windows/Android 的 debug 构建）走 [isDebug]==true，release 恒为
/// false。`kDebugMode` 是编译期常量：release 构建里这些分支会被 DCE 剪掉，
/// 因此"Dev 标识"只存在于调试产物，不会泄漏进正式包。
class AppBuildInfo {
  AppBuildInfo._();

  /// 当前是否为 debug（开发）构建。
  static bool get isDebug => kDebugMode;

  /// 用于在 UI 角落/关于页展示的短标识；release 返回 null（无标识）。
  static String? get badge => kDebugMode ? 'DEV' : null;
}
