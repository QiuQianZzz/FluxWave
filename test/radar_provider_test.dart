import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/providers/radar_provider.dart';

/// 假客户端：按歌单 id 回放详情响应。
class FakeRadarClient extends NeteaseClient {
  FakeRadarClient()
    : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  final calls = <String>[];
  Map<String, Map<String, dynamic>> byId = {};

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    final id = data['id']?.toString() ?? '?';
    calls.add(id);
    return byId[id] ?? const {'code': 404};
  }
}

Map<String, dynamic> _radar(int id, String name) => {
  'code': 200,
  'playlist': {
    'id': id,
    'name': name,
    'coverImgUrl': 'https://p1.music.126.net/mock/$id.jpg',
    'description': '描述 $id',
    'trackCount': 30,
  },
};

void main() {
  test('全部成功：按固定 id 顺序返回 7 个雷达，逐个发详情请求', () async {
    final client = FakeRadarClient();
    final api = NeteaseApi(client);
    client.byId = {
      for (final id in radarPlaylistIds) '$id': _radar(id, '雷达-$id'),
    };
    final rp = RadarProvider();
    await rp.load(api);

    expect(client.calls, hasLength(radarPlaylistIds.length));
    expect(rp.loaded, isTrue);
    expect(rp.radars, hasLength(radarPlaylistIds.length));
    for (var i = 0; i < radarPlaylistIds.length; i++) {
      expect(rp.radars[i].id, radarPlaylistIds[i], reason: '顺序应对齐固定 id');
    }
    expect(rp.radars.first.name, '雷达-${radarPlaylistIds.first}');
  });

  test('个别失败容错：非 200/缺 playlist 被跳过，其余保留', () async {
    final client = FakeRadarClient();
    final api = NeteaseApi(client);
    // 只成功 私人/时光/神秘 三个，其余按默认 404 失败
    client.byId = {
      '${radarPlaylistIds[0]}': _radar(radarPlaylistIds[0], '私人雷达'),
      '${radarPlaylistIds[2]}': _radar(radarPlaylistIds[2], '时光雷达'),
      '${radarPlaylistIds[6]}': _radar(radarPlaylistIds[6], '神秘雷达'),
    };
    final rp = RadarProvider();
    await rp.load(api);

    expect(rp.error, isNull);
    expect(rp.loaded, isTrue);
    expect(rp.radars, hasLength(3));
    expect(rp.radars.map((e) => e.name), ['私人雷达', '时光雷达', '神秘雷达']);
    // 失败的也照常发出请求，只是被跳过
    expect(client.calls, hasLength(radarPlaylistIds.length));
  });

  test('全部失败：置 error、保持未加载态，reload 可重试', () async {
    final client = FakeRadarClient();
    final api = NeteaseApi(client);
    // 所有 id 都按默认 404 失败
    final rp = RadarProvider();
    await rp.load(api);

    expect(rp.error, isNotNull, reason: '全部失败不能伪装成空列表');
    expect(rp.loaded, isFalse);
    expect(rp.radars, isEmpty);

    // reload 应仍能重试（loaded=false 时 load 也允许重入）
    client.byId = {
      '${radarPlaylistIds[0]}': _radar(radarPlaylistIds[0], '私人雷达'),
    };
    await rp.reload(api);
    expect(rp.error, isNull);
    expect(rp.radars, hasLength(1));
  });

  test('已加载重入不重拉；reload 强制重拉；clear 复位', () async {
    final client = FakeRadarClient();
    final api = NeteaseApi(client);
    client.byId = {
      '${radarPlaylistIds[0]}': _radar(radarPlaylistIds[0], '私人雷达'),
    };

    final rp = RadarProvider();
    await rp.load(api);
    final firstCalls = client.calls.length;

    await rp.load(api);
    expect(client.calls.length, firstCalls, reason: '已加载后重入不重拉');

    await rp.reload(api);
    expect(client.calls.length, firstCalls * 2, reason: 'reload 强制重拉');

    rp.clear();
    expect(rp.loaded, isFalse);
    expect(rp.radars, isEmpty);
    await rp.load(api);
    expect(client.calls.length, firstCalls * 3);
    expect(rp.radars, hasLength(1));
  });
}
