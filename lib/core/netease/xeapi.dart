/// xeapi 二期反爬：游客注册 / 部分接口。
/// 忠实复刻 S Player-Next `core/crypto.ts` 的 xeapi 段(含 buildXeapiPlaintext)。
/// 端点/UA 等见 `xeapiFetch.ts` / `request.ts`。
///
/// 说明：
/// - 依赖 config 的 [kXeapiStaticKey](AES-256-ECB) 与 [kXeapiSignKey](HMAC 签名)。
/// - X25519 + AES-128-GCM 用 `cryptography` 纯 Dart 实现(Windows/Android 可用)。
/// - 网易会更新协议；失效请对照参考 `crypto.ts`/`xeapi.ts` 核对。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cxp;

import 'config.dart';
import 'crypto.dart';

/// xeapi 会话：响应头 `x-encr-ssid` / `x-encr-sskey` 回传。
class XeapiSession {
  String sessionId = '';
  String sessionKey = '';
}

/// 反爬公钥状态(解密 `/security/key/get` 的 encryptedData 得到)。
class XeapiPublicKeyState {
  String version = '';
  String publicKey = ''; // 32 字节 X25519 公钥(base64)
  String? sk;

  bool get valid =>
      version.isNotEmpty &&
      publicKey.isNotEmpty &&
      base64Decode(publicKey).length == 32;
}

/// 签名：HMAC-SHA256(kXeapiSignKey, ts+nonce) -> base64。
/// signKey 直接用字符串 UTF-8 字节(不对 base64 解码)。
String xeapiSign(String ts, String nonce) =>
    base64Encode(hmacSha256(kXeapiSignKey, utf8.encode('$ts$nonce')));

/// 解密 `/api/gorilla/anti/crawler/security/key/get` 的 `encryptedData`。
XeapiPublicKeyState xeapiDecryptPublicKey(String encryptedData) {
  final dec = aesEcbDecrypt(base64Decode(encryptedData), kXeapiStaticKey);
  final j = jsonDecode(utf8.decode(dec)) as Map<String, dynamic>;
  return XeapiPublicKeyState()
    ..version = (j['version'] ?? '').toString()
    ..publicKey = (j['publicKey'] ?? '').toString()
    ..sk = j['sk']?.toString();
}

/// 中间层变换：随机 XOR + base64 + 旋转(与 `xeapiMidTransform` 一致)。
Uint8List _midTransform(List<int> ciphertext) {
  final random = randomBytes(16);
  final xored = List<int>.generate(
    ciphertext.length,
    (i) => ciphertext[i] ^ random[i & 0x0f],
  );
  final b64 = utf8.encode(base64Encode(Uint8List.fromList(xored)));
  final rot = b64.isEmpty ? 0 : (random[0] & 0x0f) % b64.length;
  final out = Uint8List(16 + b64.length);
  out.setRange(0, 16, random);
  out.setRange(16, 16 + b64.length - rot, b64.sublist(rot));
  out.setRange(16 + b64.length - rot, out.length, b64.sublist(0, rot));
  return out;
}

/// 仿 `URLSearchParams.toString()`：application/x-www-form-urlencoded，
/// 空格编码为 `+`(与 Node 一致)。
String _form(Map<String, Object> data) => data.entries
    .map(
      (e) =>
          '${Uri.encodeQueryComponent(e.key).replaceAll('%20', '+')}='
          '${Uri.encodeQueryComponent(e.value.toString()).replaceAll('%20', '+')}',
    )
    .join('&');

/// 构造 xeapi 明文 JSON(字段：body / queryString 等)。
String _buildPlaintext(
  String uri,
  Map<String, Object> data, {
  String method = 'POST',
  String? contentType,
}) {
  final fields = <String, String>{};
  final ct = contentType ?? kContentTypeFormWithCharset;
  if (ct.split(';').first.trim().toLowerCase() != kContentTypeForm) {
    fields['contentType'] = ct;
  }
  final m = method.toUpperCase();
  if (m != 'POST') fields['method'] = m;
  final qIdx = uri.indexOf('?');
  final qs = qIdx >= 0 ? uri.substring(qIdx + 1) : '';
  if (data.isNotEmpty) {
    final body = <String, Object>{...data}..remove('e_r');
    fields['body'] = base64Encode(utf8.encode(_form(body)));
  }
  fields['queryString'] = qs.isEmpty ? 'e_r=true' : '$qs&e_r=true';
  return jsonEncode(fields);
}

