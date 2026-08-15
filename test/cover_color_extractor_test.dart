import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/cover_color_extractor.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// 封面取色纯函数与 ThemeProvider 动态取色集成测试。
void main() {
  group('CoverColorExtractor.extractVibrantSeed', () {
    List<int> pixels(int w, int h, Color c) {
      final rgba = <int>[];
      final r = (c.r * 255).round();
      final g = (c.g * 255).round();
      final b = (c.b * 255).round();
      for (var i = 0; i < w * h; i++) {
        rgba
          ..add(r)
          ..add(g)
          ..add(b)
          ..add(255);
      }
      return rgba;
    }

    test('纯红封面 → 高饱和红色种子', () {
      final color = CoverColorExtractor.extractVibrantSeed(
        pixels(4, 4, const Color(0xFFFF0000)),
        4,
        4,
      );
      final hsl = HSLColor.fromColor(color);
      expect(hsl.saturation, greaterThan(0.8));
      // 红色相接近 0°/360°。
      final hue = hsl.hue;
      expect(hue < 30 || hue > 330, isTrue, reason: '应偏向红色相，实际 hue=$hue');
    });

    test('纯灰封面 → 走主色兜底（低饱和）', () {
      final color = CoverColorExtractor.extractVibrantSeed(
        pixels(4, 4, const Color(0xFF808080)),
        4,
        4,
      );
      expect(HSLColor.fromColor(color).saturation, lessThan(0.05));
      expect((color.r * 255).round(), inInclusiveRange(115, 145)); // 近 128
    });

    test('全透明 → 默认紫', () {
      final rgba = List<int>.filled(4 * 4 * 4, 0); // alpha 0
      expect(
        CoverColorExtractor.extractVibrantSeed(rgba, 4, 4),
        const Color(0xFF9C27B0),
      );
    });
  });

  group('CoverColorExtractor.extractPaletteColors', () {
    test('多色封面 → 按占比提取多主色', () {
      // 8x8 像素：左半红、右半蓝（构造两个主色）。
      final rgba = <int>[];
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final c = x < 4 ? const Color(0xFFFF0000) : const Color(0xFF0000FF);
          rgba
            ..add((c.r * 255).round())
            ..add((c.g * 255).round())
            ..add((c.b * 255).round())
            ..add(255);
        }
      }
      final palette = CoverColorExtractor.extractPaletteColors(
        rgba,
        8,
        8,
        count: 4,
      );
      expect(palette, hasLength(4));
      // 前两个主色应覆盖红与蓝两种色相。
      final hues = palette.map((c) => HSLColor.fromColor(c).hue).toSet();
      final hasRed = hues.any((h) => h < 30 || h > 330);
      final hasBlue = hues.any((h) => h > 200 && h < 280);
      expect(hasRed, isTrue, reason: '色板应含红色相，实际 $hues');
      expect(hasBlue, isTrue, reason: '色板应含蓝色相，实际 $hues');
    });

    test('黑白（无彩色）封面 → 用平均色补足色板', () {
      // 纯灰：无高饱和像素，走平均色兜底。
      final rgba = <int>[];
      for (var i = 0; i < 4 * 4; i++) {
        rgba
          ..add(200)
          ..add(200)
          ..add(200)
          ..add(255);
      }
      final palette = CoverColorExtractor.extractPaletteColors(
        rgba,
        4,
        4,
        count: 3,
      );
      expect(palette, hasLength(3));
      for (final c in palette) {
        expect(HSLColor.fromColor(c).saturation, lessThan(0.05));
      }
    });
  });

  group('ThemeProvider 动态取色', () {
    test('默认开启动态取色', () async {
      SharedPreferences.setMockInitialValues({});
      final tp = ThemeProvider();
      expect(tp.dynamicColor, isTrue);
      await tp.init();
      expect(tp.dynamicColor, isTrue);
    });

    test('setDynamicColor 持久化；关闭时清空封面色', () async {
      SharedPreferences.setMockInitialValues({});
      final tp = ThemeProvider();
      await tp.init();
      tp.setCoverSeedColor(const Color(0xFF112233));
      expect(tp.effectiveSeedColor, const Color(0xFF112233));

      await tp.setDynamicColor(false);
      expect(tp.dynamicColor, isFalse);
      expect(tp.coverSeedColor, isNull, reason: '关闭后清空封面色');
      expect(tp.effectiveSeedColor, tp.seedColor);

      final tp2 = ThemeProvider();
      await tp2.init();
      expect(tp2.dynamicColor, isFalse, reason: '开关应持久化');
    });

    test('setCoverSeedColor 改变实际主题的 primary 色', () async {
      SharedPreferences.setMockInitialValues({});
      final tp = ThemeProvider();
      await tp.init();
      final before = tp.lightTheme.colorScheme.primary;

      tp.setCoverSeedColor(const Color(0xFFFF0000));
      expect(tp.coverSeedColor, const Color(0xFFFF0000));
      expect(
        tp.lightTheme.colorScheme.primary,
        isNot(equals(before)),
        reason: '封面种子应改变主题配色',
      );

      tp.setCoverSeedColor(null);
      expect(tp.lightTheme.colorScheme.primary, before, reason: '清空后回退手动种子');
    });
  });
}
