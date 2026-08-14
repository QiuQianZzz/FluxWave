import 'package:flutter/services.dart';

import 'platform_utils.dart';

/// 后台播放期间保持 WiFi 射频活性的电源锁（仅 Android）。
///
/// 系统息屏/省电时可能关闭 WiFi 网卡电源，导致后台播放取歌地址 DNS 解析失败
/// （`errno=7`）。播放期间持锁能显著降低此类后台断网概率，作为代码层
/// 「退避重试 + 自愈续播」之外的系统层兜底。
///
/// 非 Android 平台一律空操作。原生侧采用引用计数 acquire/release，调用顺序
/// 抖动不会导致锁提前释放。持锁失败（ROM 限制等）不影响播放。
class WifiLock {
  static const _channel = MethodChannel('fluxwave/wifi_lock');

  /// 当前是否持有 WiFi 锁（Android 实时查询；其它平台恒 false）。
  static Future<bool> isHeld() async {
    if (!PlatformUtils.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isHeld') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 持锁：通知原生侧 acquire 一次 WiFi 锁。
  /// 非 Android 平台直接返回。
  static Future<void> acquire() => _invoke('acquire');

  /// 释放：通知原生侧 release 一次 WiFi 锁（引用计数归零才真正释放）。
  /// 非 Android 平台直接返回。
  static Future<void> release() => _invoke('release');

  static Future<void> _invoke(String method) async {
    if (!PlatformUtils.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (_) {
      // 未注册 channel 的环境（模拟器/测试）忽略，不影响播放。
    }
  }
}