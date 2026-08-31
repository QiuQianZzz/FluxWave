import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/models/artist.dart';

void main() {
  group('ArtistSummary', () {
    test('fromJson 解析完整数据', () {
      final a = ArtistSummary.fromJson({'id': 123, 'name': '测试歌手'});
      expect(a.id, 123);
      expect(a.name, '测试歌手');
    });

    test('fromJson 字段缺失时用默认值', () {
      final a = ArtistSummary.fromJson({});
      expect(a.id, 0);
      expect(a.name, '');
    });

    test('toJson 往返一致', () {
      const a = ArtistSummary(id: 456, name: '周杰伦');
      final json = a.toJson();
      final b = ArtistSummary.fromJson(json);
      expect(b.id, a.id);
      expect(b.name, a.name);
    });
  });

  group('ArtistDetail', () {
    test('fromJson 解析完整数据（alias 为 List）', () {
      final d = ArtistDetail.fromJson({
        'id': 1,
        'name': '歌手',
        'cover': 'http://img.com/cover.jpg',
        'avatar': 'http://img.com/avatar.jpg',
        'alias': ['别名1', '别名2'],
        'briefDesc': '简介',
        'musicSize': 100,
        'albumSize': 10,
        'followed': true,
      });
      expect(d.id, 1);
      expect(d.name, '歌手');
      expect(d.coverUrl, 'http://img.com/cover.jpg');
      expect(d.avatarUrl, 'http://img.com/avatar.jpg');
      expect(d.alias, '别名1 / 别名2');
      expect(d.briefDesc, '简介');
      expect(d.musicSize, 100);
      expect(d.albumSize, 10);
      expect(d.followed, true);
    });

    test('fromJson 兼容 picUrl/img1v1Url 命名', () {
      final d = ArtistDetail.fromJson({
        'id': 2,
        'name': 'b',
        'picUrl': 'http://img.com/pic.jpg',
        'img1v1Url': 'http://img.com/avatar2.jpg',
      });
      expect(d.coverUrl, 'http://img.com/pic.jpg');
      expect(d.avatarUrl, 'http://img.com/avatar2.jpg');
    });

    test('fromJson 字段缺失时用默认值', () {
      final d = ArtistDetail.fromJson({});
      expect(d.id, 0);
      expect(d.name, '');
      expect(d.coverUrl, isNull);
      expect(d.avatarUrl, isNull);
      expect(d.alias, '');
      expect(d.briefDesc, '');
      expect(d.musicSize, 0);
      expect(d.albumSize, 0);
      expect(d.followed, false);
    });

    test('coverSmall 返回带 param 的 URL', () {
      const d = ArtistDetail(
        id: 1,
        name: 'a',
        coverUrl: 'http://img.com/a.jpg',
      );
      expect(d.coverSmall, 'http://img.com/a.jpg?param=100y100');
    });

    test('coverSmall 已有 param 时不重复追加', () {
      const d = ArtistDetail(
        id: 1,
        name: 'a',
        coverUrl: 'http://img.com/a.jpg?param=300y300',
      );
      expect(d.coverSmall, 'http://img.com/a.jpg?param=300y300');
    });

    test('coverSmall 空 URL 返回 null', () {
      const d = ArtistDetail(id: 1, name: 'a');
      expect(d.coverSmall, isNull);
    });

    test('avatarSmall 返回带 param 的 URL', () {
      const d = ArtistDetail(
        id: 1,
        name: 'a',
        avatarUrl: 'http://img.com/avatar.jpg',
      );
      expect(d.avatarSmall, 'http://img.com/avatar.jpg?param=100y100');
    });

    test('avatarSmall 空 URL 返回 null', () {
      const d = ArtistDetail(id: 1, name: 'a');
      expect(d.avatarSmall, isNull);
    });

    test('coverSmall 处理含查询参数的 URL', () {
      const d = ArtistDetail(
        id: 1,
        name: 'a',
        coverUrl: 'http://img.com/a.jpg?token=abc',
      );
      expect(d.coverSmall, 'http://img.com/a.jpg?token=abc&param=100y100');
    });
  });
}
