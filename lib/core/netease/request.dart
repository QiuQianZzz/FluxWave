library;

import 'dart:math';

import 'config.dart';
import 'cookie.dart';
import 'crypto.dart';
import 'device.dart';
import 'netease_config.dart';

enum NeteaseMode { weapi, linuxapi, eapi, api, xeapi }

/// 请求上下文：设备指纹、会话 cookie、平台伪装等。
class NeteaseRequestContext {
  String deviceId;
  String osKey; // pc / android / iphone / osx / linux
  Map<String, String> cookies;
  String? realIp;
  String? anonToken; // MUSIC_A 匿名令牌
  String? musicU; // MUSIC_U 登录令牌

  NeteaseRequestContext({
    String? deviceId,
    this.osKey = 'pc',
    Map<String, String>? cookies,
    this.realIp,
    this.anonToken,
    this.musicU,
  }) : deviceId = deviceId ?? generateDeviceId(),
       cookies = cookies ?? {};
}

/// 组装好的请求。
class PreparedRequest {
  final String url;
  final Map<String, String> headers;
  final String body; // application/x-www-form-urlencoded
  final bool needDecrypt; // 响应体是否需要 AES 解密
  const PreparedRequest({
    required this.url,
    required this.headers,
    required this.body,
    this.needDecrypt = false,
  });
}

/// 由 /api/xxx 取接口名（去掉前 5 个字符）。
String _stripUri(String uri) => uri.startsWith('/api') ? uri.substring(5) : uri;

/// 追加设备/会话 cookie。
///
/// 生成/补齐后会把稳定字段（_ntes_nuid/WNMCID/os/appver/channel/osver/deviceId 等）
/// 回写 [ctx.cookies]，保证同一会话内 N 次请求值一致——否则每次请求都生成新的
/// `_ntes_nuid/WNMCID/_ntes_nnid`，网易云会认为"每次请求都是不同环境"触发风控。
void _fillCoreCookie(Map<String, String> c, NeteaseRequestContext ctx) {
  final osMap = kOsMap[ctx.osKey] ?? kOsMap['android']!;
  final now = DateTime.now().millisecondsSinceEpoch;
  final nuid = c['_ntes_nuid'] ?? encodeHex(randomBytes(16));
  final wnmcid = c['WNMCID'] ?? generateWnmcId();
  c['__remember_me'] = 'true';
  c['ntes_kaola_ad'] = '1';
  c['_ntes_nuid'] = nuid;
  c['_ntes_nnid'] = c['_ntes_nnid'] ?? '$nuid,$now';
  c['WNMCID'] = wnmcid;
  c['WEVNSM'] = '1.0.0';
  c['osver'] = osMap['osver']!;
  c['deviceId'] = ctx.deviceId;
  c['os'] = osMap['os']!;
  c['channel'] = osMap['channel']!;
  c['appver'] = osMap['appver']!;
  // NMTID 每次请求换 8 字节
  c['NMTID'] = encodeHex(randomBytes(8));

  // 只有没有 MUSIC_U 时才补 MUSIC_A（优先 MUSIC_U）
  if (ctx.musicU != null) {
    c['MUSIC_U'] = ctx.musicU!;
    c.remove('MUSIC_A');
  } else if (ctx.anonToken != null) {
    c['MUSIC_A'] ??= ctx.anonToken!;
  }

  // 把稳定字段回写到 ctx.cookies，下次请求直接复用
  ctx.cookies['_ntes_nuid'] = nuid;
  ctx.cookies['_ntes_nnid'] = c['_ntes_nnid']!;
  ctx.cookies['WNMCID'] = wnmcid;
  ctx.cookies['WEVNSM'] = '1.0.0';
  ctx.cookies['osver'] = osMap['osver']!;
  ctx.cookies['deviceId'] = ctx.deviceId;
  ctx.cookies['os'] = osMap['os']!;
  ctx.cookies['channel'] = osMap['channel']!;
  ctx.cookies['appver'] = osMap['appver']!;
  // 同步 MUSIC_U/MUSIC_A 回 ctx（保证状态机一致）
  if (c['MUSIC_U'] != null) {
    ctx.cookies['MUSIC_U'] = c['MUSIC_U']!;
  } else {
    ctx.cookies.remove('MUSIC_U');
  }
  if (c['MUSIC_A'] != null) {
    ctx.cookies['MUSIC_A'] = c['MUSIC_A']!;
  } else {
    ctx.cookies.remove('MUSIC_A');
  }
}

