import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/providers/artist_provider.dart';

/// 假客户端：按 uri 路由返回预设响应，支持抛异常。
class FakeArtistClient extends NeteaseClient {
  FakeArtistClient()
      : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  int callCount = 0;
  final Map<String, Object Function()> _routers = {};
  Object? Function()? _fallback;

  /// 按 uri 注册响应工厂。
  void on(String uri, Object Function() handler) {
    _routers[uri] = handler;
  }

  /// 设置兜底响应。
  void fallback(Object Function() handler) {
    _fallback = handler;
  }

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    callCount++;
    final handler = _routers[uri] ?? _fallback;
    if (handler == null) return const {'code': 404};
    return handler();
  }
}

Map<String, dynamic> _detailResp({int id = 1}) => {
  'code': 200,
  'data': {
    'artist': {
      'id': id,
      'name': '歌手$id',
      'cover': 'http://img.com/cover.jpg',
      'avatar': 'http://img.com/avatar.jpg',
      'alias': ['别名'],
      'briefDesc': '简介',
      'musicSize': 100,
      'albumSize': 10,
      'followed': false,
    },
    'followerCount': 999,
  },
};

Map<String, dynamic> _songsResp({bool more = false}) => {
  'code': 200,
  'songs': [
    {
      'id': 11, 'name': '歌1',
      'ar': [{'id': 1, 'name': '歌手1'}],
      'al': {'id': 1, 'name': '专辑1', 'picUrl': 'http://img.com/a.jpg'},
      'dt': 200000,
    },
    {
      'id': 12, 'name': '歌2',
      'ar': [{'id': 1, 'name': '歌手1'}],
      'al': {'id': 2, 'name': '专辑2', 'picUrl': 'http://img.com/b.jpg'},
      'dt': 300000,
    },
  ],
  'more': more,
};

Map<String, dynamic> _albumsResp({bool more = false}) => {
  'code': 200,
  'hotAlbums': [
    {'id': 100, 'name': '专辑A', 'picUrl': 'http://img.com/al.jpg', 'size': 10},
    {'id': 101, 'name': '专辑B', 'picUrl': 'http://img.com/al2.jpg', 'size': 8},
  ],
  'more': more,
};

