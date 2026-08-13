import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/settings_provider.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/page_scroll_view.dart';

/// 网络与风控设置 section：IP 注入 + 系统代理开关。
///
/// 默认组合 = 直连 + 真实 IP + 不注入来源头，最贴官方客户端行为。
class NetworkSection extends StatelessWidget {
  const NetworkSection({super.key});

  static Widget builder(BuildContext context) => const NetworkSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sp = context.watch<SettingsProvider>();
    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          icon: Icons.security_rounded,
          title: '网络与风控',
          children: [
            if (!SettingsProvider.isAndroid)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('使用系统/环境代理'),
                subtitle: const Text(
                  'Dart 默认直连；仅当显式设置了 HTTP_PROXY/HTTPS_PROXY 环境变量时开启才会走代理。'
                  'FlClash 等工具的「系统代理」写的是系统级代理（dart 不读取），对本应用无影响',
                ),
                value: !sp.bypassSystemProxy,
                onChanged: (v) => sp.setBypassSystemProxy(!v),
              ),
            const Divider(height: 16),
            if (!SettingsProvider.isAndroid)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('注入国内 IP'),
                subtitle: const Text(
                  '给请求附加 X-Real-IP 与 X-Forwarded-For 头，会话内保持同一 IP。'
                  '海外用户启用可作地区伪装；默认关闭以贴近官方客户端行为',
                ),
                value: sp.realIpInjectionEnabled,
                onChanged: (v) => sp.setNeteaseRealIp(v),
              ),
            const SizedBox(height: 8),
            Text(
              '默认直连真实 IP、不注入来源头，仅在需要地区伪装时建议开启 IP 注入。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'TUN/VPN 模式会在网卡层接管流量，无法靠本应用绕过。'
              '若代理将音乐服务路由到境外节点，请在代理规则中将相关域名设为直连，'
              '避免「境内账号 + 境外出口 IP」触发风控。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
