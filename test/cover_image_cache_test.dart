import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/widgets/cover_image.dart';

Uint8List _bytes(int n) => Uint8List.fromList(List.filled(n, 1));

void main() {
  test('基本存取：未命中 null，命中返回数据', () {
    final c = CoverImageCache.instance;
    c.put('a', _bytes(2));
    expect(c.get('a'), isNotNull);
    expect(c.get('missing'), isNull);
    expect(c.get('a')!.length, 2);
  });

  test('LRU 淘汰：最久未使用的键被挤出', () {
    final c = CoverImageCache.instance;
    // 填满到上限（256）：0..255，键 0 最老
    for (var i = 0; i < 256; i++) {
      c.put('k$i', _bytes(1));
    }
    // 新键触发淘汰 → 挤出最老的 k0
    c.put('new', _bytes(1));
    expect(c.get('k0'), isNull, reason: 'k0 最久未使用，应被挤出');
    expect(c.get('new'), isNotNull);
    expect(c.get('k255'), isNotNull);
  });

  test('LRU 命中提升：访问过的键不因时间老被淘汰', () {
    final c = CoverImageCache.instance;
    for (var i = 0; i < 256; i++) {
      c.put('m$i', _bytes(1));
    }
    // 访问 m0 → m0 变为最近使用
    expect(c.get('m0'), isNotNull);
    // 再挤一个：应淘汰次老的 m1，而不是刚才访问的 m0
    c.put('m-new', _bytes(1));
    expect(c.get('m0'), isNotNull, reason: 'm0 刚被访问过，不应被淘汰');
    expect(c.get('m1'), isNull, reason: 'm1 才是最久未使用');
  });
}
