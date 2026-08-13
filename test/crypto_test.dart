import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/netease/crypto.dart';
import 'package:fluxwave/core/netease/cookie.dart';
import 'package:fluxwave/core/netease/device.dart';

void main() {
  group('deviceId', () {
    test('generateDeviceId 返回 52 位大写 hex', () {
      final id = generateDeviceId();
      expect(id.length, 52);
      expect(RegExp(r'^[0-9A-F]{52}$').hasMatch(id), isTrue);
    });

    test('regenerateDeviceId 生成新的 52 位 hex', () {
      final id1 = generateDeviceId();
      final id2 = regenerateDeviceId();
      expect(id2.length, 52);
      expect(id1, isNot(equals(id2)));
    });
  });

  group('encodeId', () {
    test('返回标准 base64 字符串', () {
      final id = generateDeviceId();
      final encoded = encodeId(id);
      expect(encoded.isNotEmpty, isTrue);
      expect(RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(encoded), isTrue);
    });

    test('相同输入产生相同输出（确定性）', () {
      final id = List.filled(52, 'A').join();
      expect(encodeId(id), equals(encodeId(id)));
    });
  });

  group('registerUsername', () {
    test('返回 base64 编码的 "deviceId encodeId"', () {
      final id = generateDeviceId();
      final username = registerUsername(id);
      expect(username.isNotEmpty, isTrue);
      expect(RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(username), isTrue);
    });
  });

  group('weapi', () {
    test('返回 params 和 encSecKey', () {
      final result = weapi({'s': 'test'});
      expect(result.containsKey('params'), isTrue);
      expect(result.containsKey('encSecKey'), isTrue);
      expect(result['params']!.isNotEmpty, isTrue);
    });

    test('encSecKey 为 256 位 hex（128 字节裸 RSA）', () {
      final result = weapi({'s': 'test'});
      expect(result['encSecKey']!.length, 256);
      expect(RegExp(r'^[0-9a-f]{256}$').hasMatch(result['encSecKey']!), isTrue);
    });
  });

  group('eapi', () {
    test('返回大写 hex 字符串', () {
      final result = eapi('/api/test', {'foo': 'bar'});
      expect(result.isNotEmpty, isTrue);
      expect(RegExp(r'^[0-9A-F]+$').hasMatch(result), isTrue);
    });

    test('相同输入产生相同输出（确定性）', () {
      final r1 = eapi('/api/test', {'foo': 'bar'});
      final r2 = eapi('/api/test', {'foo': 'bar'});
      expect(r1, equals(r2));
    });
  });

  group('linuxapi', () {
    test('返回 eparams 小写 hex', () {
      final result = linuxapi({
        'method': 'POST',
        'url': 'https://music.163.com/api/test',
      });
      expect(result.containsKey('eparams'), isTrue);
      expect(result['eparams']!.isNotEmpty, isTrue);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(result['eparams']!), isTrue);
    });
  });

  group('generateWnmcId', () {
    test('格式为 6字母.毫秒.01.0', () {
      final id = generateWnmcId();
      expect(
        RegExp(r'^[a-z]{6}\.\d+\.01\.0$').hasMatch(id),
        isTrue,
        reason: '实际值: $id',
      );
    });
  });

  group('generateRequestId', () {
    test('格式为 timestamp_xxxx', () {
      final id = generateRequestId();
      expect(RegExp(r'^\d+_\d{4}$').hasMatch(id), isTrue, reason: '实际值: $id');
    });
  });

  group('cookieToJson', () {
    test('解析 "k1=v1; k2=v2"', () {
      final m = cookieToJson('MUSIC_U=abc; __csrf=xyz');
      expect(m['MUSIC_U'], 'abc');
      expect(m['__csrf'], 'xyz');
    });

    test('空字符串/null 返回空 Map', () {
      expect(cookieToJson(''), isEmpty);
      expect(cookieToJson(null), isEmpty);
    });

    test('忽略无 = 的片段', () {
      final m = cookieToJson('MUSIC_U=abc; invalid; __csrf=xyz');
      expect(m['MUSIC_U'], 'abc');
      expect(m['__csrf'], 'xyz');
      expect(m.containsKey('invalid'), isFalse);
    });
  });

  group('cookieObjToString', () {
    test('生成 "k1=v1; k2=v2" 格式', () {
      final s = cookieObjToString({'MUSIC_U': 'abc', '__csrf': 'xyz'});
      expect(s, contains('MUSIC_U=abc'));
      expect(s, contains('__csrf=xyz'));
      expect(s.contains(';'), isTrue);
    });

    test('空 Map 返回空字符串', () {
      expect(cookieObjToString({}), isEmpty);
    });
  });

  group('mergeSetCookies', () {
    test('从 set-cookie 列表添加 cookie', () {
      final target = <String, String>{};
      mergeSetCookies(target, [
        'MUSIC_U=token123; Path=/; Domain=.music.163.com; HttpOnly',
        '__csrf=csrf456; Path=/',
      ]);
      expect(target['MUSIC_U'], 'token123');
      expect(target['__csrf'], 'csrf456');
    });

    test('max-age=0 时删除已有 cookie', () {
      final target = <String, String>{'MUSIC_U': 'old_token'};
      mergeSetCookies(target, ['MUSIC_U=; max-age=0; Path=/']);
      expect(target.containsKey('MUSIC_U'), isFalse);
    });

    test('expires 过去时间时删除已有 cookie', () {
      final target = <String, String>{'MUSIC_U': 'old_token'};
      mergeSetCookies(target, [
        'MUSIC_U=; expires=1970-01-01T00:00:00Z; Path=/',
      ]);
      expect(target.containsKey('MUSIC_U'), isFalse);
    });

    test('多个 set-cookie 同时处理', () {
      final target = <String, String>{};
      mergeSetCookies(target, [
        'MUSIC_U=token; Path=/',
        '__csrf=csrf; Path=/',
        'NMTID=nmtid; Path=/',
      ]);
      expect(target.length, 3);
    });
  });

  group('encodeHex / decodeHex', () {
    test('互逆', () {
      final bytes = [0, 15, 255, 128, 1];
      final hex = encodeHex(bytes);
      expect(decodeHex(hex), equals(bytes));
    });

    test('encodeHex 生成小写 hex', () {
      expect(encodeHex([255]), 'ff');
      expect(encodeHex([0]), '00');
      expect(encodeHex([10]), '0a');
    });
  });
}
