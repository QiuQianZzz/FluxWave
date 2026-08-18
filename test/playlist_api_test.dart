import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/models/playlist.dart';
import 'package:fluxwave/models/song.dart';

/// 假客户端：不发真实网络，仅捕获 API 层生成的请求参数并按 uri 回放预设响应。
class FakePlaylistClient extends NeteaseClient {
  FakePlaylistClient()
    : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  final recordedUris = <String>[];
  final recordedDatas = <Map<String, Object>>[];
  final recordedModes = <NeteaseMode>[];

  /// uri -> 响应；未命中返回 code 404。
  final Map<String, Map<String, dynamic>> stubs = {};

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    recordedUris.add(uri);
    recordedDatas.add(data);
    recordedModes.add(mode);
    return stubs[uri] ?? const {'code': 404, 'msg': 'no stub'};
  }
}

void main() {
  group('Playlist 模型', () {
    test('user/playlist 项解析（含 creator 与特殊歌单字段）', () {
      final p = Playlist.fromJson({
        'id': 1,
        'name': '我喜欢的音乐',
        'coverImgUrl': 'http://x/c.jpg',
        'description': 'desc',
        'trackCount': 2,
        'creator': {'nickname': 'me', 'userId': 100},
        'subscribed': false,
        'specialType': 5,
      });
      expect(p.id, 1);
      expect(p.name, '我喜欢的音乐');
      expect(p.coverSmall, 'http://x/c.jpg?param=300y300');
      expect(p.trackCount, 2);
      expect(p.creatorNickname, 'me');
      expect(p.creatorId, 100);
      expect(p.subscribed, isFalse);
      expect(p.specialType, 5);
    });

    test('欠字段解析容错（空 creator / 无 cover）', () {
      final p = Playlist.fromJson({'id': 2, 'name': '没有封面的歌单'});
      expect(p.id, 2);
      expect(p.coverSmall, isNull);
      expect(p.creatorNickname, isNull);
      expect(p.creatorId, isNull);
      expect(p.trackCount, isNull);
    });

    test('isLikedPlaylist：specialType=5 且创作者是本人', () {
      final p = Playlist.fromJson({
        'id': 1,
        'name': '我喜欢的音乐',
        'creator': {'userId': 100},
        'specialType': 5,
      });
      expect(isLikedPlaylist(p, 100), isTrue);
      expect(isLikedPlaylist(p, 999), isFalse);
    });

    test('isLikedPlaylist：名字含"我喜欢的音乐"且本人即可（无 specialType）', () {
      final p = Playlist.fromJson({
        'id': 2,
        'name': '我喜欢的音乐 2026',
        'creator': {'userId': 100},
      });
      expect(isLikedPlaylist(p, 100), isTrue);
    });

    test('findLikedPlaylistId：优先 specialType=5 的我喜欢歌单', () {
      final liked = Playlist.fromJson({
        'id': 10,
        'name': '我喜欢的音乐',
        'creator': {'userId': 100},
        'specialType': 5,
      });
      final other = Playlist.fromJson({
        'id': 20,
        'name': '派对',
        'creator': {'userId': 100},
      });
      expect(findLikedPlaylistId([other, liked], 100), 10);
    });

    test('findLikedPlaylistId：无我喜欢时兜底首个歌单', () {
      final a = Playlist.fromJson({
        'id': 30,
        'name': 'A',
        'creator': {'userId': 100},
      });
      expect(findLikedPlaylistId([a], 100), 30);
      expect(findLikedPlaylistId([], 100), isNull);
    });
  });

  group('Song 模型时间字段兼容', () {
    test('歌单/song-detail 用 dt 字段提供时长（毫秒）', () {
      final s = Song.fromSearch({
        'id': 1,
        'name': 'n',
        'dt': 230000,
        'ar': [
          {'name': 'artist'},
        ],
        'al': {'id': 9, 'name': 'album'},
      });
      expect(s.durationMs, 230000);
      expect(s.durationLabel, '3:50');
      expect(s.artistsLabel, 'artist');
      expect(s.coverUrl, isNull);
    });

    test('搜索接口用 duration 字段时优先级不变', () {
      final s = Song.fromSearch({'id': 1, 'name': 'n', 'duration': 10000});
      expect(s.durationMs, 10000);
    });
  });

  group('API 参数构造', () {
    test(
      'userPlaylists：weapi 端点位置与参数（uid/limit/offset/includeVideo）',
      () async {
        final client = FakePlaylistClient();
        client.stubs['/api/user/playlist'] = {
          'code': 200,
          'playlist': [
            {
              'id': 1,
              'name': 'x',
              'creator': {'userId': 100},
            },
          ],
        };
        final api = NeteaseApi(client);
        final res = await api.userPlaylists(100, limit: 30, offset: 60);
        expect(client.recordedModes, [NeteaseMode.weapi]);
        expect(client.recordedUris, ['/api/user/playlist']);
        expect(client.recordedDatas.first['uid'], 100);
        expect(client.recordedDatas.first['limit'], 30);
        expect(client.recordedDatas.first['offset'], 60);
        expect(client.recordedDatas.first['includeVideo'], true);
        expect(res['code'], 200);
      },
    );

    test('playlistDetail：eapi + n=100000 + s=8', () async {
      final client = FakePlaylistClient();
      client.stubs['/api/v6/playlist/detail'] = {
        'code': 200,
        'playlist': {'id': 5, 'name': '混合'},
      };
      final api = NeteaseApi(client);
      final res = await api.playlistDetail(5);
      expect(client.recordedModes, [NeteaseMode.eapi]);
      expect(client.recordedUris, ['/api/v6/playlist/detail']);
      expect(client.recordedDatas.first, {'id': 5, 'n': 100000, 's': 8});
      expect(res['code'], 200);
    });

    test('songDetailByIds：c 构造与 500 分批、顺序拼接、dt 时长兼容', () async {
      final client = FakePlaylistClient();
      client.stubs['/api/v3/song/detail'] = {
        'code': 200,
        'songs': [
          {'id': 1, 'name': 'a', 'dt': 111000},
        ],
      };
      final api = NeteaseApi(client);
      final ids = List.generate(1001, (i) => i + 1);
      final songs = await api.songDetailByIds(ids);
      // 1001 条 -> 3 批
      expect(client.recordedUris.length, 3);
      for (final uri in client.recordedUris) {
        expect(uri, '/api/v3/song/detail');
      }
      final sizes = client.recordedDatas
          .map((d) => d['c']!.toString())
          .toList();
      expect(sizes[0], startsWith('[{"id":1}'));
      expect(sizes[2], endsWith('{"id":1001}]'));
      for (final c in sizes) {
        final n = RegExp(r'\{"id":(\d+)\}').allMatches(c).length;
        expect(n, lessThanOrEqualTo(500));
      }
      // 假 client 每次都返同一首歌，故拼接 3 份
      expect(songs.length, 3);
      expect(songs.first.name, 'a');
      expect(songs.first.durationMs, 111000);
    });
  });
}
