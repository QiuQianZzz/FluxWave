import 'package:flutter/material.dart';

import '../core/backup_service.dart';

/// 冲突解决弹窗：对每个有差异的项目逐项选择 跳过/合并/覆盖。
///
/// 设置项只有 跳过/合并（无覆盖），其余支持 覆盖。
/// 每项默认「合并」。返回每项最终策略；选「跳过」的项目不包含在返回中，
/// 用户取消返回 null。
class BackupResolveDialog extends StatefulWidget {
  const BackupResolveDialog({super.key, required this.conflicts});

  /// 有差异的项目及其摘要列表。
  final Map<BackupItem, List<String>> conflicts;

  /// 弹出本弹窗并等待用户选择，取消返回 null。
  static Future<Map<BackupItem, ConflictStrategy>?> show(
    BuildContext context,
    Map<BackupItem, List<String>> conflicts,
  ) {
    return showDialog<Map<BackupItem, ConflictStrategy>>(
      context: context,
      builder: (_) => BackupResolveDialog(conflicts: conflicts),
    );
  }

  @override
  State<BackupResolveDialog> createState() => _BackupResolveDialogState();
}

class _BackupResolveDialogState extends State<BackupResolveDialog> {
  // 每项当前选择，默认合并。State 实例持有，setState 重建时不会重置。
  late final Map<BackupItem, _ResolveAction> _choices = {
    for (final item in widget.conflicts.keys) item: _ResolveAction.merge,
  };

  /// 各项目的可选处理方式：设置只有 跳过/合并，其余支持 覆盖。
  List<_ResolveAction> _actionsFor(BackupItem item) =>
      item == BackupItem.settings
          ? const [_ResolveAction.skip, _ResolveAction.merge]
          : const [
              _ResolveAction.skip,
              _ResolveAction.merge,
              _ResolveAction.overwrite,
            ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('数据冲突'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请为以下各项选择处理方式：'),
            const SizedBox(height: 12),
            for (final entry in widget.conflicts.entries) ...[
              Text(
                entry.key.label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final name in entry.value)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    '• $name',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (entry.key == BackupItem.settings)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    '选「合并」会用备份中的值覆盖本地对应项',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              SegmentedButton<_ResolveAction>(
                segments: [
                  for (final action in _actionsFor(entry.key))
                    ButtonSegment(value: action, label: Text(action.label)),
                ],
                selected: {_choices[entry.key]!},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _choices[entry.key] = selection.first);
                },
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            {
              for (final e in _choices.entries)
                if (e.value != _ResolveAction.skip)
                  e.key: e.value.strategy!,
            },
          ),
          child: const Text('确认'),
        ),
      ],
    );
  }
}

/// 弹窗中每一项的可选处理方式。
enum _ResolveAction {
  skip('跳过'),
  merge('合并'),
  overwrite('覆盖');

  final String label;
  const _ResolveAction(this.label);

  /// 对应的导入策略；跳过（skip）返回 null。
  ConflictStrategy? get strategy => switch (this) {
        skip => null,
        merge => ConflictStrategy.merge,
        overwrite => ConflictStrategy.overwrite,
      };
}
