import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/navigation/app_nav.dart';
import '../../../providers/daily_provider.dart';
import '../../../providers/netease_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/radar_provider.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/page_scroll_view.dart';

/// 账号设置 section：登录状态展示 + 登录/登出。
///
/// 布局说明：不限制内容宽度（与其它设置 section 保持一致）。
/// 操作按钮按内容自适应宽度，仅窄屏时才自动换行，避免宽屏下
/// 两个按钮被 Expanded 拉成占满整个窗口的两等分长条。
class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  static Widget builder(BuildContext context) => const AccountSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final provider = context.watch<NeteaseProvider>();

    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          icon: Icons.person_outline_rounded,
          title: '在线音乐账号',
          children: [
            if (provider.isLoggedIn) ...[
              Row(
                children: [
                  if (provider.avatarUrl != null)
                    CircleAvatar(
                      backgroundImage: NetworkImage(provider.avatarUrl!),
                      radius: 24,
                    )
                  else
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: cs.primaryContainer,
                      child: Icon(
                        Icons.person_rounded,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          provider.nickname ?? '用户',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '已登录',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      provider.logout();
                      // 清除已登录用户的歌单/雷达/每日推荐缓存，避免登出后展示残留数据
                      // 或换账号登录时复用上个账号的每日推荐。
                      context.read<PlaylistProvider>().clear();
                      context.read<RadarProvider>().clear();
                      context.read<DailyProvider>().clear();
                    },
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('退出登录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: provider.refreshing
                        ? null
                        : () => provider.refreshUser(),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('刷新'),
                  ),
                ],
              ),
            ] else ...[
              Text(
                '未登录在线音乐账号，扫码登录后可同步歌单与每日推荐。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => AppNav.pushNamedGlobal(context, '/login/qr'),
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: const Text('二维码登录'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
