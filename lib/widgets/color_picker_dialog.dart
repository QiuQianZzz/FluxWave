import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 简易 HSV 颜色拾取对话框：饱和度×明度方形 + 色相条 + HEX 预览。
///
/// 返回用户选定的 [Color]，取消则返回 null。
class ColorPickerDialog extends StatefulWidget {
  final Color initial;
  const ColorPickerDialog({super.key, required this.initial});

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = _hsv.toColor();
    final hex = (color.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    return AlertDialog(
      title: const Text('自定义颜色'),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      content: SizedBox(
        // 自适应宽度：窄屏留边距，避免固定 300 在窄屏横向溢出。
        width: math.min(300, MediaQuery.sizeOf(context).width - 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 180,
              child: _SVField(
                hsv: _hsv,
                onChanged: (s, v) => setState(() {
                  _hsv = _hsv.withSaturation(s).withValue(v);
                }),
              ),
            ),
            const SizedBox(height: 12),
            _HueBar(
              hue: _hsv.hue,
              onChanged: (h) => setState(() => _hsv = _hsv.withHue(h)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '#$hex',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 饱和度（横向）× 明度（纵向）选择区。
class _SVField extends StatelessWidget {
  final HSVColor hsv;
  final void Function(double saturation, double value) onChanged;
  const _SVField({required this.hsv, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return GestureDetector(
          onPanDown: (d) => _handle(d.localPosition, w, h),
          onPanUpdate: (d) => _handle(d.localPosition, w, h),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CustomPaint(
              size: Size.infinite,
              painter: _SVPainter(hue: hsv.hue),
              child: Stack(
                children: [
                  Positioned(
                    left: (hsv.saturation * w).clamp(0.0, w - 18),
                    top: ((1 - hsv.value) * h).clamp(0.0, h - 18),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [
                          BoxShadow(color: Colors.black38, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _handle(Offset local, double w, double h) {
    final s = (local.dx / w).clamp(0.0, 1.0);
    final v = 1 - (local.dy / h).clamp(0.0, 1.0);
    onChanged(s, v);
  }
}

class _SVPainter extends CustomPainter {
  final double hue;
  const _SVPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    // 横向：白 → 纯色（饱和度）
    final satPaint = Paint()
      ..shader = LinearGradient(
        colors: [Colors.white, HSVColor.fromAHSV(1, hue, 1, 1).toColor()],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, satPaint);
    // 纵向：透明 → 黑（明度）
    final valPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, valPaint);
  }

  @override
  bool shouldRepaint(_SVPainter old) => old.hue != hue;
}

/// 色相条（0–360°）。
class _HueBar extends StatelessWidget {
  final double hue;
  final void Function(double hue) onChanged;
  const _HueBar({required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return GestureDetector(
          onPanDown: (d) => _handle(d.localPosition.dx, w),
          onPanUpdate: (d) => _handle(d.localPosition.dx, w),
          child: Container(
            height: 24,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                colors: [
                  for (final h in const [
                    0.0,
                    60.0,
                    120.0,
                    180.0,
                    240.0,
                    300.0,
                    360.0,
                  ])
                    HSVColor.fromAHSV(1, h, 1, 1).toColor(),
                ],
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: (hue / 360 * w).clamp(0.0, w - 8),
                  top: 0,
                  child: Container(
                    width: 8,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.black26, width: 1),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 3),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _handle(double dx, double w) {
    final h = (dx / w).clamp(0.0, 1.0) * 360;
    onChanged(h);
  }
}