/// 由共享密钥派生 AES-GCM 密钥(HKDF 风格，HMAC 两次，取前 16 字节)。
List<int> _deriveAesKey(List<int> shared, List<int> ephRaw) {
  final prk = hmacSha256(Uint8List(32), shared);
  final box = hmacSha256(prk, Uint8List.fromList([...ephRaw, 0x01]));
  return box.sublist(0, 16);
}

/// X25519 ECDH + AES-128-GCM 封装 dynamicKey -> [ephRaw32][iv12][ct][tag16]。
Future<Uint8List> _encryptS(
  Uint8List dynamicKey,
  XeapiPublicKeyState pub,
  String os,
) async {
  final xc = cxp.X25519();
  final keyPair = await xc.newKeyPair();
  final pubKey = await keyPair.extractPublicKey();
  final ephRaw = pubKey.bytes; // X25519 原始 32 字节(等价 spki 尾部)

  final shared = await xc.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: cxp.SimplePublicKey(
      base64Decode(pub.publicKey),
      type: cxp.KeyPairType.x25519,
    ),
  );
  final sharedBytes = await shared.extractBytes();

  final aesKey = _deriveAesKey(sharedBytes, ephRaw);
  final iv = randomBytes(12);
  final plain = utf8.encode('${base64Encode(dynamicKey)}|$os|${pub.sk ?? ''}');
  final gcm = cxp.AesGcm.with128bits();
  final box = await gcm.encrypt(
    plain,
    secretKey: cxp.SecretKey(aesKey),
    nonce: iv,
  );

  final out = Uint8List(32 + 12 + box.cipherText.length + 16);
  out.setRange(0, 32, ephRaw);
  out.setRange(32, 44, iv);
  out.setRange(44, 44 + box.cipherText.length, box.cipherText);
  out.setRange(44 + box.cipherText.length, out.length, box.mac.bytes);
  return out;
}

/// 构造并发 B / S / R 三段(base64)。
///
/// [uri] 形如 `/api/xxx`。[session] 为回传的会话；[pub] 为公钥状态。
/// 首个请求 session 为空 -> dynamicKey 随机；此后复用响应头会话。
Future<Map<String, String>> xeapi(
  String uri,
  Map<String, Object> data, {
  required XeapiSession session,
  required XeapiPublicKeyState pub,
  String os = 'android',
  String method = 'POST',
  String? contentType,
}) async {
  final hasSession = session.sessionKey.isNotEmpty;
  final dynamicKey = hasSession
      ? Uint8List.fromList(utf8.encode(session.sessionKey))
      : Uint8List.fromList(randomBytes(16));

  final plaintext = _buildPlaintext(
    uri,
    data,
    method: method,
    contentType: contentType,
  );
  // B = AES-ECB(dynamicKey, mid(AES-ECB(static, plaintext)))
  final b = aesEcbEncrypt(
    _midTransform(aesEcbEncrypt(utf8.encode(plaintext), kXeapiStaticKey)),
    dynamicKey,
  );
  // S = X25519 ECDH + AES-128-GCM 封装 dynamicKey
  final s = await _encryptS(dynamicKey, pub, os);
  // R = AES-ECB(static, version|activeSessionId)
  final r = aesEcbEncrypt(
    utf8.encode('${pub.version}|${hasSession ? session.sessionId : ''}'),
    kXeapiStaticKey,
  );

  return {'B': base64Encode(b), 'S': base64Encode(s), 'R': base64Encode(r)};
}

/// xeapi 响应解密：AES-ECB(eapiKey) 再可选 gunzip -> JSON。
Object? xeapiResDecrypt(List<int> body) {
  try {
    final dec = aesEcbDecrypt(body, utf8.encode(kEapiKey));
    final plain = (dec.length >= 2 && dec[0] == 0x1f && dec[1] == 0x8b)
        ? gzip.decode(dec)
        : dec;
    return jsonDecode(utf8.decode(plain));
  } catch (_) {
    return null;
  }
}
