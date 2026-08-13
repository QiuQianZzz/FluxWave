import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Android 桌面图标运行时切换（id 驱动，支持任意多个图标）。
///
/// 通过 [MethodChannel] 调 MainActivity，按 id 启用对应的 activity-alias 并禁用
/// 其余全部，即时生效且持久（无需重启）。可选图标定义见 `app_icon.dart`。
/// Windows 等平台不支持运行时换图标，本类一律空操作，固定使用默认图标。
class LauncherIconSwitcher {
  static const _channel = MethodChannel('fluxwave/launcher_icon');

  /// 切换桌面图标为 [id] 对应的那一个（如 'default'、'alt'）。
  /// 非 Android 平台直接返回（仅默认图标生效）。
  static Future<void> setIcon(String id) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setLauncherIcon', id);
    } catch (_) {
      // 未注册 channel 的环境（模拟器/测试）忽略，不影响应用。
    }
  }
}
