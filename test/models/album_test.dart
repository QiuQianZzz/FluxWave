import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/models/album.dart';

void main() {
  group('AlbumSummary', () {
    test('fromJson 解析完整数据', () {
      final a = AlbumSummary.fromJson({
        'id': 10,
        'name': '专辑',
        'picUrl': 'http://img.com/album.jpg',
        'size': 12,
      });
      expect(a.id, 10);
      expect(a.name, '专辑');
      expect(a.picUrl, 'http://img.com/album.jpg');
      expect(a.size, 12);
    });

    test('fromJson 字段缺失时用默认值', () {
      final a = AlbumSummary.fromJson({});
      expect(a.id, 0);
      expect(a.name, '');
      expect(a.picUrl, isNull);
      expect(a.size, 0);
    });

    test('toJson 往返一致', () {
      const a = AlbumSummary(id: 5, name: 'test', picUrl: 'http://img.com/a.jpg', size: 8);
      final json = a.toJson();
      final b = AlbumSummary.fromJson(json);
      expect(b.id, a.id);
      expect(b.name, a.name);
      expect(b.picUrl, a.picUrl);
      expect(b.size, a.size);
    });

    test('coverSmall 生成缩略 URL', () {
      const a = AlbumSummary(id: 1, name: 'a', picUrl: 'http://img.com/a.jpg');
      expect(a.coverSmall, 'http://img.com/a.jpg?param=100y100');
    });

    test('coverSmall 已有 param 时不重复追加', () {
      const a = AlbumSummary(id: 1, name: 'a', picUrl: 'http://img.com/a.jpg?param=300y300');
      expect(a.coverSmall, 'http://img.com/a.jpg?param=300y300');
    });

    test('coverSmall 空 URL 返回 null', () {
      const a = AlbumSummary(id: 1, name: 'a');
      expect(a.coverSmall, isNull);
    });

    test('coverSmall 处理含查询参数的 URL', () {
      const a = AlbumSummary(id: 1, name: 'a', picUrl: 'http://img.com/a.jpg?token=abc');
      expect(a.coverSmall, 'http://img.com/a.jpg?token=abc&param=100y100');
    });
  });
}
