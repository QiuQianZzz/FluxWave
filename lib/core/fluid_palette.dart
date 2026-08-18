import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 封面色板 → 1D 色板纹理（供伪流体 shader 查色）。
///
/// 核心思路（伪流体取色）：
/// 把从封面提取的少量主色，按"中心交替展开"策略映射到 [kPaletteSize] 个槽位。
/// 相邻槽位之间做线性插值，确保色板在空间上连续——shader 里相邻高度值
/// 映射到相近颜色，避免等高线边缘的颜色跳变（"一堆液体混在一起"的观感
/// 很大程度来自色板不连续）。
class FluidPalette {
  FluidPalette._();

  /// 色板槽位数（1D 纹理宽度）。越大颜色过渡越细腻。
  static const int kPaletteSize = 2048;

  /// 把 [colors] 展开为连续的 RGBA 像素（[kPaletteSize] * 1）。
  static Uint8List toRgba(List<Color> colors, {int size = kPaletteSize}) {
    final out = Uint8List(size * 4);
    if (colors.isEmpty) {
      // 空色板：默认深灰，避免全黑。
      for (var i = 0; i < size; i++) {
        out[i * 4] = 30;
        out[i * 4 + 1] = 30;
        out[i * 4 + 2] = 40;
        out[i * 4 + 3] = 255;
      }
      return out;
    }

    // 主色 → 关键色序列。为避免相邻主色在色板中突变，把主色按"占比/顺序"
    // 依次放置，并在相邻主色间线性插值。
    final n = colors.length;
    final base = n > 1 ? n : 1;
    for (var i = 0; i < size; i++) {
      // 归一化位置 0..1，按主色数循环展开。
      final t = (i / (size - 1)) * base;
      final idx0 = t.floor() % n;
      final idx1 = (idx0 + 1) % n;
      final f = t - t.floor();
      final c0 = colors[idx0];
      final c1 = colors[idx1];
      final c = Color.lerp(c0, c1, f)!;
      out[i * 4] = (c.r * 255).round();
      out[i * 4 + 1] = (c.g * 255).round();
      out[i * 4 + 2] = (c.b * 255).round();
      out[i * 4 + 3] = 255;
    }
    return out;
  }

  /// 生成 1D 色板 [ui.Image]（可传给 shader 的 sampler）。
  static Future<ui.Image?> buildImage(
    List<Color> colors, {
    int size = kPaletteSize,
  }) async {
    final rgba = toRgba(colors, size: size);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      size,
      1,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }
}
