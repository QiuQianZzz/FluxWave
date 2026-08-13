import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_icon.dart';
import '../../../core/platform_utils.dart';
import '../../../providers/settings_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../widgets/color_picker_dialog.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/page_scroll_view.dart';
import '../../../widgets/theme_switch_diff.dart';
import 'icon_section.dart';

/// 外观设置 section：主题模式 + 种子颜色 + 调色板预览 + 桌面图标（仅 Android）。
class ThemeSection extends StatelessWidget {
  const ThemeSection({super.key});

  static Widget builder(BuildContext context) => const ThemeSection();

  @override
  Widget build(BuildContext context) {
    // 动态取色开启时隐藏手动种子色（种子仅在关闭时可选）。
    final dynamicColor = context.select<ThemeProvider, bool>(
      (t) => t.dynamicColor,
    );
    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _AppearanceCard(),
        const SizedBox(height: 8),
        const _GlassBlurCard(),
        const SizedBox(height: 8),
        const _DynamicColorCard(),
        const SizedBox(height: 8),
        if (!dynamicColor) ...[
          const _SeedColorCard(),
          const SizedBox(height: 8),
        ],
        const _PalettePreviewCard(),
        const SizedBox(height: 8),
        if (PlatformUtils.isAndroid) ...[
          const _BackBehaviorCard(),
          const SizedBox(height: 8),
        ],
        if (PlatformUtils.isAndroid) ...[
          const _HapticCard(),
          const SizedBox(height: 8),
        ],
        if (SettingsProvider.isAndroid) ...[
          const SizedBox(height: 8),
          const _LauncherIconCard(),
        ],
        const SizedBox(height: 32),
      ],
    );
  }
}

/// 界面毛玻璃：导航栏 / 侧边栏 / 迷你播放器等界面元素共用同一毛玻璃效果。
class _GlassBlurCard extends StatelessWidget {
  const _GlassBlurCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<SettingsProvider>();
    return SectionCard(
      icon: Icons.blur_on_rounded,
      title: '界面毛玻璃',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('界面毛玻璃效果'),
          subtitle: Text(
            '开启后导航栏、迷你播放器等界面元素使用半透明毛玻璃背景，'
            '后续新增的界面元素默认跟随此开关。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          value: settings.glassBlur,
          onChanged: (v) => settings.setGlassBlur(v),
        ),
      ],
    );
  }
}

/// 动态取色：主题种子跟随当前歌曲封面自动变化。
class _DynamicColorCard extends StatelessWidget {
  const _DynamicColorCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tp = context.watch<ThemeProvider>();
    return SectionCard(
      icon: Icons.auto_awesome_rounded,
      title: '动态取色',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('根据歌曲封面取色'),
          subtitle: Text(
            '开启后主题色跟随当前播放歌曲的封面自动变化；'
            '关闭时使用下方手动选择的种子颜色。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          value: tp.dynamicColor,
          onChanged: (v) => tp.setDynamicColor(v),
        ),
      ],
    );
  }
}

// ── 外观：主题模式 ───────────────────────────────────────────
class _AppearanceCard extends StatefulWidget {
  const _AppearanceCard();

  @override
  State<_AppearanceCard> createState() => _AppearanceCardState();
}

class _AppearanceCardState extends State<_AppearanceCard> {
  /// 主题模式分段控件的 RenderBox + 最近一次点击位置（全局坐标），
  /// 用于推导被点 **segment** 的中心与尺寸。
  final GlobalKey _buttonKey = GlobalKey();
  Offset? _lastTapGlobal;