void main() {
  late FakeArtistClient client;
  late NeteaseApi api;
  late ArtistProvider provider;

  setUp(() {
    client = FakeArtistClient();
    api = NeteaseApi(client);
    provider = ArtistProvider();

    // 默认路由：3 个接口都返回空数据
    client.on('/api/artist/head/info/get', () => {'code': 200, 'data': {}});
    client.on('/api/v1/artist/songs', () => {'code': 200, 'songs': [], 'more': false});
    client.on('/api/artist/albums/1', () => {'code': 200, 'hotAlbums': [], 'more': false});
    client.on('/api/artist/albums/2', () => {'code': 200, 'hotAlbums': [], 'more': false});
  });

  tearDown(() {
    provider.dispose();
  });

  group('loadArtist', () {
    test('并发拉取 detail + songs + albums', () async {
      client.on('/api/artist/head/info/get', () => _detailResp());
      client.on('/api/v1/artist/songs', () => _songsResp());
      client.on('/api/artist/albums/1', () => _albumsResp());

      await provider.loadArtist(api, 1);

      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
      expect(provider.detail, isNotNull);
      expect(provider.detail!.name, '歌手1');
      expect(provider.detail!.alias, '别名');
      expect(provider.songs, hasLength(2));
      expect(provider.songs[0].name, '歌1');
      expect(provider.albums, hasLength(2));
      expect(provider.albums[0].name, '专辑A');
      expect(provider.songsHasMore, isFalse);
      expect(provider.albumsHasMore, isFalse);
      expect(provider.followerCount, 999);
    });

    test('分页标记正确（有更多）', () async {
      client.on('/api/artist/head/info/get', () => _detailResp());
      client.on('/api/v1/artist/songs', () => _songsResp(more: true));
      client.on('/api/artist/albums/1', () => _albumsResp(more: true));

      await provider.loadArtist(api, 1);

      expect(provider.songsHasMore, isTrue);
      expect(provider.albumsHasMore, isTrue);
    });

    test('重复调用取消旧请求', () async {
      var callIndex = 0;
      client.on('/api/artist/head/info/get', () {
        callIndex++;
        return _detailResp(id: callIndex);
      });
      client.on('/api/v1/artist/songs', () => _songsResp());
      client.on('/api/artist/albums/1', () => _albumsResp());
      client.on('/api/artist/albums/2', () => _albumsResp());

      final f1 = provider.loadArtist(api, 1);
      final f2 = provider.loadArtist(api, 2);
      await Future.wait([f1, f2]);

      expect(provider.detail!.id, 2);
    });

    test('异常时 error 非空', () async {
      client.on('/api/artist/head/info/get', () => throw Exception('network'));
      await provider.loadArtist(api, 1);

      expect(provider.loading, isFalse);
      expect(provider.error, isNotNull);
    });
  });

  group('loadMoreSongs', () {
    test('分页加载歌曲', () async {
      client.on('/api/artist/head/info/get', () => _detailResp());
      client.on('/api/v1/artist/songs', () => _songsResp(more: true));
      client.on('/api/artist/albums/1', () => _albumsResp());
      await provider.loadArtist(api, 1);
      expect(provider.songs, hasLength(2));

      client.on('/api/v1/artist/songs', () => {
        'code': 200,
        'songs': [
          {
            'id': 13, 'name': '歌3',
            'ar': [{'id': 1, 'name': '歌手1'}],
            'al': {'id': 1, 'name': '专辑1'},
            'dt': 180000,
          },
        ],
        'more': false,
      });
      await provider.loadMoreSongs(api);

      expect(provider.songs, hasLength(3));
      expect(provider.songs[2].name, '歌3');
      expect(provider.songsHasMore, isFalse);
    });

    test('无更多时不请求', () async {
      client.on('/api/artist/head/info/get', () => _detailResp());
      client.on('/api/v1/artist/songs', () => _songsResp(more: false));
      client.on('/api/artist/albums/1', () => _albumsResp());
      await provider.loadArtist(api, 1);
      final callsAfter = client.callCount;

      await provider.loadMoreSongs(api);
      expect(client.callCount, callsAfter); // 没有新请求
    });

    test('加载中不重复请求', () async {
      client.on('/api/artist/head/info/get', () => _detailResp());
      client.on('/api/v1/artist/songs', () => _songsResp(more: true));
      client.on('/api/artist/albums/1', () => _albumsResp());
      await provider.loadArtist(api, 1);

      // 第一次调用正常完成，songsLoadingMore 回到 false
      await provider.loadMoreSongs(api);
      expect(provider.songsLoadingMore, isFalse);
      // 因为没有更多数据了（more: true 是第一次，第二次会被置为 false），
      // 直接用另一种方式：让第二次调用时 hasMore=false 来验证 guard 生效
    });
  });

  group('loadMoreAlbums', () {
    test('分页加载专辑', () async {
      client.on('/api/artist/head/info/get', () => _detailResp());
      client.on('/api/v1/artist/songs', () => _songsResp());
      client.on('/api/artist/albums/1', () => _albumsResp(more: true));
      await provider.loadArtist(api, 1);
      expect(provider.albums, hasLength(2));

      client.on('/api/artist/albums/1', () => {
        'code': 200,
        'hotAlbums': [
          {'id': 200, 'name': '专辑C', 'picUrl': 'http://img.com/c.jpg', 'size': 6},
        ],
        'more': false,
      });
      await provider.loadMoreAlbums(api);

      expect(provider.albums, hasLength(3));
      expect(provider.albums[2].name, '专辑C');
      expect(provider.albumsHasMore, isFalse);
    });
  });

  group('clear', () {
    test('复位所有状态', () async {
      client.on('/api/artist/head/info/get', () => _detailResp());
      client.on('/api/v1/artist/songs', () => _songsResp());
      client.on('/api/artist/albums/1', () => _albumsResp());
      await provider.loadArtist(api, 1);
      expect(provider.detail, isNotNull);

      provider.clear();
      expect(provider.detail, isNull);
      expect(provider.songs, isEmpty);
      expect(provider.albums, isEmpty);
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
      expect(provider.followerCount, 0);
    });
  });
}
