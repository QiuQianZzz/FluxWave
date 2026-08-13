import 'dart:convert';

import 'crypto.dart';

/// 匿名注册用的 XOR 密钥(register_anonimous 的 ID_XOR_KEY)。
const kIdXorKey = '3go8&\$8*3*3h0k(2)2';

/// 生成 xx 位大写 hex 设备ID(26 随机字节 -> 52 位 hex 大写)。
String generateDeviceId() {
  final b = randomBytes(26);
  return encodeHex(b).toUpperCase();
}

/// 重新生成设备ID(register_anonimous 每次都会换新设备)。
String regenerateDeviceId() => generateDeviceId();

/// 生成 WNMID：6 位小写字母.<毫秒>.01.0。
String generateWnmcId() {
  final letters = randomBytes(6).map<int>((b) => 0x61 + b % 26);
  return '${String.fromCharCodes(letters)}.${DateTime.now().millisecondsSinceEpoch}.01.0';
}

/// 生成请求号：timestamp_xxxx。
String generateRequestId() {
  final r = (randomBytes(1).first % 1000).toString().padLeft(4, '0');
  return '${DateTime.now().millisecondsSinceEpoch}_$r';
}

/// register_anonimous 的 encodeId：逐字 XOR kIdXorKey 后 MD5 -> 标准 base64。
String encodeId(String deviceId) {
  final bytes = utf8.encode(deviceId);
  final xored = List<int>.generate(
    bytes.length,
    (i) => bytes[i] ^ kIdXorKey[i % kIdXorKey.length].codeUnitAt(0),
  );
  return base64Encode(decodeHex(md5Hex(xored)));
}

/// 匿名注册 username：标准 base64(`${deviceId} {encodeId}`)。
String registerUsername(String deviceId) =>
    base64Encode(utf8.encode('$deviceId ${encodeId(deviceId)}'));
