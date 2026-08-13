import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/playlist_provider.dart';

/// 假客户端：按 uid 记录请求轮次，逐次回放预设响应（用于分页/分组单测）。
class FakePlaylistClient extends NeteaseClient {
  FakePlaylistClient()
    : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  final calls = <Map<String, Object>>[];

  /// 每次调用依次弹出的响应（超过后循环使用最后一个）。
  List<Object> responses = const [];

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    calls.add(data);
    if (responses.isEmpty) return const {'code': 404};
    final idx = calls.length - 1 < responses.length
        ? calls.length - 1
        : responses.length - 1;
    return responses[idx];
  }
}

Map<String, dynamic> _pl(
  int id,
  String name, {
  int specialType = 0,
  bool subscribed = false,
  int creatorId = 100,
}) => {
  'id': id,
  'name': name,
  'creator': {'userId': creatorId},
  'specialType': specialType,
  'subscribed': subscribed,
};

/// 构造一个返回成功列表的假客户端（用于缓存写入/读取场景复用）。
FakePlaylistClient _okClient(List<Map<String, dynamic>> list) {
  final client = FakePlaylistClient();
  client.responses = [
    {'code': 200, 'count': list.length, 'playlist': list},
  ];
  return client;
}

void main() {
  group('PlaylistProvider 拉取与分组', () {
    test('单页 count 足够时一次拉完，liked/created/collected 分组正确', () async {
      final client = FakePlaylistClient();
      final api = NeteaseApi(client);
      client.responses = [
        {
          'code': 200,
          'count': 3,
          'playlist': [
            _pl(1, '我喜欢的音乐', specialType: 5),
            _pl(5, '歌单A'),
            _pl(9, '别人的歌单', subscribed: true, creatorId: 200),
          ],
        },
      ];
      final pp = PlaylistProvider();
      await pp.load(100, api);

      expect(client.calls.length, 1);
      expect(pp.likedId, 1);
      expect(pp.likedPlaylist?.name, '我喜欢的音乐');
      expect(pp.created, hasLength(1));
      expect(pp.created.single.id, 5);
      expect(pp.collected, hasLength(1));
      expect(pp.collected.single.id, 9);
      expect(pp.error, isNull);
    });

    test('count > limit 时分页续拉，最终全量合并', () async {
      final client = FakePlaylistClient();
      final api = NeteaseApi(client);
      // 第 1 页 1000 条，count=1001 → 第 2 页补 1 条
      final page1 = [
        for (var i = 1000; i < 2000; i++)
          _pl(i, 'A$i', creatorId: i == 1999 ? 200 : 100),
      ];
      client.responses = [
        {'code': 200, 'count': 1001, 'playlist': page1},
        {
          'code': 200,
          'count': 1001,
          'playlist': [_pl(77, '尾部歌单', subscribed: true)],
        },
      ];
      final pp = PlaylistProvider();
      await pp.load(100, api);
      expect(client.calls.length, 2);
      expect(pp.playlists.length, 1001);
      // 1999 是他人创建的；其余 999 条 creatorId==100 且首条被当"我喜欢"兜底
      expect(pp.created, hasLength(999));
      expect(pp.collected, hasLength(1));
      expect(pp.collected.single.id, 1999);

      // 同 uid 重入不重拉
      await pp.load(100, api);
      expect(client.calls.length, 2);
    });

    test('同 uid 已加载时跳过，reload 才重拉', () async {
      final client = FakePlaylistClient();
      final api = NeteaseApi(client);
      client.responses = [
        {
          'code': 200,
          'count': 1,
          'playlist': [_pl(1, 'A')],
        },
        {
          'code': 200,
          'count': 1,
          'playlist': [_pl(2, 'B')],
        },
      ];
      final pp = PlaylistProvider();
      await pp.load(100, api);
      expect(pp.playlists.single.id, 1);
      await pp.load(100, api); // 命中缓存
      expect(client.calls.length, 1);
      await pp.load(100, api, reload: true);
      expect(client.calls.length, 2);
      expect(pp.playlists.single.id, 2);
    });

    test('count 缺失（非 int）时分页不越界，按本次页长度终止', () async {
      final client = FakePlaylistClient();
      final api = NeteaseApi(client);
      // 服务端不返回 count：batch 不足 limit → 一次拉完终止
      client.responses = [
        {
          'code': 200,
          'playlist': [_pl(1, 'A')],
        },
      ];
      final pp = PlaylistProvider();
      await pp.load(100, api);
      expect(client.calls.length, 1);
      expect(pp.playlists, hasLength(1));
    });

    test('接口非 200 记 error 且不标记 loaded，登出后 clear 复位', () async {
      final client = FakePlaylistClient();
      final api = NeteaseApi(client);
      client.responses = [
        {'code': 429, 'msg': 'too fast'},
      ];
      final pp = PlaylistProvider();
      await pp.load(100, api);
      expect(pp.error, isNotNull);
      expect(pp.loaded, isFalse);
      expect(pp.loading, isFalse);
      pp.clear();
      expect(pp.playlists, isEmpty);
      expect(pp.error, isNull);
      expect(pp.uid, isNull);
    });
  });

  group('PlaylistProvider 本地缓存', () {
    test('拉取成功后按 (source, uid) 落盘，同 uid 重开 provider 秒显缓存并后台刷新', () async {
      SharedPreferences.setMockInitialValues({});
      final list = [_pl(1, '我喜欢的音乐', specialType: 5), _pl(5, '歌单A')];

      // 第一次：网络拉到 → 落盘
      final client = _okClient(list);
      final pp = PlaylistProvider();
      await pp.load(100, NeteaseApi(client));
      expect(pp.playlists, hasLength(2));

      // 同一 SharedPreferences 里已写入缓存；换新 provider 模拟重开应用，
      // 但这次网络全挂 → 应秒显缓存、不置 error（离线兜底）
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('playlist_cache_netease_100'),
        isNotNull,
        reason: '首次拉取后应已持久化缓存',
      );

      final offline = FakePlaylistClient();
      offline.responses = const []; // 返回 {'code': 404}
      final pp2 = PlaylistProvider();
      await pp2.load(100, NeteaseApi(offline));
      expect(pp2.playlists, hasLength(2));
      expect(pp2.likedId, 1);
      expect(pp2.error, isNull, reason: '有缓存时网络失败不置 error');
      expect(pp2.loaded, isTrue, reason: '缓存态视为已加载');
    });

    test('无缓存时网络失败仍记 error（不误判为离线可用）', () async {
      SharedPreferences.setMockInitialValues({});
      final client = FakePlaylistClient();
      client.responses = const []; // 404
      final pp = PlaylistProvider();
      await pp.load(100, NeteaseApi(client));
      expect(pp.error, isNotNull);
      expect(pp.loaded, isFalse);
    });

    test('登出 clear 只复位内存：磁盘缓存保留（同 uid 重登可秒显）', () async {
      SharedPreferences.setMockInitialValues({});
      final list = [_pl(1, '歌单X')];
      final pp = PlaylistProvider();
      await pp.load(200, NeteaseApi(_okClient(list)));
      expect(pp.playlists, hasLength(1));

      pp.clear();
      // 内存已复位
      expect(pp.playlists, isEmpty);
      expect(pp.uid, isNull);
      expect(pp.loaded, isFalse);
      // 磁盘缓存保留，未因登出被删
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('playlist_cache_netease_200'),
        isNotNull,
        reason: '登出不应删磁盘缓存（按 (source,uid) 键控无污染）',
      );
    });

    test('缓存键按 uid 隔离，切换账号互不串数据', () async {
      SharedPreferences.setMockInitialValues({});
      final ppA = PlaylistProvider();
      await ppA.load(100, NeteaseApi(_okClient([_pl(1, 'A的歌单')])));

      final ppB = PlaylistProvider();
      await ppB.load(200, NeteaseApi(_okClient([_pl(2, 'B的歌单')])));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('playlist_cache_netease_100'), isNotNull);
      expect(prefs.getString('playlist_cache_netease_200'), isNotNull);
      expect(
        prefs.getString('playlist_cache_netease_100'),
        isNot(prefs.getString('playlist_cache_netease_200')),
      );
    });

    test('缓存键按 (source, uid) 隔离：同 uid 不同音源互不串数据', () async {
      SharedPreferences.setMockInitialValues({});
      final ppN = PlaylistProvider();
      await ppN.load(100, NeteaseApi(_okClient([_pl(1, '网易云歌单')])));

      // 同一 uid 但换音源：应写入独立缓存键，且重新加载回显各自数据
      final ppK = PlaylistProvider();
      await ppK.load(
        100,
        NeteaseApi(_okClient([_pl(2, '酷狗歌单')])),
        source: 'kugou',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('playlist_cache_netease_100'), isNotNull);
      expect(prefs.getString('playlist_cache_kugou_100'), isNotNull);
      expect(
        prefs.getString('playlist_cache_netease_100'),
        isNot(prefs.getString('playlist_cache_kugou_100')),
      );
      expect(ppN.playlists.single.id, 1);
      expect(ppK.playlists.single.id, 2);
    });

    test('同 uid 换音源：source 不一致不命中跳过，重新拉取并切换数据集', () async {
      SharedPreferences.setMockInitialValues({});
      final pp = PlaylistProvider();
      await pp.load(100, NeteaseApi(_okClient([_pl(1, '网易云歌单')])));
      expect(pp.playlists.single.id, 1);
      expect(pp.source, SongSource.netease);

      // 同 uid 换 kugou：跳过判定要求 source 一致 → 不命中，重新拉取
      await pp.load(
        100,
        NeteaseApi(_okClient([_pl(2, '酷狗歌单')])),
        source: 'kugou',
      );
      expect(pp.playlists.single.id, 2);
      expect(pp.source, 'kugou');

      // 同 uid 同 source 再入 → 命中跳过，不重拉
      final client = FakePlaylistClient();
      client.responses = const [];
      await pp.load(100, NeteaseApi(client), source: 'kugou');
      expect(client.calls, isEmpty, reason: '同 uid 同 source 应命中跳过');
    });
  });
}
