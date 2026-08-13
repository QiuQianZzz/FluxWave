import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/providers/daily_provider.dart';

/// 假客户端：回放单次预设响应（每日推荐为一次性接口，无分页）。
class FakeDailyClient extends NeteaseClient {
  FakeDailyClient()
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

Map<String, dynamic> _song(int id, String name) => {
  'id': id,
  'name': name,
  'ar': [
    {'name': '歌手$id'},
  ],
  'al': {
    'id': id,
    'name': '专辑$id',
    'picUrl': 'https://p1.music.126.net/mock/$id.jpg',
  },
  'dt': 210000,
  'fee': 0,
};

void main() {
  test('每日推荐解析 + 已加载重入不重拉 + reload 重拉', () async {
    final client = FakeDailyClient();
    final api = NeteaseApi(client);
    client.response = {
      'code': 200,
      'data': {
        'dailySongs': [_song(1, '第一日推'), _song(2, '第二日推')],
      },
    };
    final dp = DailyProvider();
    await dp.load(api);

    expect(client.calls, hasLength(1));
    expect(dp.loaded, isTrue);
    expect(dp.songs, hasLength(2));
    expect(dp.songs.first.name, '第一日推');
    expect(dp.songs.first.artistsLabel, '歌手1');
    expect(dp.songs.first.durationMs, 210000);
    expect(dp.songs.first.coverSmall, isNotNull);
    expect(dp.error, isNull);

    await dp.load(api);
    expect(client.calls, hasLength(1), reason: '已加载重入不重拉');

    client.response = {
      'code': 200,
      'data': {
        'dailySongs': [_song(3, '第三日推')],
      },
    };
    await dp.reload(api);
    expect(client.calls, hasLength(2), reason: 'reload 强制重拉');
    expect(dp.songs, hasLength(1));
    expect(dp.songs.first.name, '第三日推');
  });

  test('非 200 code → 置 error，loaded 保持 false 可重试', () async {
    final client = FakeDailyClient();
    final api = NeteaseApi(client);
    client.response = {'code': 400, 'data': {}};
    final dp = DailyProvider();
    await dp.load(api);

    expect(dp.loaded, isFalse);
    expect(dp.error, isNotNull);
    expect(dp.songs, isEmpty);

    client.response = {
      'code': 200,
      'data': {
        'dailySongs': [_song(1, '恢复')],
      },
    };
    await dp.load(api);
    expect(dp.loaded, isTrue);
    expect(dp.error, isNull);
    expect(dp.songs.first.name, '恢复');
  });

  test('clear 复位状态', () async {
    final client = FakeDailyClient();
    final api = NeteaseApi(client);
    client.response = {
      'code': 200,
      'data': {
        'dailySongs': [_song(1, 'A')],
      },
    };
    final dp = DailyProvider();
    await dp.load(api);
    expect(dp.loaded, isTrue);

    dp.clear();
    expect(dp.loaded, isFalse);
    expect(dp.songs, isEmpty);
    expect(dp.error, isNull);
  });
}
