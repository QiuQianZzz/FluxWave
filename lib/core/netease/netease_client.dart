import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import '../logging/app_log.dart';
import 'config.dart';
import 'crypto.dart';
import 'cookie.dart';
import 'device.dart';
import 'netease_config.dart';
import 'request.dart';
import 'storage/netease_session_storage.dart';
import 'xeapi.dart';

/// 网易云 HTTP 客户端(Windows/Android 可用 dart:io)。
///
/// 职责：
/// 1. 用 [buildRequest] 拼出加密请求；
/// 2. 用 HttpClient 发送 application/x-www-form-urlencoded；
/// 3. 需要时解密 eapi 响应；
/// 4. 合并 set-cookie 与 xeapi 会话(若接入)。
/// 5. 若注入 [storage]，在 SESSION_MUTATING 接口成功后自动落盘。
class NeteaseClient {
  NeteaseRequestContext ctx;
  final NeteaseSessionStorage? storage;
  NeteaseClient({NeteaseRequestContext? context, this.storage})
    : ctx = context ?? NeteaseRequestContext();
  // 注意：MUSIC_A 由 /api/register/anonimous 服务端下发(见 registerAnon)，
  // 不应本地伪造。匿名态首次请求不带 anonToken。

  static const _timeout = Duration(seconds: 15);

  /// 统一 HttpClient 工厂：默认直连（绕过系统/环境代理）。直连避免 Clash 等代理把出口 IP 换成境外节点引发风控；
  /// 仅用户显式开启"使用系统代理"时才读 HTTP_PROXY/HTTPS_PROXY/NO_PROXY。
  HttpClient _createHttp() => HttpClient()
    ..connectionTimeout = _timeout
    ..findProxy = NeteaseConfig.bypassSystemProxy
        ? null
        : HttpClient.findProxyFromEnvironment;

