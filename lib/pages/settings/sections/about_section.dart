import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../../core/app_build_info.dart';
import '../../../core/update_service.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/page_scroll_view.dart';
import '../../../widgets/update_dialog.dart';
import '../../../core/logging/app_log.dart';
import 'logs/log_list_page.dart';

/// 关于 section：应用信息 + 版本 + 开源协议 + 检查更新。
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  static Widget builder(BuildContext context) => const AboutSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
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
            // debug 构建：显示真实包名（Android debug 含 .debug 后缀）与
            // PackageInfo 版本号，release 构建该段不渲染。
            if (AppBuildInfo.isDebug) ...[
              const Divider(height: 24),
              const _DebugBuildRow(),
            ],
            const Divider(height: 24),
            _AboutRow(icon: Icons.book_rounded, title: '开源协议', trailing: 'MIT'),
          ],
        ),
        const SizedBox(height: 8),
        SectionCard(
          icon: Icons.article_outlined,
          title: '应用日志',
          children: [
            Text(
              '查看或导出应用运行日志，用于问题反馈与排障。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
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
        SectionCard(
          icon: Icons.system_update_rounded,
          title: '更新',
          children: [
            Text(
              '检查是否有新版本可用。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            const _UpdateButton(),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启动时检查更新'),
              subtitle: const Text('开启后每次启动自动检查新版本'),
              value: context.select<SettingsProvider, bool>(
                (s) => s.checkUpdateOnStart,
              ),
              onChanged: (v) =>
                  context.read<SettingsProvider>().setCheckUpdateOnStart(v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SectionCard(
          icon: Icons.code_rounded,
          title: '致谢',
          children: [
            Text(
              '本项目灵感与实现参考自 SPlayer、SPlayer-Next 与 NeriPlayer，感谢社区贡献。',
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

/// 版本行：从 PackageInfo 动态读取，pubspec.yaml 为唯一版本来源。
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
    return _AboutRow(
      icon: Icons.tag_rounded,
      title: '版本',
      trailing: _version.isEmpty ? '...' : _version,
    );
  }
}

/// 仅 debug 构建渲染：展示真实包名 + PackageInfo 版本号，作为调试包标识。
class _DebugBuildRow extends StatefulWidget {
  const _DebugBuildRow();

  @override
  State<_DebugBuildRow> createState() => _DebugBuildRowState();
}

class _DebugBuildRowState extends State<_DebugBuildRow> {
  String _package = '';
  String _version = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String package = '';
    String version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      package = info.packageName;
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // 平台/测试环境拿不到包信息时保持占位文本，不影响页面。
    }
    if (!mounted) return;
    setState(() {
      _package = package;
      _version = version;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _AboutRow(
      icon: Icons.terminal_rounded,
      title: 'Debug 构建',
      subtitle: _package.isEmpty ? '开发版（包信息不可用）' : _package,
      trailing: _version.isEmpty ? 'DEV' : _version,
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
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => LogListPage(kind: kind))),
    );
  }
}

/// 检查更新按钮：调用 GitHub API 检测新版本，有更新弹窗展示，无更新提示。
class _UpdateButton extends StatefulWidget {
  const _UpdateButton();

  @override
  State<_UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<_UpdateButton> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await UpdateService.instance.check();
      if (!mounted) return;
      if (info != null) {
        await UpdateDialog.show(context, info);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('当前已是最新版本'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: _checking ? null : _check,
      icon: _checking
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh_rounded, size: 18),
      label: Text(_checking ? '检查中...' : '检查更新'),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;
  const _AboutRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
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
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
