import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/player/song_url.dart';
import 'package:fluxwave/models/song.dart';

void main() {
  group('SongUrlResolver.parse', () {
    test('完整版：freeTrialInfo 为 null → isTrial=false', () {
      final r = SongUrlResolver.parse({
        'code': 200,
        'data': [
          {
            'id': 1,
            'url': 'https://cdn.example/a.mp3',
            'fee': 0,
            'level': 'standard',
            'freeTrialInfo': null,
          },
        ],
      });
      expect(r, isNotNull);
      expect(r!.url, 'https://cdn.example/a.mp3');
      expect(r.isTrial, isFalse);
      expect(r.level, 'standard');
    });

    test('试听片段：freeTrialInfo 非空 → isTrial=true', () {
      final r = SongUrlResolver.parse({
        'code': 200,
        'data': [
          {
            'id': 2,
            'url': 'https://cdn.example/preview.m4a',
            'fee': 1,
            'freeTrialInfo': {'end': 30, 'start': 0},
          },
        ],
      });
      expect(r, isNotNull);
      expect(r!.isTrial, isTrue);
      expect(r.fee, 1);
    });

    test('http 播放地址自动升 https（Android 禁明文）', () {
      final r = SongUrlResolver.parse({
        'code': 200,
        'data': [
          {'id': 1, 'url': 'http://m7.music.126.net/abc.mp3'},
        ],
      });
      expect(r!.url, 'https://m7.music.126.net/abc.mp3');
    });

    test('url 为 null（无版权/需会员）→ 返回 null', () {
      final r = SongUrlResolver.parse({
        'code': 200,
        'data': [
          {'id': 3, 'url': null, 'fee': 1},
        ],
      });
      expect(r, isNull);
    });

    test('code 非 200 → 返回 null', () {
      final r = SongUrlResolver.parse({
        'code': 403,
        'message': '无权限',
        'data': <Object?>[],
      });
      expect(r, isNull);
    });

    test('data 为空 / 非 List → 返回 null', () {
      expect(SongUrlResolver.parse({'code': 200}), isNull);
      expect(SongUrlResolver.parse({'code': 200, 'data': <Object?>[]}), isNull);
    });

    test('本地缓存挂点 MVP 恒 miss', () async {
      const song = Song(id: 1, name: 't');
      final r = await SongUrlResolver.checkLocalCache(song);
      expect(r, isNull);
    });
  });
}
