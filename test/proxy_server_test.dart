import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/audio_cache/audio_cache.dart';
import 'package:fluxwave/core/audio_cache/cache_store.dart';
import 'package:fluxwave/core/audio_cache/proxy_server.dart';
import 'package:fluxwave/core/player/song_url.dart';
import 'package:fluxwave/models/song.dart';

/// 本地假 CDN：支持 Range，统计请求次数以便断言「命中后不再回源」。
class _FakeCdn {
  _FakeCdn(this.data);

  final List<int> data;
  late HttpServer _server;
  int requests = 0;
  bool supportRange = true;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() async => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    requests++;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null && supportRange) {
      final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      if (m != null) {
        final start = int.parse(m.group(1)!);
        final endText = m.group(2);
        final end = (endText == null || endText.isEmpty)
            ? data.length - 1
            : int.parse(endText);
        final actualEnd = end.clamp(start, data.length - 1);
        final chunk = data.sublist(start, actualEnd + 1);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$actualEnd/${data.length}',
        );
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.contentLength = chunk.length;
        req.response.add(chunk);
        await req.response.close();
        return;
      }
    }
    req.response.statusCode = HttpStatus.ok;
    req.response.contentLength = data.length;
    req.response.add(data);
    await req.response.close();
  }
}

void main() {
  late Directory tempDir;
  late _FakeCdn cdn;
  final songData = List<int>.generate(2000, (i) => i % 251);
  // 音质档由低到高（与 SettingsProvider.qualityOptions 一致），供 bestUrlFor。
  const qualityRank = [
    'standard',
    'higher',
    'exhigh',
    'lossless',
    'hires',
    'jyeffect',
    'sky',
    'jymaster',
  ];

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('proxy_test');
    cdn = _FakeCdn(songData);
    await cdn.start();
    await AudioCache.initForTest(tempDir.path);
  });

  tearDown(() async {
    await AudioCache.resetForTest();
    await cdn.close();
    for (var i = 0; i < 5 && tempDir.existsSync(); i++) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Future<HttpClientResponse> proxyGet(
    HttpClient c,
    String key,
    String range,
  ) async {
    final req = await c.getUrl(
      Uri.parse('${AudioCacheProxy.instance.baseUrl}/$key'),
    );
    if (range.isNotEmpty) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close();
  }

  test('未命中：回源 CDN 边转发边写盘，随后命中不再回源', () async {
    final key = '1_std_mp3';
    AudioCacheStore.instance.remember(key, '${cdn.base}/file.mp3');
    final client = HttpClient();

    // 第一次请求段 [100,299]：回源，缓存同时写入。
    var res = await proxyGet(client, key, 'bytes=100-299');
    expect(res.statusCode, HttpStatus.partialContent);
    final bytes1 = <int>[];
    await for (final b in res) {
      bytes1.addAll(b);
    }
    expect(bytes1, songData.sublist(100, 300));
    expect(cdn.requests, 1);
    expect(AudioCacheStore.instance.isCached(key, 100, 300), isTrue);

    // 第二次请求同一段：应本地直读，不再打 CDN。
    res = await proxyGet(client, key, 'bytes=100-299');
    expect(res.statusCode, HttpStatus.partialContent);
    final bytes2 = <int>[];
    await for (final b in res) {
      bytes2.addAll(b);
    }
    expect(bytes2, songData.sublist(100, 300));
    expect(cdn.requests, 1, reason: '命中缓存后不应再回源');
    expect(
      res.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-299/2000',
    );

    client.close(force: true);
  });

  test('开区间 Range：回源整段并全部落盘', () async {
    final key = 'proxy-open';
    AudioCacheStore.instance.remember(key, '${cdn.base}/file.mp3');
    final client = HttpClient();

    final res = await proxyGet(client, key, 'bytes=0-');
    final bytes = <int>[];
    await for (final b in res) {
      bytes.addAll(b);
    }
    expect(bytes.length, songData.length);
    expect(AudioCacheStore.instance.isCached(key, 0, 2000), isTrue);
    expect(cdn.requests, 1);

    client.close(force: true);
  });

  test('未登记直链返回 404，不崩溃', () async {
    final client = HttpClient();
    final res = await proxyGet(client, 'nobody', '');
    expect(res.statusCode, HttpStatus.notFound);
    client.close(force: true);
  });

  test('完整缓存离线可播：无 CDN 直链也能服务（GAP-1）', () async {
    // 直接落盘整曲 + 写入 totalSize，不 remember 任何 CDN 直链。
    const key = 'offline-full';
    AudioCacheStore.instance.setTotalSize(key, songData.length);
    await AudioCacheStore.instance.write(key, 0, songData);
    expect(AudioCacheStore.instance.isComplete(key), isTrue);
    // 明确无 session URL：模拟重启后只剩磁盘缓存。
    expect(AudioCacheStore.instance.sessionUrl(key), isNull);

    final client = HttpClient();
    final res = await proxyGet(client, key, 'bytes=0-1999');
    expect(res.statusCode, HttpStatus.partialContent);
    final bytes = <int>[];
    await for (final b in res) {
      bytes.addAll(b);
    }
    expect(bytes, songData);
    // 命中后不应打 CDN（requests 保持 0）。
    expect(cdn.requests, 0, reason: '离线命中不应回源');
    client.close(force: true);
  });

  test('exactUrlFor：精确档完整命中返回代理地址+档位/编码；未完整/未缓存 null（GAP-2）', () async {
    // 完整缓存：按歌曲（音源+id）精确的档位 key 命中。
    AudioCacheStore.instance.setTotalSize(
      'netease_77_standard_mp3',
      songData.length,
    );
    await AudioCacheStore.instance.write(
      'netease_77_standard_mp3',
      0,
      songData,
    );

    // 精确命中（standard）：带回缓存 key 里的档位/编码（供 UI 音质栏展示）。
    final hit = AudioCache.exactUrlFor(
      const Song(id: 77, name: 'full'),
      level: 'standard',
    )!;
    expect(hit.url, startsWith('http://127.0.0.1:'));
    expect(hit.url, contains('77_standard_mp3'));
    expect(hit.level, 'standard');
    expect(hit.type, 'mp3');
    // 未登记码率时 br 为 0。
    expect(hit.br, 0);

    // 登记码率后，命中返回的 br 如实带回（离线音质栏显示 kbps）。
    await AudioCacheStore.instance.setBr('netease_77_standard_mp3', 128000);
    expect(
      AudioCache.exactUrlFor(
        const Song(id: 77, name: 'full'),
        level: 'standard',
      )!.br,
      128000,
    );
    expect(
      AudioCache.bestUrlFor(
        const Song(id: 77, name: 'full'),
        rank: qualityRank,
      )!.br,
      128000,
    );

    // 档位不精确（缓存里只有 standard，请求 lossless）→ 不命中。
    expect(
      AudioCache.exactUrlFor(
        const Song(id: 77, name: 'full'),
        level: 'lossless',
      ),
      isNull,
    );

    // 只缓存一段（未完整）→ 不应离线命中。
    AudioCacheStore.instance.setTotalSize(
      'netease_88_std_mp3',
      songData.length,
    );
    await AudioCacheStore.instance.write(
      'netease_88_std_mp3',
      0,
      songData.sublist(0, 100),
    );
    expect(
      AudioCache.exactUrlFor(
        const Song(id: 88, name: 'partial'),
        level: 'standard',
      ),
      isNull,
    );
    expect(
      AudioCache.bestUrlFor(
        const Song(id: 88, name: 'partial'),
        rank: qualityRank,
      ),
      isNull,
    );

    // 完全没缓存。
    expect(
      AudioCache.exactUrlFor(
        const Song(id: 99, name: 'none'),
        level: 'standard',
      ),
      isNull,
    );
    expect(
      AudioCache.bestUrlFor(
        const Song(id: 99, name: 'none'),
        rank: qualityRank,
      ),
      isNull,
    );
  });

  test('bestUrlFor：按档位序取最高完整档；exactUrlFor 仅精确档（GAP-4）', () async {
    // 同一首歌同时缓存了低档（std/mp3）与高档（hires/flac）完整档。
    AudioCacheStore.instance.setTotalSize(
      'netease_66_std_mp3',
      songData.length,
    );
    await AudioCacheStore.instance.write('netease_66_std_mp3', 0, songData);
    AudioCacheStore.instance.setTotalSize(
      'netease_66_hires_flac',
      songData.length,
    );
    await AudioCacheStore.instance.write('netease_66_hires_flac', 0, songData);

    // 兜底：取档位最高的完整档 → hires。
    final best = AudioCache.bestUrlFor(
      const Song(id: 66, name: 'hi'),
      rank: qualityRank,
    )!;
    expect(best.url, contains('66_hires_flac'));
    expect(best.level, 'hires');
    expect(best.type, 'flac');

    // 精确命中：hires 档存在完整缓存 → 命中 hires。
    final exact = AudioCache.exactUrlFor(
      const Song(id: 66, name: 'hi'),
      level: 'hires',
    )!;
    expect(exact.url, contains('66_hires_flac'));

    // 精确命中：请求未缓存的档（lossless）→ 不命中（不在此降档）。
    expect(
      AudioCache.exactUrlFor(const Song(id: 66, name: 'hi'), level: 'lossless'),
      isNull,
    );
  });

  test('routeUrl：非试听走代理并登记（含码率）；试听走原 CDN 不登记', () async {
    final url = await AudioCache.routeUrl(
      const Song(id: 7, name: 'a'),
      const SongUrlResult(url: 'http://cdn/7.mp3', br: 320000),
    );
    expect(url, startsWith('http://127.0.0.1:'));
    expect(
      AudioCacheStore.instance.sessionUrl('netease_7_std_mp3'),
      'http://cdn/7.mp3',
    );
    // 在线解析拿到的码率随 routeUrl 后台登记进条目，供离线命中回读。
    await Future<void>.delayed(Duration.zero); // 让串行链上的登记投递完成
    expect(AudioCacheStore.instance.entry('netease_7_std_mp3')!.br, 320000);

    final trialUrl = await AudioCache.routeUrl(
      const Song(id: 8, name: 'b'),
      const SongUrlResult(
        url: 'https://cdn/trial.mp3',
        isTrial: true,
        br: 96000,
      ),
    );
    expect(trialUrl, 'https://cdn/trial.mp3');
    // 试听不进缓存：不登记直链也不登记码率。
    expect(AudioCacheStore.instance.entry('netease_8_std_mp3'), isNull);
    expect(AudioCacheStore.instance.sessionUrl('netease_8_std_mp3'), isNull);
  });

  test('ready 与 keyFor', () {
    expect(AudioCache.ready, isTrue);
    expect(
      AudioCache.keyFor(
        const Song(id: 9, name: 'x'),
        const SongUrlResult(url: ''),
      ),
      'netease_9_std_mp3',
    );
  });

  test('上游不支持 Range（200 整首直下）：完整流式落盘、离线命中、整曲完整', () async {
    cdn.supportRange = false; // 强制走 HttpStatus.ok 分支（_streamWhole 路径）
    final key = '3_std_mp3';
    AudioCacheStore.instance.remember(key, '${cdn.base}/file.mp3');
    final client = HttpClient();

    final res = await proxyGet(client, key, 'bytes=0-');
    expect(res.statusCode, HttpStatus.partialContent);
    final bytes = <int>[];
    await for (final b in res) {
      bytes.addAll(b);
    }
    expect(bytes, songData, reason: '整首应从 CDN 完整取回');

    // 每段都落盘 → 整曲完整。
    expect(AudioCacheStore.instance.isComplete(key), isTrue);
    expect(AudioCacheStore.instance.entry(key)!.totalSize, songData.length);

    // 命中后不再打 CDN（requests 保持 1）。
    expect(cdn.requests, 1, reason: '命中后不应再次回源');
    client.close(force: true);
  });
}
