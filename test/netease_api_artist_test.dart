import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';

/// 假客户端：记录调用参数并回放预设响应。
class FakeApiClient extends NeteaseClient {
  FakeApiClient()
      : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  final calls = <Map<String, Object?>>[];
  Object? response;

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    calls.add({'uri': uri, 'data': data, 'mode': mode});
    return response ?? const {'code': 404};
  }
}

void main() {
  late FakeApiClient client;
  late NeteaseApi api;

  setUp(() {
    client = FakeApiClient();
    api = NeteaseApi(client);
  });

  group('artistDetail', () {
    test('参数正确传递', () async {
      client.response = {
        'code': 200,
        'data': {
          'id': 123,
          'name': '测试歌手',
          'cover': 'http://img.com/cover.jpg',
          'avatar': 'http://img.com/avatar.jpg',
          'alias': ['别名'],
          'briefDesc': '简介',
          'musicSize': 100,
          'albumSize': 10,
          'followed': false,
        },
      };
      final r = await api.artistDetail(123);
      expect(client.calls, hasLength(1));
      expect(client.calls[0]['uri'], '/api/artist/head/info/get');
      expect(client.calls[0]['data'], {'id': 123});
      expect(client.calls[0]['mode'], NeteaseMode.api);
      expect(r['code'], 200);
    });
  });

  group('artistDynamic', () {
    test('参数正确传递', () async {
      client.response = {'code': 200, 'data': {'followerCount': 999}};
      final r = await api.artistDynamic(456);
      expect(client.calls, hasLength(1));
      expect(client.calls[0]['uri'], '/api/artist/detail/dynamic');
      expect(client.calls[0]['data'], {'id': 456});
      expect(client.calls[0]['mode'], NeteaseMode.api);
      expect(r['code'], 200);
    });
  });

  group('artistSongs', () {
    test('默认参数', () async {
      client.response = {'code': 200, 'songs': []};
      await api.artistSongs(789);
      expect(client.calls, hasLength(1));
      expect(client.calls[0]['uri'], '/api/v1/artist/songs');
      final data = client.calls[0]['data'] as Map;
      expect(data['id'], 789);
      expect(data['order'], 'hot');
      expect(data['offset'], 0);
      expect(data['limit'], 50);
      expect(data['private_cloud'], 'true');
      expect(data['work_type'], '1');
      expect(client.calls[0]['mode'], NeteaseMode.api);
    });

    test('自定义分页和排序', () async {
      client.response = {'code': 200, 'songs': []};
      await api.artistSongs(111, order: 'time', offset: 50, limit: 20);
      final data = client.calls[0]['data'] as Map;
      expect(data['order'], 'time');
      expect(data['offset'], 50);
      expect(data['limit'], 20);
    });
  });

  group('artistAlbums', () {
    test('默认参数', () async {
      client.response = {'code': 200, 'hotAlbums': []};
      await api.artistAlbums(222);
      expect(client.calls, hasLength(1));
      expect(client.calls[0]['uri'], '/api/artist/albums/222');
      final data = client.calls[0]['data'] as Map;
      expect(data['limit'], 30);
      expect(data['offset'], 0);
      expect(data['total'], 'true');
      expect(client.calls[0]['mode'], NeteaseMode.api);
    });

    test('自定义分页', () async {
      client.response = {'code': 200, 'hotAlbums': []};
      await api.artistAlbums(333, offset: 10, limit: 5);
      final data = client.calls[0]['data'] as Map;
      expect(data['limit'], 5);
      expect(data['offset'], 10);
    });
  });

  group('返回值容错', () {
    test('非 Map 响应返回空 Map', () async {
      client.response = 'not a map';
      final r = await api.artistDetail(1);
      expect(r, isEmpty);
    });
  });
}
