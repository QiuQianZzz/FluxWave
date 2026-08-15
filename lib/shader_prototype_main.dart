import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

void main() {
  runApp(const MaterialApp(
    home: PrototypePage(),
  ));
}

class PrototypePage extends StatefulWidget {
  const PrototypePage({super.key});

  @override
  State<PrototypePage> createState() => _PrototypePageState();
}

class _PrototypePageState extends State<PrototypePage> {
  bool _enabled = true;
  double _speed = 1.0;
  double _noiseScale = 1.0;
  double _turbulence = 1.0;
  double _warping = 0.4;
  double _presence = 2.0;
  double _darkness = 1.0;

  ui.FragmentProgram? _program;
  String? _error;

  // 测试色板：模拟封面提取的多个主色。
  static const _testColors = [
    Color(0xFF0A3D62), // 深蓝
    Color(0xFF00E676), // 绿
    Color(0xFF7C4DFF), // 紫
    Color(0xFFFFB74D), // 橙
    Color(0xFF4DD0E1), // 青
    Color(0xFFE91E63), // 粉
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final program = await ui.FragmentProgram.fromAsset('shaders/fluid.frag');
      if (mounted) {
        setState(() => _program = program);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _darkness > 0.5
          ? const Color(0xFF050508)
          : const Color(0xFFF4F4F7),
      body: Stack(
        children: [
          Positioned.fill(
            child: _program != null
                ? _FluidPainter(
                    program: _program!,
                    colors: _testColors,
                    enabled: _enabled,
                    speed: _speed,
                    noiseScale: _noiseScale,
                    turbulence: _turbulence,
                    warping: _warping,
                    presence: _presence,
                    darkness: _darkness,
                  )
                : Center(
                    child: Text(
                      _error ?? 'shader loading...',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text('开关',
                            style: TextStyle(color: Colors.white70)),
                        const SizedBox(width: 12),
                        Switch(
                          value: _enabled,
                          onChanged: (v) => setState(() => _enabled = v),
                        ),
                      ],
                    ),
                    _SliderRow(
                      label: '速度',
                      value: _speed,
                      min: 0.1,
                      max: 3,
                      onChanged: (v) => setState(() => _speed = v),
                    ),
                    _SliderRow(
                      label: '噪点',
                      value: _noiseScale,
                      min: 0.2,
                      max: 3,
                      onChanged: (v) => setState(() => _noiseScale = v),
                    ),
                    _SliderRow(
                      label: '湍流',
                      value: _turbulence,
                      min: 0,
                      max: 3,
                      onChanged: (v) => setState(() => _turbulence = v),
                    ),
                    _SliderRow(
                      label: '扭曲',
                      value: _warping,
                      min: 0,
                      max: 2,
                      onChanged: (v) => setState(() => _warping = v),
                    ),
                    _SliderRow(
                      label: '色彩循环',
                      value: _presence,
                      min: 1,
                      max: 8,
                      onChanged: (v) => setState(() => _presence = v),
                    ),
                    _SliderRow(
                      label: '深色',
                      value: _darkness,
                      min: 0,
                      max: 1,
                      onChanged: (v) => setState(() => _darkness = v),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
      ],
    );
  }
}

class _FluidPainter extends StatefulWidget {
  final ui.FragmentProgram program;
  final List<Color> colors;
  final bool enabled;
  final double speed;
  final double noiseScale;
  final double turbulence;
  final double warping;
  final double presence;
  final double darkness;

  const _FluidPainter({
    required this.program,
    required this.colors,
    required this.enabled,
    required this.speed,
    required this.noiseScale,
    required this.turbulence,
    required this.warping,
    required this.presence,
    required this.darkness,
  });

  @override
  State<_FluidPainter> createState() => _FluidPainterState();
}

class _FluidPainterState extends State<_FluidPainter>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _time = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    if (widget.enabled) _ticker.start();
  }

  void _onTick(Duration elapsed) {
    _time.value = elapsed.inMicroseconds / 1e6;
  }

  @override
  void didUpdateWidget(_FluidPainter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_ticker.isActive) {
      _ticker.start();
    } else if (!widget.enabled && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          willChange: true,
          painter: _FluidShaderPainter(
            program: widget.program,
            colors: widget.colors,
            time: _time,
            speed: widget.speed,
            noiseScale: widget.noiseScale,
            turbulence: widget.turbulence,
            warping: widget.warping,
            presence: widget.presence,
            darkness: widget.darkness,
          ),
        ),
      ),
    );
  }
}

class _FluidShaderPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final List<Color> colors;
  final ValueNotifier<double> time;
  final double speed;
  final double noiseScale;
  final double turbulence;
  final double warping;
  final double presence;
  final double darkness;

  _FluidShaderPainter({
    required this.program,
    required this.colors,
    required this.time,
    required this.speed,
    required this.noiseScale,
    required this.turbulence,
    required this.warping,
    required this.presence,
    required this.darkness,
  }) : super(repaint: time);

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    shader.getUniformVec2('uResolution').set(size.width, size.height);
    shader.getUniformFloat('uTime').set(time.value);

    final n = colors.length > 6 ? 6 : colors.length;
    shader.getUniformFloat('uColorCount').set(n.toDouble());
    for (var i = 0; i < 6; i++) {
      final base = i * 4;
      if (i < n) {
        final c = colors[i];
        shader.getUniformFloat('uColors', base).set(c.r);
        shader.getUniformFloat('uColors', base + 1).set(c.g);
        shader.getUniformFloat('uColors', base + 2).set(c.b);
        shader.getUniformFloat('uColors', base + 3).set(1.0);
      } else {
        shader.getUniformFloat('uColors', base).set(0);
        shader.getUniformFloat('uColors', base + 1).set(0);
        shader.getUniformFloat('uColors', base + 2).set(0);
        shader.getUniformFloat('uColors', base + 3).set(0);
      }
    }

    final p = shader;
    p.getUniformFloat('uParams', 0).set(speed);
    p.getUniformFloat('uParams', 1).set(noiseScale);
    p.getUniformFloat('uParams', 2).set(turbulence);
    p.getUniformFloat('uParams', 3).set(warping);
    p.getUniformFloat('uParams', 4).set(0.06);
    p.getUniformFloat('uParams', 5).set(presence);
    p.getUniformFloat('uParams', 6).set(0.55);
    p.getUniformFloat('uParams', 7).set(0.001);
    p.getUniformFloat('uParams', 8).set(darkness);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_FluidShaderPainter oldDelegate) =>
      oldDelegate.speed != speed ||
      oldDelegate.noiseScale != noiseScale ||
      oldDelegate.turbulence != turbulence ||
      oldDelegate.warping != warping ||
      oldDelegate.presence != presence ||
      oldDelegate.darkness != darkness;
}