  /// 由点击位置推导被点 segment 的全局圆心与起始半径。
  ({Offset origin, double startRadius}) _segmentRevealGeometry() {
    final box = _buttonKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final w = box.size.width;
      final h = box.size.height;
      final segments = 3; // 系统 / 浅色 / 深色
      final segWidth = w / segments;

      // 点击点换算为按钮内局部坐标，落入哪个 segment。
      final local = _lastTapGlobal == null
          ? Offset.zero
          : box.globalToLocal(_lastTapGlobal!);
      final index = (local.dx / segWidth).floor().clamp(0, segments - 1);

      // 该 segment 的中心（按钮内局部）→ 全局。
      final center = Offset((index + 0.5) * segWidth, h / 2);
      return (
        origin: box.localToGlobal(center),
        startRadius: math.max(segWidth, h) / 2,
      );
    }
    // 兜底：屏幕中心。
    final screen = MediaQuery.sizeOf(context);
    return (origin: screen.center(Offset.zero), startRadius: 0);
  }

  void _onModeSelected(ThemeMode mode) {
    final provider = context.read<ThemeProvider>();
    final platform = MediaQuery.platformBrightnessOf(context);
    final oldBrightness = Theme.of(context).brightness;
    final newBrightness = provider.resolveBrightness(mode, platform);

    // 亮度未变（如系统模式与当前系统亮度一致、浅色模式下选浅色）：
    // 无可见变化，直接切换不播动画。
    if (oldBrightness == newBrightness) {
      unawaited(provider.setThemeMode(mode));
      return;
    }

    // 有可见变化：通过 App 根部的 ThemeRevealScope 截取旧画面快照，并以
    // 被点 segment 的中心为圆心、初始等于该 segment 大小向外扩散到全屏。
    final scope = ThemeRevealScope.maybeOf(context);
    final geometry = _segmentRevealGeometry();

    if (scope != null) {
      unawaited(
        scope.startReveal(
          origin: geometry.origin,
          startRadius: geometry.startRadius,
          newMode: mode,
        ),
      );
    } else {
      unawaited(provider.setThemeMode(mode));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tp = context.watch<ThemeProvider>();
    final button = SegmentedButton<ThemeMode>(
      key: _buttonKey,
      segments: const [
        ButtonSegment(
          value: ThemeMode.system,
          label: Text('系统'),
          icon: Icon(Icons.brightness_auto_rounded, size: 18),
        ),
        ButtonSegment(
          value: ThemeMode.light,
          label: Text('浅色'),
          icon: Icon(Icons.light_mode_rounded, size: 18),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          label: Text('深色'),
          icon: Icon(Icons.dark_mode_rounded, size: 18),
        ),
      ],
      selected: {tp.themeMode},
      onSelectionChanged: (v) => _onModeSelected(v.first),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity(horizontal: -1, vertical: -1),
      ),
    );

    // 记录真实点击点（全局坐标），用于推导被点 segment 的中心作为扩散圆心。
    final tapAwareButton = Listener(
      onPointerDown: (e) => _lastTapGlobal = e.position,
      child: button,
    );

    return SectionCard(
      icon: Icons.brightness_6_rounded,
      title: '外观',
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 440;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (narrow) ...[
                  Text('主题模式', style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: tapAwareButton),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text('主题模式', style: theme.textTheme.bodyMedium),
                      ),
                      Expanded(
                        flex: 3,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: tapAwareButton,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '使用 Material Design 3 配色方案，自动基于种子颜色生成完整色调体系。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ── 种子颜色：预设 + 自定义 ─────────────────────────────────
class _SeedColorCard extends StatelessWidget {
  const _SeedColorCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tp = context.watch<ThemeProvider>();
    return SectionCard(
      icon: Icons.color_lens_rounded,
      title: '种子颜色',
      children: [
        Text(
          '选择主题色，FluxWave 将自动生成完整的 Material 3 调色板。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '预设',
          style: theme.textTheme.labelSmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final color in ThemeProvider.seedColors)
              _ColorChip(
                color: color,
                selected: tp.seedColorValue == color,
                onTap: () => tp.setSeedColorValue(color),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '自定义',
          style: theme.textTheme.labelSmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final color in tp.customSeedColors)
              _ColorChip(
                color: color,
                selected: tp.seedColorValue == color,
                onTap: () => tp.setSeedColorValue(color),
                onDelete: () => _confirmDelete(context, tp, color),
              ),
            _AddColorChip(onTap: () => _pickCustomColor(context, tp)),
          ],
        ),
      ],
    );
  }

  Future<void> _pickCustomColor(BuildContext context, ThemeProvider tp) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => ColorPickerDialog(initial: tp.seedColor),
    );
    if (picked != null && context.mounted) {
      tp.addCustomColor(picked.toARGB32());
      tp.setSeedColorValue(picked.toARGB32());
    }
  }

  void _confirmDelete(BuildContext context, ThemeProvider tp, int color) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除颜色'),
        content: const Text('确定要移除此自定义颜色吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              tp.removeCustomColor(color);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

// ── 调色板预览 ───────────────────────────────────────────────
class _PalettePreviewCard extends StatelessWidget {
  const _PalettePreviewCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tp = context.watch<ThemeProvider>();
    final brightness = theme.brightness;
    final p = ColorScheme.fromSeed(
      seedColor: Color(tp.seedColorValue),
      brightness: brightness,
    );
    return SectionCard(
      icon: Icons.palette_rounded,
      title: '调色板预览',
      children: [
        Text(
          '基于当前种子颜色生成的 MD3 色调方案预览。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 16,
          children: [
            _PaletteCard(
              label: 'Primary',
              items: [
                (p.primary, 'primary'),
                (p.onPrimary, 'onPrimary'),
                (p.primaryContainer, 'container'),
                (p.onPrimaryContainer, 'onContainer'),
              ],
            ),
            _PaletteCard(
              label: 'Secondary',
              items: [
                (p.secondary, 'secondary'),
                (p.onSecondary, 'onSecondary'),
                (p.secondaryContainer, 'container'),
                (p.onSecondaryContainer, 'onContainer'),
              ],
            ),
            _PaletteCard(
              label: 'Tertiary',
              items: [
                (p.tertiary, 'tertiary'),
                (p.onTertiary, 'onTertiary'),
                (p.tertiaryContainer, 'container'),
                (p.onTertiaryContainer, 'onContainer'),
              ],
            ),
            _PaletteCard(
              label: 'Neutral',
              items: [
                (p.surface, 'surface'),
                (p.surfaceContainerLow, 'surfaceLow'),
                (p.surfaceContainerHigh, 'surfaceHigh'),
                (p.outline, 'outline'),
              ],
            ),
            _PaletteCard(
              label: 'Error',
              items: [
                (p.error, 'error'),
                (p.onError, 'onError'),
                (p.errorContainer, 'container'),
                (p.onErrorContainer, 'onContainer'),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _PaletteCard extends StatelessWidget {
  final String label;
  final List<(Color, String)> items;
  const _PaletteCard({required this.label, required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: 224,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          _row(items[0], items[1], context, cs),
          const SizedBox(height: 6),
          _row(items[2], items[3], context, cs),
        ],
      ),
    );
  }

  Widget _row(
    (Color, String) a,
    (Color, String) b,
    BuildContext context,
    ColorScheme cs,
  ) {
    return Row(
      children: [
        _swatch(a.$1, a.$2, context, cs),
        const SizedBox(width: 8),
        _swatch(b.$1, b.$2, context, cs),
      ],
    );
  }

  Widget _swatch(
    Color color,
    String name,
    BuildContext context,
    ColorScheme cs,
  ) {
    final theme = Theme.of(context);
    return Expanded(
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 色块组件 ─────────────────────────────────────────────────
class _ColorChip extends StatelessWidget {
  final int color;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  const _ColorChip({
    required this.color,
    required this.selected,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final c = Color(color);
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Material(
              color: c,
              shape: CircleBorder(
                side: selected
                    ? BorderSide(color: cs.surface, width: 3)
                    : BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.6),
                        width: 1,
                      ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                customBorder: const CircleBorder(),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: selected
                      ? Center(
                          child: Icon(
                            Icons.check_rounded,
                            size: 22,
                            color: c.computeLuminance() > 0.5
                                ? Colors.black87
                                : Colors.white,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          if (onDelete != null)
            Positioned(
              right: -2,
              top: -2,
              child: Material(
                color: cs.surfaceContainerHighest,
                shape: CircleBorder(
                  side: BorderSide(color: cs.outlineVariant, width: 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onDelete,
                  customBorder: const CircleBorder(),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: Icon(
                      Icons.close_rounded,
                      size: 12,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AddColorChip extends StatelessWidget {
  final VoidCallback onTap;
  const _AddColorChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      shape: CircleBorder(
        side: BorderSide(color: cs.outlineVariant, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.add_rounded, size: 22, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

// ── 预测性返回（Android 系统行为）───────────────────────────
class _BackBehaviorCard extends StatelessWidget {
  const _BackBehaviorCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tp = context.watch<ThemeProvider>();
    return SectionCard(
      icon: Icons.swipe_rounded,
      title: '返回行为',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('预测性返回（Predictive Back）'),
          subtitle: const Text(
            'Android 系统返回手势的过渡预览。开启后返回键/边缘滑动会显示上一页预览动画；'
            '仅 Android 13+ 支持',
          ),
          value: tp.predictiveBack,
          onChanged: (v) => tp.setPredictiveBack(v),
        ),
        const SizedBox(height: 8),
        Text(
          SettingsProvider.isAndroid
              ? '关闭后可减少部分设备上的过渡动画开销。'
              : '当前平台不支持（仅 Android 生效），此开关保留供 Android 端使用。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ── 桌面图标（仅 Android）：并入外观，点选后弹底部面板 ────────
class _LauncherIconCard extends StatelessWidget {
  const _LauncherIconCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<SettingsProvider>();
    final current = appIconOptionFor(settings.launcherIconId);
    return SectionCard(
      icon: Icons.apps_rounded,
      title: '桌面图标',
      children: [
        InkWell(
          onTap: () => showLauncherIconPickerSheet(context),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    current.previewAsset,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current.label,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '点击更换',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
              ],
            ),
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
}

// ── 触感反馈（tab 切换等交互震动）────────────────────────────
class _HapticCard extends StatelessWidget {
  const _HapticCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sp = context.watch<SettingsProvider>();
    return SectionCard(
      icon: Icons.vibration_rounded,
      title: '触感反馈',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('切页震动'),
          subtitle: const Text('切换页面时触发轻微的触感反馈（点击 Tab 或滑动切换）'),
          value: sp.hapticFeedback,
          onChanged: (v) => sp.setHapticFeedback(v),
        ),
        const SizedBox(height: 8),
        Text(
          '仅 Android 支持（Android 设备带震动马达）；Windows 无触感硬件，开关不生效。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
