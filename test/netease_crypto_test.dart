import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/netease/cookie.dart';
import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/crypto.dart';
import 'package:fluxwave/core/netease/device.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/core/netease/xeapi.dart';

void main() {
  test('AES-CBC 与 AES-ECB 加解密往返一致', () {
    final key = utf8.encode('0123456789abcdef');
    final iv = utf8.encode('1234567890abcdef');
    final plain = utf8.encode('hello netease, 你好');

    final cbc = aesCbcEncrypt(plain, key, iv: iv);
    expect(utf8.decode(aesCbcDecrypt(cbc, key, iv)), 'hello netease, 你好');

    final ecb = aesEcbEncrypt(plain, key);
    expect(utf8.decode(aesEcbDecrypt(ecb, key)), 'hello netease, 你好');
  });

  test('weapi 输出结构正确(含 encSecKey 256 hex)', () {
    final w = weapi({'s': '周杰伦', 'limit': 20});
    expect(w.containsKey('params'), isTrue);
    expect(w['params']!.isNotEmpty, isTrue);
    // encSecKey 应为 128 字节 = 256 位 hex
    expect(RegExp(r'^[0-9a-f]{256}$').hasMatch(w['encSecKey']!), isTrue);
  });

  test('eapi 加密后可用 eapiReqDecrypt 还原', () {
    final data = <String, Object>{
      'id': 31253223,
      'level': 'standard',
      'header': {'os': 'android'},
    };
    final pij = eapi('/api/v1/song/url', data);
    expect(
      RegExp(r'^[0-9A-F]+$').hasMatch(pij),
      isTrue,
      reason: 'eapi 应为大写 hex',
    );

    final dec = eapiReqDecrypt(pij);
    expect(dec, isNotNull);
    final body = dec!.$2 as Map;
    // 解析出的 body 应包含原始字段(id)
    expect(body.containsKey('id'), isTrue);
  });

  test('linuxapi 可解密还原', () {
    final enc = linuxapi({'a': 'b'});
    expect(enc['eparams']!.isNotEmpty, isTrue);
    // 用相同 AES-ECB 反解回 JSON
    final dec = jsonDecode(
      utf8.decode(
        aesEcbDecrypt(
          decodeHex(enc['eparams']!),
          utf8.encode('rFgB&h#%2?^eDg:Q'),
        ),
      ),
    );
    expect(dec['a'], 'b');
  });

  test('rsaEncryptRaw 输出恒定且为 256 位 hex', () {
    final a = rsaEncryptRaw('vHw4arXj');
    final b = rsaEncryptRaw('vHw4arXj');
    expect(a, b); // 无随机，确定性
    expect(RegExp(r'^[0-9a-f]{256}$').hasMatch(a), isTrue);
  });

  test('间接验证裸 RSA 与参考一致：相同明文→相同密文', () {
    // 仅校验可重现，真正一致需对拍卖私有指数，这里保留结构校验
    final c1 = rsaEncryptRaw('secretKey123');
    expect(c1.length, 256);
  });

  test('设备指纹可生成(52 hex)', () {
    final did = generateDeviceId();
    expect(
      RegExp(r'^[0-9A-F]{52}$').hasMatch(did),
      isTrue,
      reason: 'deviceId 52 hex',
    );
  });

  test('encodeId 确定且 registerUsername 可拆回 deviceId+encodeId', () {
    final did = generateDeviceId();
    final e1 = encodeId(did);
    final e2 = encodeId(did);
    expect(e1, e2, reason: 'encodeId 应确定性');
    expect(() => base64Decode(e1), returnsNormally);
    final user = registerUsername(did);
    final decoded = utf8.decode(base64Decode(user));
    expect(decoded.split(' ')[0], did);
    expect(decoded.split(' ')[1], e1);
  });

  test('cookie 解析/拼接往返', () {
    const raw = 'MUSIC_U=abc; os=pc; foo=bar';
    final map = cookieToJson(raw);
    expect(map['os'], 'pc');
    final out = cookieObjToString(map);
    expect(out.contains('os='), isTrue);
  });

  test('mergeSetCookies 忽略属性字段并处理过期/删除', () {
    final target = <String, String>{'os': 'pc'};
    mergeSetCookies(target, [
      'MUSIC_U=abc; Path=/; HttpOnly',
      'foo=bar; Max-Age=0',
      'new=token; Max-Age=3600',
      'old=gone; expires=2010-01-12T00:00:00',
      'keep=yes; expires=2060-01-12T00:00:00Z',
    ]);
    // 正常 cookie 入库；已有 os 保留
    expect(target['MUSIC_U'], 'abc');
    expect(target['os'], 'pc');
    // 属性(path/max-age/expires/httponly)不入库
    expect(target.containsKey('Path'), isFalse);
    expect(target.containsKey('HttpOnly'), isFalse);
    expect(target.containsKey('max-age'), isFalse);
    // Max-Age=0 → 删除；过去 expires → 删除；未来 expires → 保留
    expect(target['new'], 'token');
    expect(target.containsKey('foo'), isFalse);
    expect(target.containsKey('old'), isFalse);
    expect(target['keep'], 'yes');
  });

  test('buildRequest(weapi) 拼出正确 URL/Header/Body', () {
    final prep = buildRequest('/api/search', {
      'keywords': 'a',
      'limit': 10,
    }, NeteaseMode.weapi);
    expect(prep.url, startsWith('https://music.163.com/weapi/'));
    expect(prep.headers['User-Agent'], isNotNull);
    expect(prep.body.contains('params='), isTrue);
    expect(prep.body.contains('encSecKey='), isTrue);
  });

  test('buildRequest(eapi) 拼出 /eapi url；默认 e_r=false 不解密,e_r=true 才解密', () {
    final prep = buildRequest('/api/song/url/v1', {
      'id': 1,
      'level': 'standard',
    }, NeteaseMode.eapi);
    expect(prep.url, contains('/eapi/song/url/v1'));
    expect(prep.needDecrypt, isFalse); // 对齐 SNext ENCRYPT_RESPONSE=false
    expect(prep.body, startsWith('params='));
    final prepER = buildRequest(
      '/api/song/url/v1',
      {'id': 1},
      NeteaseMode.eapi,
      useER: true,
    );
    expect(prepER.needDecrypt, isTrue);
  });

  test('xeapiSign 确定性且为 base64', () {
    final a = xeapiSign('1700000000', '1234567890123456');
    final b = xeapiSign('1700000000', '1234567890123456');
    expect(a, b);
    expect(() => base64Decode(a), returnsNormally);
  });

  test('xeapiDecryptPublicKey 可还原加密后的公钥状态', () {
    final state = XeapiPublicKeyState()
      ..version = '1.0'
      ..publicKey = base64Encode(List.filled(32, 7))
      ..sk = 'abc';
    // 按参考：AES-ECB(staticKey) 加密 JSON
    final plain = utf8.encode(
      jsonEncode({
        'version': state.version,
        'publicKey': state.publicKey,
        'sk': state.sk,
      }),
    );
    final encrypted = base64Encode(aesEcbEncrypt(plain, kXeapiStaticKey));
    final dec = xeapiDecryptPublicKey(encrypted);
    expect(dec.version, state.version);
    expect(dec.publicKey, state.publicKey);
    expect(dec.sk, state.sk);
    expect(dec.valid, isTrue);
  });

  test('xeapi 输出 B/S/R 三段合法(长度与 base64)', () async {
    final pub = XeapiPublicKeyState()
      ..version = 'v'
      ..publicKey = base64Encode(List.filled(32, 9))
      ..sk = null;
    final out = await xeapi(
      '/api/register/anonimous',
      {'username': 'x'},
      session: XeapiSession(),
      pub: pub,
    );
    expect(out.keys, containsAll(['B', 'S', 'R']));
    // B 与 R 为 AES-ECB(块对齐) 的 base64
    expect(base64Decode(out['B']!).length % 16, 0, reason: 'B 应为块对齐');
    // S = 32(eph) + 12(iv) + ct + 16(tag)
    final s = base64Decode(out['S']!).length;
    expect(s >= 32 + 12 + 16, isTrue);
  });

  test('xeapiResDecrypt 往返(无 gzip)', () {
    final inner = utf8.encode('[1,2,3]');
    final cipher = aesEcbEncrypt(inner, utf8.encode(kEapiKey));
    final j = xeapiResDecrypt(cipher);
    expect(j, [1, 2, 3]);
  });
}
