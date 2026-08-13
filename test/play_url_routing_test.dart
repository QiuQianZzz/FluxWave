import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/audio_cache/audio_cache.dart';
import 'package:fluxwave/core/audio_cache/cache_store.dart';
import 'package:fluxwave/core/audio_cache/proxy_server.dart';
import 'package:fluxwave/core/player/song_url.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/player_provider.dart';

/// #1 回归：离线整曲命中 → 播的就是完整 key 那串代理地址，且绝不把代理地址
/// 当 CDN 直链写进 sessionUrl（否则会话被污染、该 key 再次未命中回源会反向
/// 打代理自己 → 无限递归/500）。
void main() {
  late Directory tempDir;
  final songData = List<int>.generate(2000, (i) => i % 251);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('routing_test');
    await AudioCache.initForTest(tempDir.path);
  });

  tearDown(() async {
    await AudioCache.resetForTest();
    for (var i = 0; i < 5 && tempDir.existsSync(); i++) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  String proxyUrlFor(String key) => '${AudioCacheProxy.instance.baseUrl}/$key';

  test('离线整曲命中：直接播完整 key 的代理地址，不污染 sessionUrl', () async {
    // 完整缓存：高码率档（hires）已完整在盘。
    const key = '55_hires_flac';
    AudioCacheStore.instance.setTotalSize(key, songData.length);
    await AudioCacheStore.instance.write(key, 0, songData);

    // 播放器 resolve 给 SongUrlResult 的正是缓存命中（exactUrlFor/bestUrlFor）
    // 返回的代理地址（本测试手动构造、未带 level；真实流程会附档位/编码）。
    final result = SongUrlResult(url: proxyUrlFor(key));
    final playUrl = await resolvePlayUrl(
      const Song(id: 55, name: 'hi'),
      result,
    );

    // 不变量 1：播的就是那串完整 key 的代理地址（不再被 routeUrl 重推成别的 key）。
    expect(playUrl, proxyUrlFor(key));

    // 不变量 2：sessionUrl 未被「代理地址」污染（该 key 未登记任何 CDN 直链）。
    expect(AudioCacheStore.instance.sessionUrl(key), isNull);
  });

  test('CDN 直链（在线）：路由到代理并登记 CDN 直链', () async {
    const cdn = 'http://cdn.example.com/hi.mp3';
    final playUrl = await resolvePlayUrl(
      const Song(id: 5, name: 'a'),
      const SongUrlResult(url: cdn),
    );
    expect(playUrl, proxyUrlFor('netease_5_std_mp3'));
    expect(AudioCacheStore.instance.sessionUrl('netease_5_std_mp3'), cdn);
  });

  test('试听：直接播原 CDN，不入缓存', () async {
    const url = 'http://cdn.example.com/trial.mp3';
    final playUrl = await resolvePlayUrl(
      const Song(id: 6, name: 't'),
      const SongUrlResult(url: url, isTrial: true),
    );
    expect(playUrl, url);
    expect(AudioCacheStore.instance.sessionUrl('netease_6_std_mp3'), isNull);
  });

  test('无歌：直接播原 URL，不入缓存', () async {
    const url = 'http://cdn.example.com/7.mp3';
    final playUrl = await resolvePlayUrl(null, const SongUrlResult(url: url));
    expect(playUrl, url);
    expect(AudioCacheStore.instance.sessionUrl('netease_7_std_mp3'), isNull);
  });
}
