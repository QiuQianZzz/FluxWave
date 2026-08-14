import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/audio_cache/cover_cache.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cover_cache_test');
    CoverCache.configureForTest(tempDir.path);
  });

  tearDown(() async {
    CoverCache.resetForTest();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 1));

  test('按尺寸独立存取：写入 300 不污染 1000', () async {
    await CoverCache.instance.write('s1', 300, bytes(10));
    expect(
      await CoverCache.instance.read('s1', 1000),
      isNull,
      reason: '只有 300，请求 1000 不应命中（避免小图喂给全屏变糊）',
    );
    expect(await CoverCache.instance.read('s1', 300), isNotNull);

    await CoverCache.instance.write('s1', 1000, bytes(20));
    expect(await CoverCache.instance.read('s1', 1000), isNotNull);
    final f = await CoverCache.instance.read('s1', 300);
    expect(f, isNotNull);
    expect(await f!.length(), 10, reason: '300 槽位保持自己的字节，不被 1000 覆盖');
  });

  test('小尺寸回退大图：精确尺寸缺失时命中 cover_1000.jpg', () async {
    await CoverCache.instance.write('s2', 1000, bytes(50));
    final f = await CoverCache.instance.read('s2', 300);
    expect(f, isNotNull);
    expect(await f!.length(), 50);
  });

  test('清理/统计覆盖所有尺寸文件', () async {
    await CoverCache.instance.write('s3', 100, bytes(4));
    await CoverCache.instance.write('s3', 300, bytes(8));
    await CoverCache.instance.write('s3', 1000, bytes(16));
    expect(await CoverCache.instance.count(), 3);
    expect(await CoverCache.instance.totalBytes(), 28);

    await CoverCache.instance.delete('s3');
    expect(await CoverCache.instance.count(), 0, reason: 'delete 清除该歌所有尺寸');

    await CoverCache.instance.write('s3', 300, bytes(8));
    await CoverCache.instance.clearAll();
    expect(await CoverCache.instance.count(), 0);
    expect(await CoverCache.instance.totalBytes(), 0);
  });
}
