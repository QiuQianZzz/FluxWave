import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/material.dart' show HSLColor;

/// 播放页强调色的可读性修正。
///
/// 播放页固定深色背景（流体背景压在近黑底色上），文字用深色主题的浅色
/// （onSurface 白 / onSurfaceVariant 浅灰）。封面取色只影响"强调色"
/// （播放按钮/进度条/歌词高亮），但强调色直接取封面会与背景或次要文字
/// 撞色。这里对封面强调候选做可读性检测与提升：
///
/// - 饱和度 ≥ [kMinSaturation]；
/// - 与背景对比度 ≥ [kMinBackgroundContrast]（深底上保证醒目）；
/// - 与次要文字（inactive）的色距/亮度差 ≥ 阈值（避免"和文字一样浅"）；
/// 不达标就 boost（提饱和 + 压亮度到深底可读区间），仍不达标回退固定亮蓝。
class ReadableAccentResolver {
  const ReadableAccentResolver._();

  static const double kMinSaturation = 0.32;
  static const double kBoostedMinSaturation = 0.52;
  static const double kMinBackgroundContrast = 3.0;
  static const double kMinColorDistance = 0.25;
  static const double kMinLuminanceGap = 0.14;

  /// 深色背景（流体近黑底）回退强调色：亮蓝，确保任何封面下可读。
  static const Color kDarkFallback = Color(0xFF8FD8FF);

  /// 对 [accent]（封面取色候选）做可读性修正，得到深色背景上可用的强调色。
  ///
  /// [inactiveContentColor] 为页面次要文字色（深色主题的 onSurfaceVariant），
  /// [backgroundColor] 为背景代表色（默认近黑深蓝底）。可读则原样返回，
  /// 否则 boost，仍不可读则返回 [kDarkFallback]。
  static Color resolve(
    Color accent, {
    Color? inactiveContentColor,
    Color? backgroundColor,
  }) {
    final bg = backgroundColor ?? const Color(0xFF05060A);
    final inactive = inactiveContentColor ?? const Color(0xFFB8C2CC);

    if (isReadable(accent, inactive, bg)) return accent;

    final boosted = _boost(accent, bg);
    if (isReadable(boosted, inactive, bg)) return boosted;

    return kDarkFallback;
  }

  /// 流体背景色板压暗：明度 [threshold] 以上的颜色压缩到暗区间
  /// [minLightness, maxLightness]（保留色相与饱和），保证浅色/白色封面
  /// 背景下文字仍可读；深色封面原样通过，观感不变。
  static Color darkenForBackground(
    Color color, {
    double threshold = 0.40,
    double minLightness = 0.20,
    double maxLightness = 0.30,
  }) {
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness <= threshold) return color;
    // 0.40..1.0 → min..max 线性映射。
    final t = (hsl.lightness - threshold) / (1.0 - threshold);
    final target =
        minLightness + (maxLightness - minLightness) * t.clamp(0.0, 1.0);
    return HSLColor.fromAHSL(
      hsl.alpha,
      hsl.hue,
      hsl.saturation,
      target,
    ).toColor();
  }

  /// 可读性检测：饱和度足 + 背景对比度足 + 与 inactive 文字差异足。
  static bool isReadable(Color active, Color inactive, Color background) {
    final saturation = _hsl(active).saturation;
    final backgroundContrast = _contrastRatio(active, background);
    final colorDistance = _rgbDistance(active, inactive);
    final luminanceGap = (_relativeLuminance(active) -
            _relativeLuminance(inactive))
        .abs();
    return saturation >= kMinSaturation &&
        backgroundContrast >= kMinBackgroundContrast &&
        (colorDistance >= kMinColorDistance ||
            luminanceGap >= kMinLuminanceGap);
  }

  /// 提升强调色到深色背景可读：提饱和、亮度压到亮区（深底上鲜艳且醒目）。
  static Color _boost(Color source, Color background) {
    var hsl = _hsl(source);
    // 深色背景（近黑）：目标亮度在亮区，饱和度提到下限以上。
    hsl = _HSL(
      hue: hsl.hue,
      saturation: math.max(hsl.saturation, kBoostedMinSaturation),
      lightness: hsl.lightness.clamp(0.58, 0.74),
    );
    final boosted = hsl.toColor();
    // 深底检测基于相对亮度：深背景恒为暗，调整后对比度稳定达标。
    return boosted;
  }

  static _HSL _hsl(Color c) {
    final r = c.r, g = c.g, b = c.b;
    final max = math.max(r, math.max(g, b));
    final min = math.min(r, math.min(g, b));
    final delta = max - min;
    final lightness = (max + min) / 2;
    final saturation = delta == 0
        ? 0.0
        : lightness > 0.5
            ? delta / (2 - max - min)
            : delta / (max + min);
    var hue = 0.0;
    if (delta != 0) {
      if (max == r) {
        hue = ((g - b) / delta) + (g < b ? 6 : 0);
      } else if (max == g) {
        hue = ((b - r) / delta) + 2;
      } else {
        hue = ((r - g) / delta) + 4;
      }
      hue *= 60;
    }
    return _HSL(
      hue: (hue % 360 + 360) % 360,
      saturation: saturation.clamp(0.0, 1.0),
      lightness: lightness.clamp(0.0, 1.0),
    );
  }

  static double _rgbDistance(Color a, Color b) {
    final dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b;
    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  static double _contrastRatio(Color a, Color b) {
    final l1 = _relativeLuminance(a), l2 = _relativeLuminance(b);
    final lighter = math.max(l1, l2), darker = math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }

  static double _relativeLuminance(Color c) {
    final r = _linear(c.r), g = _linear(c.g), b = _linear(c.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  static double _linear(double channel) {
    return channel <= 0.03928
        ? channel / 12.92
        : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  }
}

class _HSL {
  final double hue;
  final double saturation;
  final double lightness;

  const _HSL({
    required this.hue,
    required this.saturation,
    required this.lightness,
  });

  Color toColor() {
    if (saturation == 0) {
      return Color.from(alpha: 1, red: lightness, green: lightness, blue: lightness);
    }
    final q = lightness < 0.5
        ? lightness * (1 + saturation)
        : lightness + saturation - lightness * saturation;
    final p = 2 * lightness - q;
    return Color.from(
      alpha: 1,
      red: _hueRgb(p, q, hue / 360 + 1 / 3),
      green: _hueRgb(p, q, hue / 360),
      blue: _hueRgb(p, q, hue / 360 - 1 / 3),
    );
  }

  double _hueRgb(double p, double q, double t) {
    var h = t;
    if (h < 0) h += 1;
    if (h > 1) h -= 1;
    if (h < 1 / 6) return p + (q - p) * 6 * h;
    if (h < 1 / 2) return q;
    if (h < 2 / 3) return p + (q - p) * (2 / 3 - h) * 6;
    return p;
  }
}
