import 'dart:io';
import 'dart:typed_data';

import '../logging/app_log.dart';
import 'cache_store.dart';

/// 本地音频缓存代理。
///
/// 播放器（just_audio）播的不是 CDN 直链，而是 `http://127.0.0.1:<port>/<key>`。
/// 代理收到 Range 请求后：
/// - 命中缓存段 → 直接读本地文件回 206（离线可播、零网络）；
/// - 未命中 → 用 `CacheStore.sessionUrl(key)` 的 CDN 直链发同样的 Range 回源，
///   一边流回播放器、一边按字节偏移写进缓存。
///
/// 不新增任何接口：回源请求与播放器原本对 CDN 的请求完全同构（同 URL、同 Range）。
/// 全 best-effort：代理内部失败只回 4xx/5xx，绝不抛到 Dart 调用方。
class AudioCacheProxy {
  AudioCacheProxy._();

  static final AudioCacheProxy instance = AudioCacheProxy._();

  HttpServer? _server;
  bool _started = false;

  /// 代理端口（未启动为 null）。
  int? get port => _server?.port;

  /// 代理根 URL（未启动为 null）。
  String? get baseUrl =>
      _server == null ? null : 'http://127.0.0.1:${_server!.port}';

  /// 某 key 的代理地址（供播放器 setUrl）。
  String urlFor(String key) => '${baseUrl!}/$key';

  /// 启动代理（127.0.0.1 随机端口）。幂等；失败静默置为未启动。
  static Future<void> start() async {
    final proxy = instance;
    if (proxy._started) return;
    proxy._started = true;
    try {
      proxy._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy._server!.listen(proxy._handle);
    } catch (e, st) {
      AppLog.warn('音频缓存代理启动失败', tag: 'audio_cache', error: e, stack: st);
      proxy._server = null;
    }
  }