/// 会话级"国内 IP"池。
/// 进程内只生成一次，同一进程的所有请求共用同一 IP，避免同会话内 IP 漂移触发风控。
const List<String> _kCnIpPrefixes = [
  '116.25',
  '121.8',
  '120.36',
  '39.144',
  '117.136',
  '223.104',
  '171.8',
  '182.140',
];

String? _cachedSessionRealIp;

/// 会话级国内 IP：进程内首次生成后缓存，同进程所有请求(含手动 xeapi
/// 请求如 registerAnon)共用，避免会话内 IP 漂移触发风控。
/// 供 [buildRequest] 及外部手动请求读取同一缓存。
String generateSessionRealIp() {
  final cached = _cachedSessionRealIp;
  if (cached != null) return cached;
  final rng = Random.secure();
  final prefix = _kCnIpPrefixes[rng.nextInt(_kCnIpPrefixes.length)];
  final third = rng.nextInt(256);
  final fourth = 1 + rng.nextInt(254);
  final ip = '$prefix.$third.$fourth';
  _cachedSessionRealIp = ip;
  return ip;
}

/// 三层语义决定请求注入的 IP（buildRequest / registerAnon 共用同一逻辑）：
///
/// 1. 显式 `explicit`（非空）→ 注入它（调用方/调试/海外显式注入赢）；
/// 2. 否则 [NeteaseConfig.enableRealIpInjection] 开启 → 会话级国内 IP；
/// 3. 否则 → 不注入（默认，对齐官方客户端从不发这两个头）。
String effectiveRealIp({String? explicit}) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (NeteaseConfig.enableRealIpInjection) return generateSessionRealIp();
  return '';
}

/// 模式 + uaType 选择 UA，不是按 cookie.os 自由组合
///
/// - weapi → weapi:pc（固定桌面 Edge/Chrome）
/// - linuxapi → linuxapi:linux（固定 Chrome 60 X11）
/// - eapi/api →  优先 caller 传 ua；否则默认 api:iphone（只有 cookie.os==='osx' 才用 OSX 桌面 UA）
/// - xeapi →  api:android
String _chooseUa(NeteaseMode mode, NeteaseRequestContext ctx) {
  switch (mode) {
    case NeteaseMode.weapi:
      return kUaMap['weapi']!['pc']!;
    case NeteaseMode.linuxapi:
      return kUaMap['linuxapi']!['linux']!;
    case NeteaseMode.xeapi:
      return kUaMap['api']!['android']!;
    case NeteaseMode.eapi:
    case NeteaseMode.api:
      // cookie.os === 'osx' ? OSX_USER_AGENT : chooseUserAgent('api','iphone')
      // OSX 走独立纯 Chrome UA（kOsxUa），不复用 weapi.pc（带 Edg/ 后缀），
      if (ctx.osKey == 'osx') return kOsxUa;
      return kUaMap['api']!['iphone']!;
  }
}

