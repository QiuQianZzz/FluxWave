import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/models/song.dart';

/// `Song` 封面缩略 URL 构造逻辑（纯函数，不联网）。
void main() {
  Song song({String? cover}) => Song(id: 1, name: 'x', coverUrl: cover);

  test('coverSmall 默认 100：无 param 时追加 ?param=100y100', () {
    final s = song(cover: 'http://p1.music.126.net/abc.jpg');
    expect(s.coverSmall, 'http://p1.music.126.net/abc.jpg?param=100y100');
  });

  test('coverFor：可指定任意尺寸', () {
    final s = song(cover: 'http://p1.music.126.net/abc.jpg');
    expect(s.coverFor(300), 'http://p1.music.126.net/abc.jpg?param=300y300');
    expect(s.coverFor(500), 'http://p1.music.126.net/abc.jpg?param=500y500');
  });

  test('已带其他 query：用 & 追加，不重复 ?', () {
    final s = song(cover: 'http://p1.music.126.net/abc.jpg?foo=1');
    expect(s.coverSmall, 'http://p1.music.126.net/abc.jpg?foo=1&param=100y100');
  });

  test('已带 param：原样返回，不重复追加', () {
    final s = song(cover: 'http://p1.music.126.net/abc.jpg?param=200y200');
    expect(s.coverSmall, 'http://p1.music.126.net/abc.jpg?param=200y200');
  });

  test('无封面：返回 null', () {
    final s = song(cover: null);
    expect(s.coverSmall, isNull);
    final s2 = song(cover: '');
    expect(s2.coverSmall, isNull);
  });

  test('原图 URL 不受影响（coverUrl 保持原样）', () {
    final s = song(cover: 'http://p1.music.126.net/abc.jpg');
    expect(s.coverUrl, 'http://p1.music.126.net/abc.jpg');
  });

  test('isPaid：fee=0/8 免费可听，fee=1/4 才付费', () {
    Song withFee(int fee) => Song(id: 1, name: 'x', fee: fee);
    expect(withFee(0).isPaid, isFalse); // 免费
    expect(withFee(8).isPaid, isFalse, reason: '会员高音质视作免费'); // 会员高音质
    expect(withFee(1).isPaid, isTrue); // VIP
    expect(withFee(4).isPaid, isTrue); // 购买专辑
  });

  group('source 命名空间 json 往返', () {
    test('默认网易云，toJson 带 source，fromJson 还原', () {
      final s = Song(id: 7, name: 'x', source: 'kugou');
      expect(s.source, 'kugou');
      expect(s.toJson()['source'], 'kugou');
      expect(Song.fromJson(s.toJson()).source, 'kugou');
    });

    test('旧 JSON 缺 source 回退网易云（零迁移）', () {
      final s = Song.fromJson({'id': 7, 'name': 'x'});
      expect(s.source, SongSource.netease);
      expect(s.id, 7);
    });
  });
}
