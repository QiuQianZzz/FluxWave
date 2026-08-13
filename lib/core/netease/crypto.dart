import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashlib;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:pointycastle/api.dart';

import 'config.dart';

/// 加密工具集：AES / RSA(裸) / MD5 / HMAC / weapi / eapi / linuxapi。
/// 便于交叉验证。

final Random _rng = Random.secure();

/// 生成 n 个随机字节。
List<int> randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// 生成 n 位 base62 随机字符串(用作 weapi 的 secretKey)。
String randomBase62(int n) {
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(kBase62[_rng.nextInt(kBase62.length)]);
  }
  return sb.toString();
}

/// 字节 -> 小写 hex。
String encodeHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// hex -> 字节。
List<int> decodeHex(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}

/// MD5 小写 hex。
String md5Hex(List<int> data) => hashlib.md5.convert(data).toString();

/// HMAC-SHA256 原始字节。
List<int> hmacSha256(List<int> key, List<int> data) =>
    hashlib.Hmac(hashlib.sha256, key).convert(data).bytes;

/// ---- AES-CBC (PKCS7) 加密/解密 ----
Uint8List aesCbcEncrypt(List<int> plain, List<int> key, {List<int>? iv}) {
  final c = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
  final ivl = Uint8List.fromList(iv ?? utf8.encode(kIv));
  c.init(
    true,
    PaddedBlockCipherParameters(
      ParametersWithIV<KeyParameter>(
        KeyParameter(Uint8List.fromList(key)),
        ivl,
      ),
      null,
    ),
  );
  return c.process(Uint8List.fromList(plain));
}

Uint8List aesCbcDecrypt(List<int> cipher, List<int> key, List<int> iv) {
  final c = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
  c.init(
    false,
    PaddedBlockCipherParameters(
      ParametersWithIV<KeyParameter>(
        KeyParameter(Uint8List.fromList(key)),
        Uint8List.fromList(iv),
      ),
      null,
    ),
  );
  return c.process(Uint8List.fromList(cipher));
}

/// AES-ECB (PKCS7) 加密，返回字节。
Uint8List aesEcbEncrypt(List<int> plain, List<int> key) {
  final c = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()));
  c.init(
    true,
    PaddedBlockCipherParameters(KeyParameter(Uint8List.fromList(key)), null),
  );
  return c.process(Uint8List.fromList(plain));
}

/// AES-ECB (PKCS7) 解密，返回字节。
Uint8List aesEcbDecrypt(List<int> cipher, List<int> key) {
  final c = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()));
  c.init(
    false,
    PaddedBlockCipherParameters(KeyParameter(Uint8List.fromList(key)), null),
  );
  return c.process(Uint8List.fromList(cipher));
}

/// ---- RSA(裸模幂)：明文左侧补 0 到 128 字节 ----
BigInt? _modulus, _exponent;

void _loadRsaKey() {
  if (_modulus != null) return;
  final b64 = kPublicKeyPem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll(RegExp(r'\s'), '');
  final der = base64Decode(b64);
  // 遍历 DER，取整型 INTEGER(0x02)，最长为模数、短的为指数。
  BigInt? mod, exp;
  var i = 0;
  while (i < der.length) {
    final tag = der[i];
    if (tag == 0x02) {
      var l = der[i + 1];
      var h = i + 2;
      if (l == 0x81) {
        l = der[i + 2];
        h = i + 3;
      } else if (l == 0x82) {
        l = (der[i + 2] << 8) | der[i + 3];
        h = i + 4;
      }
      final data = der.sublist(h, h + l);
      var n = BigInt.zero;
      for (final b in data) {
        n = (n << 8) | BigInt.from(b);
      }
      if (data.length >= 100) {
        mod = n;
      } else {
        exp = n;
      }
      i = h + l;
    } else {
      i++;
    }
  }
  _modulus = mod;
  _exponent = exp;
  if (_modulus == null || _exponent == null) {
    throw ArgumentError('无效的 RSA 公钥：未能从 PEM 解析出完整模数/指数');
  }
}

/// 把字符串做裸 RSA 模幂并输出小写 hex(恰 128 字节=256 hex)。
String rsaEncryptRaw(String text) {
  _loadRsaKey();
  final msg = utf8.encode(text);
  final padded = Uint8List(128);
  padded.setRange(128 - msg.length, 128, msg);
  var m = BigInt.zero;
  for (final b in padded) {
    m = (m << 8) | BigInt.from(b);
  }
  final c = m.modPow(_exponent!, _modulus!);
  return c.toRadixString(16).padLeft(256, '0');
}

String _reverse(String s) => s.split('').reversed.join();

/// ==== 各协议的加解密 ====

/// weapi：双 AES-CBC + 裸 RSA 加密随机密钥。
/// 注意：参考实现中，第 1 层输出的是 **base64 字符串**，第 2 层再加密该 base64
/// 串的 UTF-8 字节（不是加密第 1 层的原始密文）。`params` base64 编码后即 CU 层密文。
Map<String, String> weapi(Map<String, Object> data) {
  final secretKey = randomBase62(16); // 16 字符
  final enc1 = aesCbcEncrypt(
    utf8.encode(jsonEncode(data)),
    utf8.encode(kPresetKey),
    iv: utf8.encode(kIv),
  );
  final firstB64 = base64Encode(enc1); // 参考 aesEncrypt 默认输出 base64
  final params = aesCbcEncrypt(
    utf8.encode(firstB64),
    utf8.encode(secretKey),
    iv: utf8.encode(kIv),
  );
  final encSecKey = rsaEncryptRaw(_reverse(secretKey));
  return {'params': base64Encode(params), 'encSecKey': encSecKey};
}

/// linuxapi 加密。hex 大小写服务端不区分；这里用小写（大写不影响正确性）。
Map<String, String> linuxapi(Map<String, Object> data) {
  final e = aesEcbEncrypt(
    utf8.encode(jsonEncode(data)),
    utf8.encode(kLinuxApiKey),
  );
  return {'eparams': encodeHex(e)};
}

/// eapi 加密：MD5 签名 + AES-ECB hex(大写)。[uri] 需为 /api/ 路径。
String eapi(String uri, Map<String, Object> data) {
  final text = jsonEncode(data);
  final message = 'nobody${uri}use${text}md5forencrypt';
  final digest = md5Hex(utf8.encode(message));
  final payload = '$uri-36cd479b6b5-$text-36cd479b6b5-$digest';
  final enc = aesEcbEncrypt(utf8.encode(payload), utf8.encode(kEapiKey));
  return encodeHex(enc).toUpperCase();
}

/// eapi 响应解密(Hex) -> JSON 对象。
Object? eapiResDecrypt(String hex) {
  try {
    final dec = aesEcbDecrypt(decodeHex(hex), utf8.encode(kEapiKey));
    return jsonDecode(utf8.decode(dec));
  } catch (_) {
    return null;
  }
}

/// eapi 请求体解密 -> (url, data)。
(Map<String, String>, Object?)? eapiReqDecrypt(String hex) {
  try {
    final text = utf8.decode(
      aesEcbDecrypt(decodeHex(hex), utf8.encode(kEapiKey)),
    );
    final m = RegExp(
      r'(.*?)-36cd479b6b5-(.*?)-36cd479b6b5-(.*)',
    ).firstMatch(text);
    if (m == null) return null;
    return (<String, String>{'url': m.group(1)!}, jsonDecode(m.group(2)!));
  } catch (_) {
    return null;
  }
}
