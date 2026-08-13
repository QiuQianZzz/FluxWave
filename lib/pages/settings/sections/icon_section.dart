import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_icon.dart';
import '../../../core/launcher_icon.dart';
import '../../../providers/settings_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../widgets/predictive_back_gesture.dart';

/// 桌面图标选择面板（水平可滚动网格），供底部弹层与测试复用。
///
/// 由 [appIconOptions] 列表驱动：新增图标只需在列表里加一项（并按约定放好
/// 预览与 mipmap 资源），此处无需改动。
class LauncherIconPicker extends StatelessWidget {
  const LauncherIconPicker({super.key, this.controller});

  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<SettingsProvider>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              for (final option in appIconOptions)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _IconChoice(
                    option: option,
                    selected: settings.launcherIconId == option.id,
                    onTap: () => _select(context, option.id).ignore(),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '切换后应用会自动退出，重新打开即生效。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _select(BuildContext context, String id) async {
    final settings = context.read<SettingsProvider>();
    if (settings.launcherIconId == id) return;
    // 切换会结束当前 Activity（应用自动退出），先确认再执行。
    final confirmed = await _confirmSwitch(context, id);
    if (!confirmed) return;
    // 先持久化、再触发原生切换，避免"自动退出"切断异步写盘导致下次启动状态回退。
    await settings.setLauncherIconId(id);
    await LauncherIconSwitcher.setIcon(id);
  }

  Future<bool> _confirmSwitch(BuildContext context, String id) {
    final label = appIconOptionFor(id).label;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('切换桌面图标'),
        content: Text('切换为「$label」。切换后应用会自动退出，重新打开即生效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('切换'),
          ),
        ],
      ),
    ).then((v) => v ?? false);
  }
}

/// 弹出"选择桌面图标"底部面板（复用队列面板的预测性返回交互）。
///
/// 按 [showPredictiveBackSheet] 出规格：底部滑入/滑出，边缘 back 手势期间整块
/// 面板等比缩小预览，松手确认后下滑关闭。
Future<void> showLauncherIconPickerSheet(BuildContext context) {
  return showPredictiveBackSheet<void>(
    context,
    barrierColor: Colors.black54,
    barrierLabel: '关闭桌面图标选择',
    // 预测性返回跟随设置开关：关闭时退回普通返回（无预览动画）。
    enabled: context.read<ThemeProvider>().predictiveBack,
    builder: (_) => const _LauncherIconPickerSheetBody(),
  );
}

/// 面板内容：顶栏（拖拽手柄 + 标题）+ [LauncherIconPicker]。
class _LauncherIconPickerSheetBody extends StatefulWidget {
  const _LauncherIconPickerSheetBody();

  @override
  State<_LauncherIconPickerSheetBody> createState() =>
      _LauncherIconPickerSheetBodyState();
}

class _LauncherIconPickerSheetBodyState
    extends State<_LauncherIconPickerSheetBody> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 打开后把当前选中的图标滚到可视区（横向列表，选项多时高亮项可能在屏幕外）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToCurrent() {
    if (!mounted || !_scroll.hasClients) return;
    final settings = context.read<SettingsProvider>();
    final index = appIconOptions.indexWhere(
      (o) => o.id == settings.launcherIconId,
    );
    if (index < 0) return;
    const pitch = 108 + 12; // 格子宽 108 + 右间距 12
    final pos = _scroll.position;
    final target = (index * pitch + 108 / 2 - pos.viewportDimension / 2).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<SettingsProvider>();
    final current = appIconOptionFor(settings.launcherIconId);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── drag handle ──
        Center(
          child: Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            decoration: BoxDecoration(
              color: cs.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Icon(Icons.apps_rounded, size: 22, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                '桌面图标',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '当前：${current.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
          child: LauncherIconPicker(controller: _scroll),
        ),
      ],
    );
  }
}

class _IconChoice extends StatelessWidget {
  final AppIconOption option;
  final bool selected;
  final VoidCallback onTap;

  const _IconChoice({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SizedBox(
      width: 108,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? cs.primary : cs.outlineVariant,
              width: selected ? 2 : 1,
            ),
            color: selected ? cs.primary.withValues(alpha: 0.06) : null,
          ),
          child: Column(
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(
                      option.previewAsset,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                  if (selected)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: cs.primary,
                        child: Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