  /// 统一请求入口。返回解密后的 body(Map)，失败抛 [NeteaseException]。
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    final prep = buildRequest(uri, data, mode, ctx: ctx, useER: useER);
    final client = ctx; // 持有上下文
    final http = _createHttp();
    try {
      final req = await http.postUrl(Uri.parse(prep.url));
      prep.headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      req.write(prep.body);
      final res = await req.close().timeout(_timeout);
      final bodyBytes = await res.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      // 吸收 set-cookie：merge 后同步 ctx.musicU/anonToken
      final setCookies = res.headers['set-cookie'];
      if (setCookies != null) mergeSetCookies(client.cookies, setCookies);
      final cookies = client.cookies;
      if (cookies.containsKey('MUSIC_U')) {
        final mu = cookies['MUSIC_U'];
        if (mu != null && mu.isNotEmpty) client.musicU = mu;
      } else if (client.musicU != null) {
        client.musicU = null;
      }
      if (cookies.containsKey('MUSIC_A')) {
        final ma = cookies['MUSIC_A'];
        if (ma != null && ma.isNotEmpty) client.anonToken = ma;
      } else if (client.anonToken != null) {
        client.anonToken = null;
      }

      Object? parsed;
      if (prep.needDecrypt) {
        final hex = bodyBytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase();
        parsed = eapiResDecrypt(hex);
      } else {
        try {
          parsed = jsonDecode(utf8.decode(bodyBytes));
        } catch (_) {
          parsed = null;
        }
      }
      if (parsed is Map<String, dynamic>) {
        // 会话落盘属副作用：失败不影响本次已成功的请求结果，仅记日志，
        // 不把它误分类为网络故障（否则下游会把存储错误当"跳过源"）。
        try {
          await persistIfMutating(this, storage, uri, parsed);
        } catch (e, st) {
          AppLog.warn('会话持久化失败：$uri', tag: 'netease', error: e, stack: st);
        }
      }
      return parsed;
    } catch (e, st) {
      final detail = NeteaseException.describeNetworkCause(e);
      AppLog.warn(
        detail != null ? '接口请求失败（$detail）：$uri' : '接口请求失败：$uri',
        tag: 'netease',
        error: e,
        stack: st,
      );
      throw NeteaseException.network(e, requestPath: uri);
    } finally {
      http.close(force: true);
    }
  }

  static final Random _rng = Random();

  /// 拉取并校验/解密 xeapi 公钥包(复刻参考 `xeapi.ts` 的 fetchPublicKey)。
  Future<XeapiPublicKeyState> fetchPublicKey() async {
    final nonce = StringBuffer();
    for (var i = 0; i < 16; i++) {
      nonce.write(_rng.nextInt(10));
    }
    final nonceStr = nonce.toString();
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final data = <String, String>{
      'appVersion': '9.1.65',
      'currentKeyVersion': '',
      'deviceId': ctx.deviceId,
      'nonce': nonceStr,
      'os': 'android',
      'requestType': 'active',
      'signature': xeapiSign(timestamp, nonceStr),
      't1': '',
      't2': '',
      'timestamp': timestamp,
      'uid': '',
    };
    final body = data.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final http = _createHttp();
    try {
      final req = await http.postUrl(
        Uri.parse('$kApiDomain/api/gorilla/anti/crawler/security/key/get'),
      );
      req.headers.set('User-Agent', kUaMap['api']!['android']!);
      req.headers.set('Content-Type', kContentTypeForm);
      req.headers.set(
        'Cookie',
        'deviceId=${Uri.encodeQueryComponent(ctx.deviceId)}',
      );
      req.write(body);
      final res = await req.close().timeout(_timeout);
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      const path = '/api/gorilla/anti/crawler/security/key/get';
      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final payload = (j['data'] ?? const {}) as Map<String, dynamic>;
      final encryptedData = payload['encryptedData'] as String?;
      final c = (j['code'] as int?) ?? -1;
      if (c != 200 || encryptedData == null) {
        throw NeteaseException.non200(
          c,
          message: 'xeapi public key request failed',
          requestPath: path,
          rawBody: j,
        );
      }
      final sig = payload['signature'] ?? '';
      if (xeapiSign((payload['timestamp'] ?? '').toString(), nonceStr) != sig) {
        throw NeteaseException(
          'xeapi public key signature mismatch',
          code: c,
          requestPath: path,
        );
      }
      return xeapiDecryptPublicKey(encryptedData);
    } finally {
      http.close(force: true);
    }
  }

  /// 确保匿名注册用稳定 deviceId：复用 ctx 现有"安装级"指纹，空才补生成一次。
  ///
  /// 幂等 + 防限流（对齐实测[2026-08]：同 deviceId 二次注册返回同一 userId，
  /// 而换新指纹快速重注册触发 400）。公钥请求须与注册请求绑定同一 deviceId。
  void ensureStableDeviceId() {
    if (ctx.deviceId.isEmpty) {
      ctx.deviceId = regenerateDeviceId();
    }
  }

  /// 注册匿名态(生成 MUSIC_A)。成功返回 true 并更新 [ctx.anonToken]。
  ///
  /// 复用稳定 deviceId（[ensureStableDeviceId]），不每次换新指纹，避免每启动=新账号
  /// 触发风控/限流。公钥请求与注册请求绑定同一 deviceId。
  Future<bool> registerAnon() async {
    ensureStableDeviceId();
    final pub = await fetchPublicKey();
    final username = registerUsername(ctx.deviceId);
    final enc = await xeapi(
      '/api/register/anonimous',
      {'username': username},
      session: XeapiSession(),
      pub: pub,
    );
    final osMap = kOsMap['android']!;
    final buildver = DateTime.now().millisecondsSinceEpoch.toString().substring(
      0,
      10,
    );
    final http = _createHttp();
    try {
      final req = await http.postUrl(
        Uri.parse('$kXeapiDomain/xeapi/register/anonimous'),
      );
      req.headers.set('User-Agent', kUaMap['api']!['android']!);
      // 与 buildRequest 同一三层逻辑（显式 realIp → 开关 → 不注入）。
      final ip = effectiveRealIp(explicit: ctx.realIp);
      if (ip.isNotEmpty) {
        req.headers.set('X-Real-IP', ip);
        req.headers.set('X-Forwarded-For', ip);
      }
      req.headers.set('X-Client-Enc-State', 'ENCRYPTED');
      req.headers.set('x-aeapi', 'true');
      req.headers.set('x-deviceid', ctx.deviceId);
      req.headers.set('x-os', 'android');
      req.headers.set('x-osver', osMap['osver']!);
      req.headers.set('x-appver', osMap['appver']!);
      req.headers.set('x-sdeviceid', ctx.deviceId);
      req.headers.set('x-buildver', buildver);
      final cookie = <String, String>{
        ...ctx.cookies,
        'deviceId': ctx.deviceId,
        'os': 'android',
        'osver': osMap['osver']!,
        'appver': osMap['appver']!,
        'buildver': buildver,
        'sDeviceId': ctx.deviceId,
      };
      req.headers.set('Cookie', cookieObjToString(cookie));
      req.headers.set('Content-Type', kContentTypeForm);
      req.write(
        enc.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&'),
      );
      final res = await req.close().timeout(_timeout);
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final setCookies = res.headers['set-cookie'];
      if (setCookies != null) mergeSetCookies(ctx.cookies, setCookies);
      final parsed = xeapiResDecrypt(bytes);
      final body = (parsed is Map<String, dynamic>) ? parsed : null;
      // code=200 即算成功，不依赖 body.token。
      // 生产现状：网易云 register/anonimous 已不在响应体中返回 token，
      // MUSIC_A 完全靠 L248 mergeSetCookies 从 set-cookie 吸收。
      if (body?['code'] == 200) {
        final token = body?['token'];
        // body 里有 token 时同步写一份（兼容旧格式 / 调试 / 海外特殊节点）
        if (token is String && token.isNotEmpty) {
          ctx.anonToken = token;
          ctx.cookies['MUSIC_A'] = token;
        }
        if (body != null) {
          await persistIfMutating(
            this,
            storage,
            '/api/register/anonimous',
            body,
          );
        }
        return true;
      }
      return false;
    } catch (e, st) {
      AppLog.warn('匿名注册请求失败', tag: 'netease', error: e, stack: st);
      throw NeteaseException.network(e, requestPath: '/api/register/anonimous');
    } finally {
      http.close(force: true);
    }
  }
}

