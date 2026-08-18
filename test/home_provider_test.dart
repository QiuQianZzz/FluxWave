import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/providers/home_provider.dart';

/// 假客户端：回放单次预设响应（推荐歌单为一次性接口，无分页）。
class FakeHomeClient extends NeteaseClient {
  FakeHomeClient()
    : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  final calls = <Map<String, Object>>[];
  Object? response;

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    calls.add(data);
    return response ?? const {'code': 404};
  }
}

Map<String, dynamic> _pl(int id, String name, {int trackCount = 12}) => {
  'id': id,
  'name': name,
  'coverImgUrl': 'https://p1.music.126.net/mock/$id.jpg',
  'trackCount': trackCount,
};

void main() {
  test('推荐歌单解析 + 已加载重入不重拉 + reload 重拉', () async {
    final client = FakeHomeClient();
    final api = NeteaseApi(client);
    client.response = {
      'code': 200,
      'result': [_pl(1, '华语流行'), _pl(2, '欧美热榜')],
    };
    final hp = HomeProvider();
    await hp.load(api);

    expect(client.calls, hasLength(1));
    expect(hp.loaded, isTrue);
    expect(hp.playlists, hasLength(2));
    expect(hp.playlists.first.name, '华语流行');
    expect(hp.playlists.first.trackCount, 12);
    expect(hp.playlists.first.coverSmall, isNotNull);
    expect(hp.error, isNull);

    await hp.load(api);
    expect(client.calls, hasLength(1), reason: '已加载重入不重拉');

    client.response = {
      'code': 200,
      'result': [_pl(3, '新歌单')],
    };
    await hp.load(api, reload: true);
    expect(client.calls, hasLength(2));
    expect(hp.playlists.single.name, '新歌单');
  });

  test('非 200 记 error 且不标记 loaded，clear 复位', () async {
    final client = FakeHomeClient()..response = const {'code': 429};
    final hp = HomeProvider();
    await hp.load(NeteaseApi(client));
    expect(hp.error, isNotNull);
    expect(hp.loaded, isFalse);
    expect(hp.loading, isFalse);

    hp.clear();
    expect(hp.error, isNull);
    expect(hp.playlists, isEmpty);
    expect(hp.loaded, isFalse);
  });

  test('result 空/缺失 → 空列表但已 loaded（不误判错误）', () async {
    for (final resp in [
      const {'code': 200, 'result': <Object>[]},
      const {'code': 200},
    ]) {
      final client = FakeHomeClient()..response = resp;
      final hp = HomeProvider();
      await hp.load(NeteaseApi(client));
      expect(hp.loaded, isTrue, reason: '空结果也是成功响应');
      expect(hp.playlists, isEmpty);
      expect(hp.error, isNull);
    }
  });

  test('推荐歌单封面字段为 picUrl（无 coverImgUrl）时也能解析出 coverSmall', () async {
    final client = FakeHomeClient()
      ..response = {
        'code': 200,
        'result': [
          {
            'id': 1,
            'name': '华语精选',
            'picUrl': 'https://p2.music.126.net/mock/1.jpg',
          },
        ],
      };
    final hp = HomeProvider();
    await hp.load(NeteaseApi(client));
    expect(hp.playlists, hasLength(1));
    expect(hp.playlists.single.coverSmall, isNotNull);
    expect(
      hp.playlists.single.coverSmall,
      'https://p2.music.126.net/mock/1.jpg?param=300y300',
    );
  });

  test('过滤「私人雷达」类推荐歌单', () async {
    final client = FakeHomeClient()
      ..response = {
        'code': 200,
        'result': [_pl(1, '私人雷达'), _pl(2, '华语流行')],
      };
    final hp = HomeProvider();
    await hp.load(NeteaseApi(client));
    expect(hp.playlists, hasLength(1));
    expect(hp.playlists.single.name, '华语流行');
  });
}
