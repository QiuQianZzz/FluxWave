import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../widgets/cover_image.dart';

/// 从歌曲封面提取主题种子色（vibrant 优先）。
///
/// 流程：取封面字节（复用 [CoverImageCache]）→ 解码时缩样到 ~48px →
/// 按色相分桶聚类，选"饱和度最高且明度居中"的桶（≈ AndroidX Palette.vibrant）；
/// 兜底：量化 RGB 主色 → 像素平均色 → 默认紫。
/// 按 coverUrl 做进程内 LRU 缓存，避免重复下载/解码。
class CoverColorExtractor {
  CoverColorExtractor._();

  static const _kSampleSize = 48;
  static const _kCacheMax = 64;
  static final Map<String, Color> _cache = {};

  static Color? cached(String? rawUrl) {
    final key = CoverImage.normalize(rawUrl);
    return key == null ? null : _cache[key];
  }

  /// 异步取色：命中缓存立即返回；否则下载/解码/聚类后缓存。
  /// 无封面或解码失败返回 null。
  static Future<Color?> extract(String? rawUrl) async {
    final url = CoverImage.normalize(rawUrl);
    if (url == null) return null;
    final hit = _cache[url];
    if (hit != null) return hit;

    final bytes = await CoverImage.fetchBytes(url);
    if (bytes == null) return null;

    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _kSampleSize,
        targetHeight: _kSampleSize,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final width = image.width;
      final height = image.height;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final color = extractVibrantSeed(
        data.buffer.asUint8List(),
        width,
        height,
      );
      _put(url, color);
      return color;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  static void _put(String key, Color color) {
    if (_cache.containsKey(key)) _cache.remove(key);
    _cache[key] = color;
    while (_cache.length > _kCacheMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 纯函数：从 RGBA 像素里提取"vibrant"种子色（可单测）。
  ///
  /// - 跳过透明/过黑/过白/过灰像素；
  /// - 按色相分 24 桶，取饱和度 ≥0.18 且明度在 [0.18,0.82] 中"饱和高 + 明度
  ///   贴近 0.5"得分最高的桶，输出该桶的 RGB 均值；
  /// - 兜底：量化 RGB（每通道 16 级）出现最多的主色 → 全部像素平均色 → 默认紫。
  static Color extractVibrantSeed(List<int> rgba, int width, int height) {
    const bucketCount = 24;
    final satSum = List<double>.filled(bucketCount, 0);
    final lightSum = List<double>.filled(bucketCount, 0);
    final rSum = List<double>.filled(bucketCount, 0);
    final gSum = List<double>.filled(bucketCount, 0);
    final bSum = List<double>.filled(bucketCount, 0);
    final bucketCounts = List<int>.filled(bucketCount, 0);
    final dominantCounts = <int, int>{};
    final dominantSums = <int, List<double>>{};

    final pixelCount = width * height;
    var avgR = 0.0, avgG = 0.0, avgB = 0.0, avgN = 0;

    for (var i = 0; i < pixelCount; i++) {
      final o = i * 4;
      final r = rgba[o].toDouble();
      final g = rgba[o + 1].toDouble();
      final b = rgba[o + 2].toDouble();
      if (rgba[o + 3] < 128) continue;
      avgR += r;
      avgG += g;
      avgB += b;
      avgN++;

      final c = Color.fromARGB(255, r.round(), g.round(), b.round());
      final hsl = HSLColor.fromColor(c);
      final lightness = hsl.lightness;
      final saturation = hsl.saturation;
      // 过黑/过白/过灰对主题种子无贡献。
      if (lightness < 0.06 || lightness > 0.94 || saturation < 0.05) continue;

      final hueBucket = ((hsl.hue / 360) * bucketCount).floor().clamp(
        0,
        bucketCount - 1,
      );
      satSum[hueBucket] += saturation;
      lightSum[hueBucket] += lightness;
      rSum[hueBucket] += r;
      gSum[hueBucket] += g;
      bSum[hueBucket] += b;
      bucketCounts[hueBucket]++;

      final key =
          (r.round() ~/ 16) << 8 | (g.round() ~/ 16) << 4 | (b.round() ~/ 16);
      dominantCounts[key] = (dominantCounts[key] ?? 0) + 1;
      final sums = dominantSums.putIfAbsent(key, () => [0, 0, 0]);
      sums[0] += r;
      sums[1] += g;
      sums[2] += b;
    }

    // 1) vibrant：高饱和 + 明度居中。
    var bestBucket = -1;
    var bestScore = -1.0;
    for (var i = 0; i < bucketCount; i++) {
      if (bucketCounts[i] == 0) continue;
      final meanSat = satSum[i] / bucketCounts[i];
      final meanLight = lightSum[i] / bucketCounts[i];
      if (meanSat < 0.18 || meanLight < 0.18 || meanLight > 0.82) continue;
      final score = meanSat - (meanLight - 0.5).abs() * 0.6;
      if (score > bestScore) {
        bestScore = score;
        bestBucket = i;
      }
    }
    if (bestBucket >= 0) {
      final n = bucketCounts[bestBucket];
      return Color.fromARGB(
        255,
        (rSum[bestBucket] / n).round(),
        (gSum[bestBucket] / n).round(),
        (bSum[bestBucket] / n).round(),
      );
    }

    // 2) 兜底：量化主色。
    if (dominantCounts.isNotEmpty) {
      var bestKey = -1;
      var bestCount = 0;
      dominantCounts.forEach((k, v) {
        if (v > bestCount) {
          bestCount = v;
          bestKey = k;
        }
      });
      final sums = dominantSums[bestKey]!;
      return Color.fromARGB(
        255,
        (sums[0] / bestCount).round(),
        (sums[1] / bestCount).round(),
        (sums[2] / bestCount).round(),
      );
    }

    // 3) 兜底：平均色。
    if (avgN > 0) {
      return Color.fromARGB(
        255,
        (avgR / avgN).round(),
        (avgG / avgN).round(),
        (avgB / avgN).round(),
      );
    }
    return const Color(0xFF9C27B0);
  }
}
