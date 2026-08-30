import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_service.dart';
import '../core/logging/app_log.dart';

/// 更新弹窗：展示版本对比 + Markdown 渲染的更新日志 + 下载安装。
///
/// 宽屏居中限宽 480，窄屏自适应全宽；版本标签行溢出时自动换行。
class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;

  const UpdateDialog({super.key, required this.info});

  static Future<void> show(BuildContext context, UpdateInfo info) {
    return showDialog(
      context: context,
      builder: (_) => UpdateDialog(info: info),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  double? _progress;
  bool _downloading = false;
  String? _error;
  bool _apkExists = false;

  bool get _hasDownload => widget.info.hasDownload;

  @override
  void initState() {
    super.initState();
    _checkExistingApk();
  }

  Future<void> _checkExistingApk() async {
    final exists = await UpdateService.instance.hasDownloadedApk(
      widget.info.latestVersion,
    );
    if (mounted) setState(() => _apkExists = exists);
  }

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = _apkExists ? 1.0 : 0;
      _error = null;
    });

    try {
      final filePath = await UpdateService.instance.downloadApk(
        widget.info.downloadUrl!,
        version: widget.info.latestVersion,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );

      if (!mounted) return;
      setState(() => _progress = 1.0);

      // 短暂显示完成状态后打开安装界面
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      final result = await OpenFile.open(filePath);
      if (result.type != ResultType.done) {
        AppLog.warn('打开 APK 失败', tag: 'update', error: result.message);
        if (mounted) {
          setState(() => _error = '无法打开安装文件：${result.message}');
        }
        return;
      }

      // 成功打开安装界面，关闭弹窗
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      AppLog.warn('下载失败', tag: 'update', error: e, stack: st);
      if (mounted) {
        setState(() => _error = '下载失败：$e');
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogWidth = screenWidth < 480 ? screenWidth - 32 : 480.0;
    final info = widget.info;

    return Dialog(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: dialogWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 顶部装饰区 ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    cs.primaryContainer,
                    cs.primaryContainer.withValues(alpha: 0.6),
                  ],
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 图标 + 标题
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.system_update_rounded,
                          size: 24,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '发现新版本',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                            if (info.publishedAt != null)
                              Text(
                                info.publishedAt!.substring(0, 10),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onPrimaryContainer.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (info.isPrerelease)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: cs.error,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '测试版',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onError,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 版本对比
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _VersionChip(
                        version: info.currentVersion,
                        cs: cs,
                        style: theme.textTheme.labelLarge,
                      ),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 20,
                        color: cs.onPrimaryContainer.withValues(alpha: 0.5),
                      ),
                      _VersionChip(
                        version: info.latestVersion,
                        cs: cs,
                        filled: true,
                        style: theme.textTheme.labelLarge,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // ── 内容区 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 预发布警告
                  if (info.isPrerelease) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 20,
                            color: cs.error,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '测试版本，可能包含未完成的功能，请谨慎更新',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // 下载进度
                  if (_downloading) ...[
                    _buildDownloadProgress(theme, cs),
                    const SizedBox(height: 12),
                  ],
                  // 错误提示
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, size: 20, color: cs.error),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _error!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // 更新日志标题
                  if (!_downloading) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 16,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '更新日志',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 更新日志内容
                    Container(
                      constraints: const BoxConstraints(maxHeight: 320),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: info.releaseNotes != null &&
                                info.releaseNotes!.trim().isNotEmpty
                            ? SingleChildScrollView(
                                padding: const EdgeInsets.all(14),
                                child: MarkdownBody(
                                  data: info.releaseNotes!,
                                  selectable: true,
                                  styleSheet: _buildMarkdownStyle(theme, cs),
                                  onTapLink: (text, href, title) {
                                    if (href != null) {
                                      launchUrl(Uri.parse(href));
                                    }
                                  },
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 24,
                                ),
                                child: Center(
                                  child: Text(
                                    '暂无更新日志',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // ── 底部按钮 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _downloading
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('稍后再说'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _downloading
                          ? null
                          : (_hasDownload
                              ? _downloadAndInstall
                              : () {
                                  launchUrl(Uri.parse(info.releaseUrl));
                                  Navigator.of(context).pop();
                                }),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: Icon(
                        _hasDownload
                            ? (_apkExists
                                ? Icons.install_mobile_rounded
                                : Icons.download_rounded)
                            : Icons.open_in_new_rounded,
                        size: 18,
                      ),
                      label: Text(
                        _hasDownload
                            ? (_apkExists ? '安装' : '下载并安装')
                            : '前往 GitHub',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgress(ThemeData theme, ColorScheme cs) {
    final percent = _progress != null ? (_progress! * 100).toStringAsFixed(0) : '0';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.downloading_rounded, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              '正在下载 APK… $percent%',
              style: theme.textTheme.labelLarge?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 6,
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  /// 构建 Markdown 样式。
  MarkdownStyleSheet _buildMarkdownStyle(ThemeData theme, ColorScheme cs) {
    final base = MarkdownStyleSheet.fromTheme(theme);
    return base.copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
      h1: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      h2: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      h3: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      code: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        backgroundColor: cs.surfaceContainerHighest,
        fontSize: 12,
      ),
      codeblockDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: cs.primary.withValues(alpha: 0.5),
            width: 3,
          ),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12),
      listBullet: theme.textTheme.bodyMedium?.copyWith(
        color: cs.primary,
      ),
    );
  }
}

/// 版本号标签。
class _VersionChip extends StatelessWidget {
  final String version;
  final ColorScheme cs;
  final bool filled;
  final TextStyle? style;

  const _VersionChip({
    required this.version,
    required this.cs,
    this.filled = false,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    if (filled) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'v$version',
          style: style?.copyWith(
            color: cs.onPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.onPrimaryContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'v$version',
        style: style?.copyWith(
          color: cs.onPrimaryContainer,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
