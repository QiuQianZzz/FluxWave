import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_service.dart';

/// 更新弹窗：展示版本对比 + Markdown 渲染的更新日志 + 跳转 GitHub Releases。
///
/// 宽屏居中限宽 480，窄屏自适应全宽；版本标签行溢出时自动换行。
class UpdateDialog extends StatelessWidget {
  final UpdateInfo info;

  const UpdateDialog({super.key, required this.info});

  static Future<void> show(BuildContext context, UpdateInfo info) {
    return showDialog(
      context: context,
      builder: (_) => UpdateDialog(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogWidth = screenWidth < 480 ? screenWidth - 32 : 480.0;

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: dialogWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Text('发现新版本', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              // 版本对比（窄屏自动换行）
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _VersionTag(version: info.currentVersion, cs: cs),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                  _VersionTag(
                    version: info.latestVersion,
                    cs: cs,
                    filled: true,
                  ),
                  if (info.isPrerelease)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '测试版',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onErrorContainer,
                        ),
                      ),
                    ),
                ],
              ),
              // 预发布警告
              if (info.isPrerelease) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: cs.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '当前更新为测试版本，可能包含未完成的功能或已知问题，请谨慎更新',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // 发布时间
              if (info.publishedAt != null) ...[
                const SizedBox(height: 8),
                Text(
                  '发布时间：${info.publishedAt!.substring(0, 10)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // 更新日志（可滚动，限高 400）
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 400),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: info.releaseNotes != null &&
                            info.releaseNotes!.trim().isNotEmpty
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.all(12),
                            child: MarkdownBody(
                              data: info.releaseNotes!,
                              selectable: true,
                              styleSheet:
                                  MarkdownStyleSheet.fromTheme(theme).copyWith(
                                p: theme.textTheme.bodyMedium,
                                code: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                  backgroundColor: cs.surfaceContainerHighest,
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              onTapLink: (text, href, title) {
                                if (href != null) launchUrl(Uri.parse(href));
                              },
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.all(12),
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
              const SizedBox(height: 16),
              // 按钮（窄屏自动换行）
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('稍后再说'),
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        launchUrl(Uri.parse(info.releaseUrl));
                        Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('前往 GitHub'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VersionTag extends StatelessWidget {
  final String version;
  final ColorScheme cs;
  final bool filled;

  const _VersionTag({
    required this.version,
    required this.cs,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    if (filled) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'v$version',
          style: style?.copyWith(color: cs.onPrimary),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outline),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'v$version',
        style: style?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }
}
