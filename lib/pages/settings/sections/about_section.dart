import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_build_info.dart';
import '../../../constants/app_links.dart';
import '../../../core/contributor_service.dart';
import '../../../core/navigation/app_nav.dart';
import '../../../core/update_service.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/page_scroll_view.dart';
import '../../../widgets/update_dialog.dart';
import '../../../core/logging/app_log.dart';
import 'logs/log_list_page.dart';

/// 关于 section：应用信息 + 版本 + 开源协议 + 仓库 + 文档 + 检查更新。
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  static Widget builder(BuildContext context) => const AboutSection();

  @override
  Widget build(BuildContext context) {
    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── 关于 ──
        SectionCard(
          icon: Icons.info_outline_rounded,
          title: '关于',
          children: [
            _AboutRow(
              icon: Icons.music_note_rounded,
              title: 'FluxWave',
              subtitle: '聚合音乐播放器 · Flutter',
            ),
            const Divider(height: 24),
            const _VersionRow(),
            const Divider(height: 24),
            _LinkRow(
              icon: Icons.book_rounded,
              title: '开源协议',
              trailing: 'MIT',
              onTap: () => launchUrl(Uri.parse(AppLinks.kLicenseUrl)),
            ),
            const Divider(height: 24),
            _LinkRow(
              icon: Icons.code_rounded,
              title: '仓库地址',
              trailing: 'GitHub',
              onTap: () => launchUrl(Uri.parse(AppLinks.kGitHubRepoUrl)),
            ),
            const Divider(height: 24),
            _LinkRow(
              icon: Icons.description_outlined,
              title: '使用文档',
              trailing: 'Docs',
              onTap: () => launchUrl(Uri.parse(AppLinks.kDocsUrl)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── 更新 ──
        SectionCard(
          icon: Icons.system_update_rounded,
          title: '更新',
          children: [
            _UpdateTile(
              checkUpdateOnStart: context.select<SettingsProvider, bool>(
                (s) => s.checkUpdateOnStart,
              ),
              updateChannel: context.select<SettingsProvider, String>(
                (s) => s.updateChannel,
              ),
              onToggleAutoCheck: (v) =>
                  context.read<SettingsProvider>().setCheckUpdateOnStart(v),
              onChannelChanged: (v) =>
                  context.read<SettingsProvider>().setUpdateChannel(v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── 应用日志 ──
        SectionCard(
          icon: Icons.article_outlined,
          title: '应用日志',
          children: [
            Text(
              '查看或导出应用运行日志，用于问题反馈与排障。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('记录日志'),
              subtitle: const Text('关闭后不再写入新日志，已保存的日志仍可查看'),
              value: context.select<SettingsProvider, bool>(
                (s) => s.logEnabled,
              ),
              onChanged: (v) =>
                  context.read<SettingsProvider>().setLogEnabled(v),
            ),
            const SizedBox(height: 4),
            _LogEntryTile(
              icon: Icons.receipt_long_rounded,
              title: '运行日志',
              kind: LogSourceKind.runtime,
            ),
            const SizedBox(height: 8),
            _LogEntryTile(
              icon: Icons.bug_report_outlined,
              title: '崩溃日志',
              kind: LogSourceKind.crash,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── 贡献者 ──
        const _ContributorsSection(),
        const SizedBox(height: 8),
        // ── 致谢 ──
        SectionCard(
          icon: Icons.code_rounded,
          title: '致谢',
          children: [
            Text(
              '本项目灵感与实现参考自 SPlayer、SPlayer-Next 与 NeriPlayer，感谢社区贡献。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

/// 版本行：从 PackageInfo 动态读取，旁边附带 DEV 角标（仅 debug 构建）。
class _VersionRow extends StatefulWidget {
  const _VersionRow();

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = info.version);
    } catch (_) {
      // 测试/平台不可用时保持空，显示占位符
    }
  }

  @override
  Widget build(BuildContext context) {
    final badge = AppBuildInfo.badge;
    return _AboutRow(
      icon: Icons.tag_rounded,
      title: '版本',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _version.isEmpty ? '...' : _version,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badge,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LogEntryTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final LogSourceKind kind;
  const _LogEntryTile({
    required this.icon,
    required this.title,
    required this.kind,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => AppNav.push(context, LogListPage(kind: kind)),
    );
  }
}

/// 更新栏目：手动检查按钮 + 启动时自动检查开关 + 更新渠道选择。
class _UpdateTile extends StatefulWidget {
  final bool checkUpdateOnStart;
  final String updateChannel;
  final ValueChanged<bool> onToggleAutoCheck;
  final ValueChanged<String> onChannelChanged;

  const _UpdateTile({
    required this.checkUpdateOnStart,
    required this.updateChannel,
    required this.onToggleAutoCheck,
    required this.onChannelChanged,
  });

  @override
  State<_UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<_UpdateTile> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final settings = context.read<SettingsProvider>();
      final info = await UpdateService.instance.check(
        includeBeta: settings.updateIncludeBeta,
      );
      if (!mounted) return;
      if (info != null) {
        await UpdateDialog.show(context, info);
      } else {
        AppToast.show(context, '当前已是最新版本');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.system_update_rounded, color: cs.onSurfaceVariant),
          title: const Text('检查更新'),
          subtitle: Text(
            _checking ? '正在检查...' : '手动检查是否有新版本',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          trailing: _checking
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  Icons.chevron_right_rounded,
                  color: cs.onSurfaceVariant,
                ),
          onTap: _checking ? null : _check,
        ),
        const Divider(height: 1),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启动时自动检查'),
          subtitle: Text(
            '开启后每次启动自动检查新版本',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          value: widget.checkUpdateOnStart,
          onChanged: widget.onToggleAutoCheck,
        ),
        const Divider(height: 1),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('更新渠道'),
          subtitle: Text(
            widget.updateChannel == 'beta'
                ? '接收所有版本（含内测版）'
                : '仅接收正式版',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          trailing: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'stable',
                label: Text('正式版'),
              ),
              ButtonSegment(
                value: 'beta',
                label: Text('内测版'),
              ),
            ],
            selected: {widget.updateChannel},
            onSelectionChanged: (v) => widget.onChannelChanged(v.first),
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }
}

/// 开发者 section：从 GitHub API 动态拉取贡献者列表。
class _ContributorsSection extends StatefulWidget {
  const _ContributorsSection();

  @override
  State<_ContributorsSection> createState() => _ContributorsSectionState();
}

class _ContributorsSectionState extends State<_ContributorsSection> {
  List<Contributor>? _contributors;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    try {
      final contributors = await ContributorService.instance.getContributors(
        maxCount: 10,
      );
      if (!mounted) return;
      setState(() => _contributors = contributors);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return SectionCard(
      icon: Icons.people_rounded,
      title: '贡献者',
      children: [
        // 加载中
        if (_contributors == null && _error == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        // 错误
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: cs.error),
                const SizedBox(width: 8),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _load,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        // 贡献者列表
        if (_contributors != null) ...[
          if (_contributors!.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '暂无贡献者数据',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            )
          else
            ..._contributors!.map((c) => _ContributorTile(contributor: c)),
          // 查看完整列表
          if (_contributors!.isNotEmpty) ...[
            const Divider(height: 16),
            InkWell(
              onTap: () => launchUrl(
                Uri.parse(AppLinks.kContributorsPageUrl),
              ),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '查看完整贡献者列表',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'GitHub',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// 单个贡献者条目：头像 + 用户名 + 贡献数。
class _ContributorTile extends StatelessWidget {
  final Contributor contributor;

  const _ContributorTile({required this.contributor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return InkWell(
      onTap: () => launchUrl(Uri.parse(contributor.htmlUrl)),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            // 头像
            CircleAvatar(
              radius: 20,
              backgroundImage: NetworkImage(contributor.avatarUrl),
              backgroundColor: cs.surfaceContainerHighest,
            ),
            const SizedBox(width: 12),
            // 用户名 + 贡献数
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contributor.login,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '${contributor.contributions} commits',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 可点击的关于行：图标 + 标题 + trailing，点击触发 [onTap]。
class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? trailing;
  final VoidCallback? onTap;

  const _LinkRow({
    required this.icon,
    required this.title,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 22, color: cs.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (trailing != null) ...[
              Text(
                trailing!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              // ignore: use_null_aware_elements
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 18, color: cs.onSurfaceVariant),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// 不可点击的关于行：图标 + 标题 + 可选副标题 + trailing（Widget）。
class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const _AboutRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Icon(icon, size: 22, color: cs.onSurfaceVariant),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
