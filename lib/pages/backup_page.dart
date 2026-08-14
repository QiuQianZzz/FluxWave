import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/backup_service.dart';
import '../core/platform_utils.dart';
import '../providers/liked_songs_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/backup_resolve_dialog.dart';
import '../widgets/page_scroll_view.dart';
import '../widgets/section_card.dart';

/// 备份与恢复页。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  static Widget builder(BuildContext context) => const BackupPage();

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final Set<BackupItem> _selected = Set.of(BackupItem.values);
  bool _exporting = false;
  bool _importing = false;

  Future<void> _export() async {
    if (_selected.isEmpty) {
      AppToast.show(context, '请至少选择一项');
      return;
    }
    setState(() => _exporting = true);
    try {
      final file = await BackupService.export(_selected.toList());
      if (!mounted) return;
      // 移动端：file_selector 不提供保存对话框（getSaveLocation 未实现），
      // 走系统分享面板由用户选择保存位置；桌面端弹系统保存对话框。
      if (PlatformUtils.isMobile) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            subject: 'FluxWave 数据备份',
            text: 'FluxWave 数据备份',
          ),
        );
      } else {
        final saveLocation = await getSaveLocation(
          suggestedName: file.uri.pathSegments.last,
          acceptedTypeGroups: [
            XTypeGroup(label: '备份文件', extensions: ['json']),
          ],
        );
        if (saveLocation == null) return; // 用户取消
        await file.copy(saveLocation.path);
        if (!mounted) return;
        AppToast.show(context, '备份已保存');
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '备份失败: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: '备份文件', extensions: ['json']),
      ],
    );
    if (file == null) return;

    // 读取 manifest
    final backupFile = File(file.path);
    final manifest = await BackupService.readManifest(backupFile);
    if (manifest == null) {
      if (!mounted) return;
      AppToast.show(context, '无效的备份文件');
      return;
    }

    final availableItems = await BackupService.readItems(backupFile);
    if (availableItems.isEmpty) {
      if (!mounted) return;
      AppToast.show(context, '备份文件中没有可恢复的数据');
      return;
    }

    // 让用户选择要导入的项目
    if (!mounted) return;
    final items = await _showImportSelection(availableItems);
    if (items == null || items.isEmpty) return;

    // 检查冲突（结构错误的备份文件在此转为友好提示）
    final Map<BackupItem, List<String>> conflicts;
    try {
      conflicts = await BackupService.detectConflicts(backupFile, items);
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, '备份文件格式错误');
      return;
    }

    if (!mounted) return;
    // 需要用户决策的项：检测到差异的项目（设置无差异时也无需决策）
    final resolutions = <BackupItem, ConflictStrategy>{};
    if (conflicts.isNotEmpty) {
      final result = await BackupResolveDialog.show(context, conflicts);
      if (result == null) return; // 用户取消
      resolutions.addAll(result);
      if (resolutions.isEmpty) {
        if (!mounted) return;
        AppToast.show(context, '未导入任何数据');
        return;
      }
    } else {
      if (!mounted) return;
      AppToast.show(context, '所选数据与本地一致');
      return;
    }

    // 二次确认（存在覆盖时）
    final overwriteItems = [
      for (final e in resolutions.entries)
        if (e.value == ConflictStrategy.overwrite) e.key,
    ];
    if (overwriteItems.isNotEmpty) {
      if (!mounted) return;
      final confirmed = await _showOverwriteConfirm(overwriteItems);
      if (!confirmed) return;
    }

    // 执行导入
    setState(() => _importing = true);
    // 在任何 await 之前捕获所有 Provider 引用（context.read 在 await 前，安全）
    // ignore: use_build_context_synchronously
    final settings = context.read<SettingsProvider>();
    // ignore: use_build_context_synchronously
    final theme = context.read<ThemeProvider>();
    // ignore: use_build_context_synchronously
    final liked = context.read<LikedSongsProvider>();
    // ignore: use_build_context_synchronously
    final player = context.read<PlayerProvider>();
    try {
      await BackupService.import(backupFile, resolutions);
      // 重新加载 Provider 数据（用的是 await 前捕获的引用，不经过 context）
      if (resolutions.containsKey(BackupItem.settings)) {
        await settings.reload();
        await theme.reload();
      }
      if (resolutions.containsKey(BackupItem.likedSongs)) {
        liked.reload();
      }
      if (resolutions.containsKey(BackupItem.playlists)) {
        // 从磁盘恢复播放队列
        await player.reloadQueue();
      }
      if (!mounted) return;
      AppToast.show(context, '恢复完成');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '恢复失败: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<List<BackupItem>?> _showImportSelection(
    List<BackupItem> available,
  ) {
    final selected = Set<BackupItem>.of(available);
    return showDialog<List<BackupItem>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('选择要恢复的项目'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in available)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.label),
                      subtitle: Text(item.description),
                      value: selected.contains(item),
                      onChanged: (v) {
                        setDialogState(() {
                          if (v == true) {
                            selected.add(item);
                          } else {
                            selected.remove(item);
                          }
                        });
                      },
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, selected.toList()),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<bool> _showOverwriteConfirm(List<BackupItem> items) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认覆盖'),
          icon: Icon(
            Icons.warning_amber_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 48,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '覆盖操作将清除本地已有数据，此操作不可撤销。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              for (final item in items)
                Text('• ${item.label}',
                    style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('确认覆盖'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: PageListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            icon: Icons.upload_rounded,
            title: '导出备份',
            children: [
              Text(
                '选择要备份的数据，导出为备份文件。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final item in BackupItem.values)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.label),
                  subtitle: Text(item.description),
                  value: _selected.contains(item),
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selected.add(item);
                      } else {
                        _selected.remove(item);
                      }
                    });
                  },
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _exporting ? null : _export,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_rounded, size: 18),
                  label: Text(_exporting ? '导出中...' : '导出备份'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SectionCard(
            icon: Icons.download_rounded,
            title: '导入恢复',
            children: [
              Text(
                '从备份文件恢复数据。可选择恢复项目，支持合并或覆盖。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _importing ? null : _import,
                  icon: _importing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_open_rounded, size: 18),
                  label: Text(_importing ? '恢复中...' : '选择备份文件'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
