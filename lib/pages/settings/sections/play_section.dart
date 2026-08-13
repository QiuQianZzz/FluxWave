import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/lyric/line_lyric_reveal_mode.dart';
import '../../../core/permissions/notification_permission.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/page_scroll_view.dart';

/// 播放设置 section：音质选择（持久化，下一次播放生效）。
class PlaySection extends StatelessWidget {
  const PlaySection({super.key});

  static Widget builder(BuildContext context) => const PlaySection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<SettingsProvider>();
    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          icon: Icons.graphic_eq_rounded,
          title: '音质',
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '选择播放音质；切换后下一次播放生效。'
                '部分歌曲在所选音质不可用时自动回退到标准音质，'
                '仍不可用则提示需会员或付费。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            for (final (level, label) in SettingsProvider.qualityOptions)
              _QualityTile(
                label: label,
                level: level,
                selected: settings.qualityLevel == level,
                onTap: () => settings.setQualityLevel(level),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (defaultTargetPlatform == TargetPlatform.windows) ...[
          SectionCard(
            icon: Icons.volume_up_rounded,
            title: '音量',
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_down_rounded, size: 18),
                  Expanded(
                    child: Slider(
                      // Flutter 3.44 中 Slider.year2023 已弃用但默认仍为 true
                      // （2023 外观）。置 false 启用 Material3 2024 滑块样式；
                      // 未来版本该旗标默认翻转后，可连同此参数一并删除。
                      // ignore: deprecated_member_use
                      year2023: false,
                      value: settings.windowsVolumePercent,
                      min: 0,
                      max: 100,
                      divisions: 20,
                      label: '${settings.windowsVolumePercent.round()}%',
                      onChanged: (v) {
                        settings.setWindowsVolumePercent(v);
                        context.read<PlayerProvider>().syncWindowsVolume();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${settings.windowsVolumePercent.round()}%',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                'Windows 专属：实际音量限制在 0–${SettingsProvider.windowsVolumeCap} '
                '区间内，与 0%–100% 按比例映射。若单个设备仍偏响，可在系统混音器'
                '中单独调低本应用。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        SectionCard(
          icon: Icons.play_circle_outline_rounded,
          title: '打开时自动播放',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启动后自动播放'),
              value: settings.autoPlayOnOpen,
              onChanged: (v) => settings.setAutoPlayOnOpen(v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (defaultTargetPlatform == TargetPlatform.android) ...[
          _NotificationPermissionCard(),
          const SizedBox(height: 8),
        ],
        SectionCard(
          icon: Icons.lyrics_outlined,
          title: '歌词显示',
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '仅影响行级歌词（LRC，无逐字时间轴）当前行的显示方式；'
                '逐字歌词（YRC）始终走逐字动画。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            for (final mode in LineLyricRevealMode.values)
              _LyricModeTile(
                label: mode.label,
                selected: settings.lineLyricRevealMode == mode,
                onTap: () => settings.setLineLyricRevealMode(mode),
              ),
            const Divider(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('歌词景深模糊'),
              subtitle: Text(
                '聚焦当前行，越往上下边缘越模糊；开启后滑动时自动解除模糊，'
                '方便浏览前后歌词。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              value: settings.lyricDepthBlur,
              onChanged: (v) => settings.setLyricDepthBlur(v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SectionCard(
          icon: Icons.equalizer_rounded,
          title: '均衡器',
          children: [
            Text(
              '即将推出，敬请期待。',
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

/// 音质单选行：自绘单选圆点，避免 MD3 Radio 的 groupValue 废弃 API。
///
/// 无损及以上档位（lossless/hires/jyeffect/sky/jymaster）追加"需会员"提示，
/// 游客或普通用户可能被降级到标准音质。
class _QualityTile extends StatelessWidget {
  final String label;
  final String level;
  final bool selected;
  final VoidCallback onTap;

  /// 无损及以上音质需要会员才可使用完整版。
  static const _premiumLevels = {
    'lossless',
    'hires',
    'jyeffect',
    'sky',
    'jymaster',
  };

  const _QualityTile({
    required this.label,
    required this.level,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final needsVip = _premiumLevels.contains(level);
    return ListTile(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      onTap: onTap,
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_off_rounded,
        size: 22,
        color: selected ? cs.primary : cs.onSurfaceVariant,
      ),
      title: Row(
        children: [
          // Flexible + 省略号：超大字号/窄屏下标签收缩，避免与"需会员"徽标横向溢出。
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
          ),
          if (needsVip) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFE6A23C).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '需会员',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: const Color(0xFFE6A23C),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: needsVip
          ? Text(
              '非会员用户可能被降级到标准音质',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            )
          : null,
      dense: true,
    );
  }
}

/// 行级歌词显示方式单选行：自绘单选圆点（与 [_QualityTile] 一致）。
class _LyricModeTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LyricModeTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListTile(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      onTap: onTap,
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_off_rounded,
        size: 22,
        color: selected ? cs.primary : cs.onSurfaceVariant,
      ),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? cs.onSurface : cs.onSurfaceVariant,
        ),
      ),
      dense: true,
    );
  }
}

/// 通知权限卡片：显示通知权限状态，提供开关和跳转系统设置的功能。
class _NotificationPermissionCard extends StatefulWidget {
  @override
  State<_NotificationPermissionCard> createState() =>
      _NotificationPermissionCardState();
}

class _NotificationPermissionCardState
    extends State<_NotificationPermissionCard> with WidgetsBindingObserver {
  bool _granted = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置返回时刷新权限状态
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final granted = await NotificationPermission.isGranted();
    if (mounted) {
      setState(() {
        _granted = granted;
        _loading = false;
      });
    }
  }

  Future<void> _togglePermission(bool value) async {
    if (value) {
      // 尝试申请权限
      final granted = await NotificationPermission.requestIfNeeded();
      if (mounted) {
        setState(() => _granted = granted);
        if (!granted) {
          // 权限未授予，引导去系统设置
          _showSettingsDialog();
        }
      }
    } else {
      // 关闭时引导去系统设置
      _showSettingsDialog();
    }
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('通知权限'),
        content: const Text(
          '请在系统设置中开启通知权限：\n\n'
          '设置 → 应用 → FluxWave → 通知\n\n'
          '开启后返回此页面即可生效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              NotificationPermission.openSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return SectionCard(
      icon: Icons.notifications_outlined,
      title: '通知栏控制',
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示通知栏播放控制'),
            subtitle: Text(
              _granted
                  ? '已开启：通知栏和锁屏显示当前播放与控制按钮'
                  : '未开启：开启后可在通知栏和锁屏控制播放',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            value: _granted,
            onChanged: _togglePermission,
          ),
          if (!_granted)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '部分系统（如小米澎湃）可能需要在系统设置中手动开启「通知」权限',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ],
    );
  }
}