  /// 关闭代理（测试/退出）。
  static Future<void> stop() async {
    final proxy = instance;
    proxy._started = false;
    await proxy._server?.close(force: true);
    proxy._server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final key = _keyFromPath(req.uri.path);
      if (key == null) {
        _reply(req.response, 404, 'bad path');
        return;
      }
      if (req.method == 'HEAD') {
        _reply(req.response, 200, null);
        return;
      }
      if (req.method != 'GET') {
        _reply(req.response, 405, 'method not allowed');
        return;
      }
      // 命中优先：完整/部分缓存都能直接回，不需要 CDN 直链（离线可播）。
      // 仅当该段未命中、确需回源时才会去拿 session CDN URL。
      final cdnUrl = AudioCacheStore.instance.sessionUrl(key);
      await _serve(req, key, cdnUrl);
    } catch (e, st) {
      AppLog.error('音频缓存代理异常', tag: 'audio_cache', error: e, stack: st);
      try {
        _reply(req.response, 500, 'proxy error');
      } catch (_) {}
    }
  }

  String? _keyFromPath(String path) {
    final seg = path.split('/').where((s) => s.isNotEmpty).toList();
    if (seg.isEmpty) return null;
    return seg.last;
  }

  Future<void> _serve(HttpRequest req, String key, String? cdnUrl) async {
    final range = _parseRange(req.headers.value('range'));
    final start = range?.start ?? 0;
    final requestedEnd = range?.end; // 含端点，null = 开区间

    // 命中：读本地直接回。store 的区间是 [start,end) 排他，而 Range 的 end 含端点。
    final total = _entryTotal(key, start, requestedEnd);
    if (total != null) {
      // 闭合区间 end+1 转排他；开区间用 total（=文件长度）。
      final end = requestedEnd == null ? total : requestedEnd + 1;
      if (AudioCacheStore.instance.isCached(key, start, end)) {
        final data = await AudioCacheStore.instance.read(key, start, end);
        if (data != null) {
          _replyBytes(req.response, key, data, start, total);
          return;
        }
      }
    }

    // 未命中：需回源 CDN。若没有可用的 CDN 直链（未登记/已过期，且无缓存
    // 覆盖），只能 404 —— 不崩溃，等下次播放重新登记直链。
    if (cdnUrl == null) {
      _reply(req.response, 404, 'not registered');
      return;
    }

    await _fetchAndWrite(req, key, cdnUrl, start, requestedEnd);
  }

  int? _entryTotal(String key, int start, int? requestedEnd) {
    final e = AudioCacheStore.instance.entry(key);
    if (e == null) return null;
    final total = e.totalSize;
    if (total > 0) return total;
    // 无 total：用请求端推测（仅当用户给了闭合区间）。
    if (requestedEnd != null && requestedEnd >= start) {
      return requestedEnd + 1;
    }
    return null;
  }

  Future<void> _fetchAndWrite(
    HttpRequest req,
    String key,
    String cdnUrl,
    int start,
    int? requestedEnd,
  ) async {
    final client = _newHttpClient();
    var started = false;
    try {
      // 不回源压缩：缓存必须存原始字节，offset 才与文件一致。
      client.autoUncompress = false;
      final upstream = await client.getUrl(Uri.parse(cdnUrl));
      upstream.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      upstream.headers.set(
        HttpHeaders.rangeHeader,
        requestedEnd == null ? 'bytes=$start-' : 'bytes=$start-$requestedEnd',
      );
      final res = await upstream.close();
      if (res.statusCode != HttpStatus.partialContent) {
        if (res.statusCode == HttpStatus.ok) {
          // CDN 不支持 Range：整首流式直下并全部缓存。必须 await，否则本函数
          // 走后 finally 的 client.close(force) 会掐断 res 流，整首下到一半被截断。
          await _streamWhole(req, res, key);
          return;
        }
        _reply(req.response, res.statusCode, 'upstream ${res.statusCode}');
        return;
      }
      final cr = res.headers.value(HttpHeaders.contentRangeHeader);
      final parsed = cr == null ? null : _parseContentRange(cr);
      final total = parsed?.total ?? 0;
      final actualStart = parsed?.start ?? start;
      // 上游实际送达的末端（含端点）：EOF 提前时可能小于请求的 requestedEnd。
      final servedEnd =
          parsed?.end ?? requestedEnd ?? (total > 0 ? total - 1 : start);
      if (total > 0) {
      // 内容校验：同 key 已缓存内容与远端 total 不一致（重转码/改码）则
      // 废弃旧缓存，回源重写。
        final existing = AudioCacheStore.instance.entry(key);
        if (existing != null &&
            existing.totalSize > 0 &&
            existing.totalSize != total) {
          await AudioCacheStore.instance.invalidate(key);
        }
        AudioCacheStore.instance.setTotalSize(key, total);
      }
      final resp = req.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(HttpHeaders.contentTypeHeader, _audioType);
      // 边转发边写缓存；Content-Length 未知（流式分块），由 chunked 传输。
      // Content-Range 末端以「上游实际送达」为准（EOF 提前时总小于请求端）。
      if (total > 0) {
        resp.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $actualStart-$servedEnd/$total',
        );
      }
      var offset = actualStart;
      await for (final chunk in res) {
        await AudioCacheStore.instance.write(key, offset, chunk);
        resp.add(chunk);
        started = true;
        offset += chunk.length;
      }
      await resp.close();
    } catch (e, st) {
      AppLog.error('缓存回源失败', tag: 'audio_cache', error: e, stack: st);
      // 响应已提交（已 add 过字节）时不能改状态码/写 body，只能终止流，
      // 否则播放器收到 206 后永远等不到结束（连接挂死）。
      try {
        if (started) {
          await req.response.close();
        } else {
          _reply(req.response, 502, 'upstream error');
        }
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _streamWhole(
    HttpRequest req,
    HttpClientResponse res,
    String key,
  ) async {
    var started = false;
    try {
      final length =
          int.tryParse(
            res.headers.value(HttpHeaders.contentLengthHeader) ?? '',
          ) ??
          -1;
      final resp = req.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(HttpHeaders.contentTypeHeader, _audioType);
      if (length >= 0) {
        resp.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-${length - 1}/$length',
        );
      }
      if (length >= 0) {
        AudioCacheStore.instance.setTotalSize(key, length);
      }
      var offset = 0;
      await for (final chunk in res) {
        await AudioCacheStore.instance.write(key, offset, chunk);
        resp.add(chunk);
        started = true;
        offset += chunk.length;
      }
      // 无 Content-Length 时用实际累计长度登记 totalSize，否则 isComplete
      // 永远判假、重启后无法离线短路。
      AudioCacheStore.instance.setTotalSize(key, offset);
      await resp.close();
    } catch (e, st) {
      AppLog.error('缓存整曲直下失败', tag: 'audio_cache', error: e, stack: st);
      // 响应已提交（已 add 过字节）时不能改状态码/写 body，只能终止流，
      // 否则播放器收到 206 后永远等不到结束（连接挂死）。
      try {
        if (started) {
          await req.response.close();
        } else {
          _reply(req.response, 502, 'upstream error');
        }
      } catch (_) {}
    }
  }

  void _replyBytes(
    HttpResponse resp,
    String key,
    List<int> data,
    int start,
    int total,
  ) {
    if (data.isEmpty) {
      // 空命中（理论上被 isCached 挡住，防御）：直接 204 结束，避免 Content-Range
      // 出现 `bytes 0--1/..` 的非法值。
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      resp.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${total - 1}/$total',
      );
      resp.close();
      return;
    }
    resp.statusCode = HttpStatus.partialContent;
    resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    resp.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-${start + data.length - 1}/$total',
    );
    resp.contentLength = data.length;
    resp.add(Uint8List.fromList(data));
    resp.close();
  }

  void _reply(HttpResponse resp, int status, String? msg) {
    if (msg == null) {
      resp.statusCode = status;
      resp.close();
      return;
    }
    resp
      ..statusCode = status
      ..contentLength = msg.length
      ..write(msg);
    resp.close();
  }

  HttpClient _newHttpClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);

  /// 播放器请求的 Range：`bytes=start-end`（end 含）或 `bytes=start-`。
  ({int? start, int? end})? _parseRange(String? value) {
    if (value == null) return null;
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (m == null) return null;
    final s = m.group(1);
    final e = m.group(2);
    if (s == null || s.isEmpty) return null;
    return (
      start: int.parse(s),
      end: (e == null || e.isEmpty) ? null : int.parse(e),
    );
  }

  /// `Content-Range: bytes 100-199/2000` → (start, end, total)。
  ({int start, int end, int total})? _parseContentRange(String value) {
    final m = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)').firstMatch(value.trim());
    if (m == null) return null;
    return (
      start: int.parse(m.group(1)!),
      end: int.parse(m.group(2)!),
      total: int.parse(m.group(3)!),
    );
  }

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';

  static const _audioType = 'application/octet-stream';
}

/// 代理启动入口（main 初始化用）。
Future<void> startAudioCacheProxy() => AudioCacheProxy.start();

/// 代理停止入口。
Future<void> stopAudioCacheProxy() => AudioCacheProxy.stop();

/// 返回代理根 URL 或 null。
String? audioCacheBaseUrl() => AudioCacheProxy.instance.baseUrl;