/// 依据模式拼 URL / headers / body。
PreparedRequest buildRequest(
  String uri,
  Map<String, Object> data,
  NeteaseMode mode, {
  NeteaseRequestContext? ctx,
  bool useER = kEncryptResponse,
}) {
  final c = ctx ?? NeteaseRequestContext();
  final headers = <String, String>{};
  // 三层语义：显式 realIp 优先 → 开关开(默认关, Android 硬门控)才会话级国内 IP → 否则不注入。
  // 默认不注入：官方客户端直连从不发 X-Real-IP/X-Forwarded-For。
  final ip = effectiveRealIp(explicit: c.realIp);
  if (ip.isNotEmpty) {
    headers['X-Real-IP'] = ip;
    headers['X-Forwarded-For'] = ip;
  }
  // 先做 cookie 归一化 + processCookieObject → 所有模式共用这一个 processed cookie
  final cookie = <String, String>{...c.cookies};
  _fillCoreCookie(cookie, c);
  // 登录类接口不带 NMTID（服务端要求）
  if (uri.contains('login')) cookie.remove('NMTID');
  headers['Cookie'] = cookieObjToString(cookie);

  final csrf = cookie['__csrf'] ?? '';

  Map<String, Object> encryptedBody;
  String url;
  var needDecrypt = false;

  switch (mode) {
    case NeteaseMode.weapi:
      // headers.Referer = DOMAIN
      // headers.User-Agent = chooseUserAgent('weapi')  => weapi:pc
      // data.csrf_token = csrfFrom(cookie)
      // headers.Cookie  **沿用 processCookieObject 的 cookie 字符串**（上面 L159 已写死）
      headers['Referer'] = kWebDomain;
      headers['User-Agent'] = _chooseUa(mode, c);
      final w = <String, Object>{...data, 'csrf_token': csrf, 'e_r': useER};
      encryptedBody = weapi(w);
      url = '$kWebDomain/weapi/${_stripUri(uri)}';
      // weapi + useER=true 才解密响应
      needDecrypt = useER;
      break;
    case NeteaseMode.linuxapi:
      // UA=chooseUserAgent('linuxapi','linux')，Cookie=processCookieObject 那份
      headers['User-Agent'] = _chooseUa(mode, c);
      final payload = <String, Object>{
        'method': 'POST',
        'url': '$kWebDomain$uri',
        'params': data,
      };
      encryptedBody = linuxapi(payload);
      url = '$kWebDomain/api/linux/forward';
      break;
    case NeteaseMode.eapi:
    case NeteaseMode.api:
      // 构造一个独立的 header 对象（只取 processCookieObject 里已有的 osver/deviceId/os/appver/channel 等字段）
      //   **headers.Cookie 覆盖写为这个 header 对象的字符串**（不包含 _ntes_nuid/WNMCID 等 processCookieObject 专属字段）
      //   body.header = header 对象（eapi 时写进加密 payload）
      final header = <String, Object>{
        'osver': cookie['osver']!,
        'deviceId': c.deviceId,
        'os': cookie['os']!,
        'appver': cookie['appver']!,
        'versioncode': cookie['versioncode'] ?? '140',
        'mobilename': cookie['mobilename'] ?? '',
        'buildver':
            cookie['buildver'] ??
            '${DateTime.now().millisecondsSinceEpoch}'.substring(0, 10),
        'resolution': cookie['resolution'] ?? '1920x1080',
        '__csrf': csrf,
        'channel': cookie['channel']!,
        'requestId': generateRequestId(),
      };
      // 若 cookie 中有 MUSIC_U / MUSIC_A 则一并注入 header
      if (cookie['MUSIC_U'] != null) header['MUSIC_U'] = cookie['MUSIC_U']!;
      if (cookie['MUSIC_A'] != null) header['MUSIC_A'] = cookie['MUSIC_A']!;
      headers['Cookie'] = cookieObjToString(header);
      headers['User-Agent'] = _chooseUa(mode, c);
      if (mode == NeteaseMode.eapi) {
        final payload = <String, Object>{
          ...data,
          'header': header,
          'e_r': useER,
        };
        encryptedBody = {'params': eapi(uri, payload)};
        url = '$kApiDomain/eapi/${_stripUri(uri)}';
        needDecrypt = useER;
      } else {
        encryptedBody = data;
        url = '$kApiDomain$uri';
      }
      break;
    case NeteaseMode.xeapi:
      throw UnsupportedError('xeapi 协议请先集成 X25519 会话(见 docs)');
  }

  final body = encryptedBody.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}',
      )
      .join('&');
  headers['Content-Type'] = kContentTypeForm;
  return PreparedRequest(
    url: url,
    headers: headers,
    body: body,
    needDecrypt: needDecrypt,
  );
}
