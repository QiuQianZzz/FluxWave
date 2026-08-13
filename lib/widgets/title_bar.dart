import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面端自定义标题栏：Logo + 拖动区 + 窗口控制按钮。
///
/// 仅在桌面平台（Windows/macOS/Linux）使用，移动端无窗口概念。
/// 通过 [main.dart] 中 `setTitleBarStyle(TitleBarStyle.hidden)` 隐藏系统标题栏后，
/// 由本组件接管标题栏的绘制与交互。
///
/// [enabled] 由 main() 在 window_manager 初始化成功后置 true；
/// 初始化失败时保持 false，本组件渲染为空，回退到系统标题栏。
class TitleBar extends StatefulWidget {
  /// window_manager 是否初始化成功（运行时标志）。
  static bool enabled = false;

  const TitleBar({super.key});

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (!TitleBar.enabled) return;
    windowManager.addListener(this);
    _refreshMaximized();
  }

  @override
  void dispose() {
    if (TitleBar.enabled) windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshMaximized() async {
    final v = await windowManager.isMaximized();
    if (mounted && v != _maximized) setState(() => _maximized = v);
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  void _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 初始化失败时不渲染（回退到系统标题栏）
    if (!TitleBar.enabled) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      height: 38,
      color: cs.surfaceContainerLow,
      child: Row(
        children: [
          // 拖动区：仅包裹 Logo + 文字，不包含按钮（避免手势竞争导致延迟）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: _toggleMaximize,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  // Logo
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      color: cs.onPrimaryContainer,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'FluxWave',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 窗口控制按钮（在拖动 GestureDetector 外部，无手势竞争）
          _WindowButton(
            icon: Icons.horizontal_rule_rounded,
            onTap: () => windowManager.minimize(),
          ),
          _WindowButton(
            icon: _maximized
                ? Icons.fullscreen_exit_rounded
                : Icons.crop_square_rounded,
            onTap: _toggleMaximize,
          ),
          _WindowButton(
            icon: Icons.close_rounded,
            onTap: () => windowManager.close(),
            isClose: true,
          ),
        ],
      ),
    );
  }
}

/// 窗口控制按钮：hover 纯色背景 + InkWell 涟漪。
///
/// 按钮位于拖动 [GestureDetector] 外部，无手势竞争，
/// [InkWell.onTap] 即时触发且自带涟漪效果。
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.onTap,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isCloseHover = _hover && widget.isClose;

    final bgColor = isCloseHover
        ? const Color(0xFFC42B1C)
        : (_hover ? cs.surfaceContainerHigh : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: bgColor,
        child: InkWell(
          onTap: widget.onTap,
          splashColor: isCloseHover ? Colors.white24 : null,
          highlightColor: isCloseHover ? Colors.white12 : null,
          child: SizedBox(
            width: 46,
            height: 38,
            child: Icon(
              widget.icon,
              size: 16,
              color: isCloseHover ? Colors.white : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
