import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform_utils.dart';

/// 通知权限申请工具。
///
/// Android 13+ (API 33) 需要运行时申请 POST_NOTIFICATIONS 权限。
/// 本工具通过 MethodChannel 调用原生代码申请权限。
class NotificationPermission {
  static const _channel = MethodChannel('com.qiuqianzzz.fluxwave/permissions');

  /// 检查并申请通知权限。
  ///
  /// 仅 Android 13+ 需要申请；其他平台直接返回 true。
  /// 返回 true 表示权限已授予，false 表示未授予。
  static Future<bool> requestIfNeeded() async {
    if (!PlatformUtils.isAndroid) return true;

    try {
      final result = await _channel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      debugPrint('[Permission] 通知权限申请结果: $result');
      return result ?? false;
    } catch (e) {
      debugPrint('[Permission] 通知权限申请失败: $e');
      return false;
    }
  }

  /// 检查通知权限是否已授予。
  static Future<bool> isGranted() async {
    if (!PlatformUtils.isAndroid) return true;

    try {
      final result = await _channel.invokeMethod<bool>(
        'checkNotificationPermission',
      );
      return result ?? false;
    } catch (e) {
      debugPrint('[Permission] 检查通知权限失败: $e');
      return false;
    }
  }

  /// 跳转到系统通知设置页面。
  ///
  /// 用于用户已拒绝权限且系统不再弹出申请时，引导用户手动开启。
  static Future<bool> openSettings() async {
    if (!PlatformUtils.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>(
        'openNotificationSettings',
      );
      return result ?? false;
    } catch (e) {
      debugPrint('[Permission] 跳转通知设置失败: $e');
      return false;
    }
  }
}
