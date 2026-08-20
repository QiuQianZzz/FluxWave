import 'dart:ui' show Color;

import 'package:flutter/material.dart' show HSLColor;
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/color_readability.dart';

void main() {
  group('ReadableAccentResolver.darkenForBackground', () {
    test('深色封面原样通过', () {
      const dark = Color(0xFF1B3B6F); // lightness ≈ 0.17
      expect(ReadableAccentResolver.darkenForBackground(dark), dark);
    });

    test('过亮颜色压暗到暗区间，色相保留', () {
      const white = Color(0xFFFFFFFF);
      final darkened = ReadableAccentResolver.darkenForBackground(white);
      final hsl1 = HSLColor.fromColor(darkened);
      // HSL→RGB→HSL 往返有浮点误差，断言落在暗区间附近。
      expect(hsl1.lightness, inInclusiveRange(0.18, 0.35));
      // 用浅蓝验证色相保留。
      const paleBlue = Color(0xFFB8D4F0);
      final d = ReadableAccentResolver.darkenForBackground(paleBlue);
      expect(HSLColor.fromColor(d).hue, closeTo(212.7, 5.0));
    });

    test('过亮高饱和颜色同时压饱和，避免暗底发浊', () {
      // 亮红（高饱和）：压暗后饱和 ≤ 上限 0.35。
      const brightRed = Color(0xFFFF4444);
      final d = ReadableAccentResolver.darkenForBackground(brightRed);
      final hsl = HSLColor.fromColor(d);
      expect(hsl.saturation, lessThanOrEqualTo(0.35 + 1e-9));
      expect(hsl.lightness, inInclusiveRange(0.18, 0.35));
    });

    test('阈值以下的封面不动', () {
      // lightness ≈ 0.35 < 阈值 0.40，原样通过。
      const midDark = Color(0xFF335A80);
      expect(ReadableAccentResolver.darkenForBackground(midDark), midDark);
      // lightness ≈ 0.54 > 阈值，被压暗。
      const normal = Color(0xFF4A90C8);
      expect(
        ReadableAccentResolver.darkenForBackground(normal),
        isNot(equals(normal)),
      );
    });
  });

  group('ReadableAccentResolver.resolve', () {
    test('暗底上可读的强调色原样返回', () {
      const accent = Color(0xFF4FC3F7); // 亮蓝，深底可读
      final out = ReadableAccentResolver.resolve(accent);
      expect(out, accent);
    });

    test('过暗但带真实色相的强调色被提升', () {
      const muddy = Color(0xFF5A4030); // 深棕，饱和 0.3，深底对比不足
      final out = ReadableAccentResolver.resolve(muddy);
      expect(out, isNot(equals(muddy)));
      final hsl = HSLColor.fromColor(out);
      expect(hsl.saturation, greaterThanOrEqualTo(0.5));
      expect(hsl.lightness, inInclusiveRange(0.55, 0.80));
    });

    test('近无彩色（白/灰，色相=噪声）返回固定中性冷灰，不再放大噪声', () {
      const white = Color(0xFFE8E8E8);
      const gray = Color(0xFF9E9E9E);
      const warmWhite = Color(0xFFF7F4F2); // 白平衡偏暖的白灰封面
      expect(
        ReadableAccentResolver.resolve(white),
        ReadableAccentResolver.kNeutralAccent,
      );
      expect(
        ReadableAccentResolver.resolve(gray),
        ReadableAccentResolver.kNeutralAccent,
      );
      // 不放大成浅红/浅橙。
      final out = ReadableAccentResolver.resolve(warmWhite);
      expect(out, ReadableAccentResolver.kNeutralAccent);
      expect(out, isNot(equals(ReadableAccentResolver.kDarkFallback)));
    });

    test('中性冷灰在深底上可读且与次要文字可区分', () {
      const active = ReadableAccentResolver.kNeutralAccent;
      expect(
        ReadableAccentResolver.isReadable(
          active,
          const Color(0xFFB8C2CC),
          const Color(0xFF05060A),
        ),
        isTrue,
      );
    });

    test('极端暗色被提升为深底可读色（而非 fallback）', () {
      const nearBlack = Color(0xFF000000);
      final out = ReadableAccentResolver.resolve(nearBlack);
      // boost 后即满足可读条件，返回提升色；只有 boost 仍不可读才走 fallback。
      final readable = ReadableAccentResolver.isReadable(
        out,
        const Color(0xFFB8C2CC),
        const Color(0xFF05060A),
      );
      expect(readable, isTrue);
    });

    test('boost 仍不可读时回退固定亮蓝', () {
      // inactive 与 boost 结果同色 → 色距与亮度差均为 0 → 回退 fallback。
      final out = ReadableAccentResolver.resolve(
        const Color(0xFF7F1D1D),
        inactiveContentColor: const Color(0xFFD75151),
        backgroundColor: const Color(0xFF05060A),
      );
      expect(out, ReadableAccentResolver.kDarkFallback);
    });
  });
}
