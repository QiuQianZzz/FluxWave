// 该文件为调试测量脚本，print 输出是用途本身。
// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/lyric_spring.dart';

void main() {
  test('measure spring durations', () {
    final preset = LyricSpringPreset.standard;
    final sim = LyricSpring.spring(preset.spring, 14.0, 61.0);
    for (var ms = 0; ms <= 3000; ms += 100) {
      final t = ms / 1000.0;
      print('t=$ms ms: x=${sim.x(t).toStringAsFixed(3)} isDone=${sim.isDone(t)}');
    }
    print('duration()= ${LyricSpring.duration(preset)}');
  });
}