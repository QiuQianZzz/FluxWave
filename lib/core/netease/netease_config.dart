library;

/// 网络层运行时配置（纯 Dart，供 request/registerAnon 等请求层读取）。
///
/// 由 [SettingsProvider] 在启动时写入；默认值即"最像官方客户端"的保守组合：
/// 直连真实 IP、不伪造任何来源 IP 头。
class NeteaseConfig {
  /// 自动注入会话级国内 IP，默认关。
  ///
  /// 共识：官方客户端直连从不携带 `X-Real-IP/X-Forwarded-For`（这两个头是
  /// 代理/CDN 加的），默认不注入最贴官方；Android 由 SettingsProvider 硬门控
  /// 恒为 false。显式 [NeteaseRequestContext.realIp] 始终优先（开发者/调试意图）。
  static bool enableRealIpInjection = false;

  /// 绕过系统/环境代理，默认开=直连。
  ///
  /// 直连可避免 Clash 等代理把出口 IP 换成境外节点引发风控；注意 TUN/VpnService
  /// 属网络层接管，此开关无法生效（需用户让网易云走直连或大陆节点）。
  static bool bypassSystemProxy = true;
}