/// 网易云接口异常（携带 code + 请求路径）。
///
/// - [code] 为服务端返回的 `body.code`（网络层错误时为 `-1`）；
/// - [requestPath] 为发生错误的接口路径（可选），便于定位；
/// - [message] 为人类可读的错误描述。
///
/// 调用方可按 `code` 程序化分支：
/// - `-1` 本地/网络错误；
/// - `429` 触发退避重试；
/// - `800` qr 过期；
/// - `50x` 服务端故障，等。
class NeteaseException implements Exception {
  final String message;
  final int code;
  final String? requestPath;

  /// 是否为瞬时网络故障（断网/DNS/超时/TLS），区别于服务端业务错误。
  /// 网络故障不应计入"连续播放失败"的跳过链，应退避重试。
  final bool isNetwork;

  /// 网络故障的具体成因描述（DNS/超时/TLS 等），非网络类错误为 null。
  String? get networkCauseDetail {
    if (!isNetwork) return null;
    final cause = _cause;
    return cause == null ? null : describeNetworkCause(cause);
  }

  /// 原始底层异常（可能为 null）。
  final Object? _cause;

  NeteaseException(
    this.message, {
    this.code = -1,
    this.requestPath,
    this.isNetwork = false,
    this._cause,
  });

  /// 网络/运行时原生错误包装（无服务端 code）。
  ///
  /// [isNetwork] 依据底层 cause 类型自动判定：Socket/Handshake/超时等
  /// 传输层异常为瞬时故障，重试可恢复；其余（如 json 解析失败）非网络问题。
  factory NeteaseException.network(
    Object cause, {
    String? requestPath,
  }) =>
      NeteaseException(
        '请求失败: $cause',
        code: -1,
        requestPath: requestPath,
        isNetwork: _isNetworkCause(cause),
        cause: cause,
      );

  static bool _isNetworkCause(Object cause) {
    if (cause is NeteaseException) return cause.isNetwork;
    if (cause is SocketException) return true;
    if (cause is TimeoutException) return true;
    if (cause is HandshakeException) return true;
    if (cause is HttpException) return true;
    // 其它传输层包装（如 HTTPSocket/回调中的嵌套异常）缺省非网络。
    return false;
  }

  /// 网络故障的具体成因描述（用于诊断日志）。
  ///
  /// 区分 DNS 解析失败 / 连接超时 / TLS 握手失败 / 连接拒绝 / HTTP 错误，
  /// 帮助判断「是否是系统挂起网络（Doze/省电）导致」还是服务器侧问题。
  /// 非网络类错误返回 null。
  static String? describeNetworkCause(Object cause) {
    if (cause is SocketException) {
      final socket = cause.osError;
      if (socket != null) {
        final code = socket.errorCode;
        if (code == 7) return 'DNS 解析失败(OS error $code)——疑似系统挂起网络(Doze/省电)';
        if (code == 8) return '连接被拒绝(OS error $code)';
        if (code == 110 || code == 60) return '连接超时(OS error $code)';
        if (code == 64 || code == 61) return '连接被拒绝/对端未监听(OS error $code)';
        if (code == 113) return '路由/网络不可达(OS error $code)';
        return '套接字错误(OS error $code): ${socket.message}';
      }
      if (cause.address != null || cause.port != null) {
        return '套接字错误(${cause.address}:${cause.port})';
      }
      return '套接字错误: ${cause.message}';
    }
    if (cause is TimeoutException) {
      return '请求超时(${cause.duration})';
    }
    if (cause is HandshakeException) {
      return 'TLS 握手失败: ${cause.message}';
    }
    if (cause is HttpException) {
      return 'HTTP 错误: ${cause.message}';
    }
    return null;
  }

  /// 服务端 body.code != 200 场景。
  factory NeteaseException.non200(
    int code, {
    String? message,
    String? requestPath,
    Object? rawBody,
  }) {
    final detail = rawBody is Map
        ? (rawBody['message']?.toString() ?? rawBody['msg']?.toString() ?? '')
        : '';
    return NeteaseException(
      message ??
          '服务端返回非 200（code=$code${detail.isNotEmpty ? ', msg=$detail' : ''}）',
      code: code,
      requestPath: requestPath,
    );
  }

  @override
  String toString() =>
      'NeteaseException[$code]'
      '${requestPath != null ? ' ($requestPath)' : ''}: $message';
}
