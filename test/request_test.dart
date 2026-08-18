import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/netease/request.dart';

void main() {
  // 辅助：从 Cookie header 字符串解析回 Map
  Map<String, String> parseCookieHeader(String header) {
    final map = <String, String>{};
    for (final item in header.split(';')) {
      final idx = item.indexOf('=');
      if (idx <= 0) continue;
      map[item.substring(0, idx).trim()] = Uri.decodeComponent(
        item.substring(idx + 1).trim(),
      );
    }
    return map;
  }

  group('buildRequest weapi', () {
    test('URL 包含 /weapi/ 且指向 music.163.com', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      expect(prep.url, contains('/weapi/'));
      expect(prep.url, contains('music.163.com'));
    });

    test('UA 为桌面浏览器 (Edge/Chrome)', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      expect(
        prep.headers['User-Agent'],
        anyOf(contains('Edg'), contains('Chrome')),
      );
    });

    test('Cookie 包含 _ntes_nuid 和 WNMCID', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], contains('_ntes_nuid'));
      expect(prep.headers['Cookie'], contains('WNMCID'));
    });

    test('body 为加密格式（params= + encSecKey=）', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      // weapi 加密后 csrf_token/e_r 在 params 密文内，body 只暴露 params + encSecKey
      expect(prep.body, contains('params='));
      expect(prep.body, contains('encSecKey='));
    });
  });

  group('buildRequest eapi', () {
    test('URL 包含 /eapi/ 且指向 interface.music.163.com', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.url, contains('/eapi/'));
      expect(prep.url, contains('interface.music.163.com'));
    });

    test('UA 为 iPhone（eapi 默认 iPhone 伪装）', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['User-Agent'], contains('iPhone'));
    });

    test('Cookie 不含 _ntes_nuid/WNMCID（eapi 用独立 header 对象）', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], isNot(contains('_ntes_nuid')));
      expect(prep.headers['Cookie'], isNot(contains('WNMCID')));
      expect(prep.headers['Cookie'], isNot(contains('__remember_me')));
    });

    test('Cookie 包含 osver 和 appver', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], contains('osver'));
      expect(prep.headers['Cookie'], contains('appver'));
      expect(prep.headers['Cookie'], contains('deviceId'));
      expect(prep.headers['Cookie'], contains('channel'));
      expect(prep.headers['Cookie'], contains('requestId'));
    });
  });

  group('buildRequest linuxapi', () {
    test('URL 指向 /api/linux/forward', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.linuxapi,
        ctx: ctx,
      );
      expect(prep.url, contains('/api/linux/forward'));
    });

    test('UA 为 Linux Chrome', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.linuxapi,
        ctx: ctx,
      );
      expect(prep.headers['User-Agent'], contains('Linux'));
    });
  });

  group('NMTID 处理', () {
    test('登录类接口移除 NMTID', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/login/qrcode/unikey',
        {'type': 3},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], isNot(contains('NMTID')));
    });

    test('非登录接口保留 NMTID', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], contains('NMTID'));
    });
  });

  group('_fillCoreCookie 稳定性', () {
    test('连续两次请求 _ntes_nuid 值相同（回写 ctx 生效）', () {
      final ctx = NeteaseRequestContext(osKey: 'android');
      final prep1 = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      final prep2 = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      final c1 = parseCookieHeader(prep1.headers['Cookie']!);
      final c2 = parseCookieHeader(prep2.headers['Cookie']!);
      expect(c1['_ntes_nuid'], equals(c2['_ntes_nuid']));
      expect(c1['WNMCID'], equals(c2['WNMCID']));
      expect(c1['_ntes_nnid'], equals(c2['_ntes_nnid']));
    });

    test('不同 ctx 实例 _ntes_nuid 不同', () {
      final ctx1 = NeteaseRequestContext(osKey: 'android');
      final ctx2 = NeteaseRequestContext(osKey: 'android');
      final prep1 = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx1,
      );
      final prep2 = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx2,
      );
      final c1 = parseCookieHeader(prep1.headers['Cookie']!);
      final c2 = parseCookieHeader(prep2.headers['Cookie']!);
      expect(c1['_ntes_nuid'], isNot(equals(c2['_ntes_nuid'])));
    });
  });

  group('MUSIC_U 注入', () {
    test('eapi header 包含 MUSIC_U（当 ctx.musicU 非空）', () {
      final ctx = NeteaseRequestContext(
        osKey: 'android',
        musicU: 'test_music_u_token',
      );
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], contains('MUSIC_U'));
      expect(prep.headers['Cookie'], contains('test_music_u_token'));
    });

    test('weapi cookie 包含 MUSIC_U（当 ctx.musicU 非空）', () {
      final ctx = NeteaseRequestContext(
        osKey: 'android',
        musicU: 'test_music_u_token',
      );
      final prep = buildRequest(
        '/api/cloudsearch/pc',
        {'s': 'test'},
        NeteaseMode.weapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], contains('MUSIC_U'));
    });

    test('MUSIC_U 存在时移除 MUSIC_A', () {
      final ctx = NeteaseRequestContext(
        osKey: 'android',
        musicU: 'test_music_u',
        anonToken: 'test_music_a',
      );
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], contains('MUSIC_U'));
      expect(prep.headers['Cookie'], isNot(contains('MUSIC_A')));
    });

    test('无 MUSIC_U 时保留 MUSIC_A', () {
      final ctx = NeteaseRequestContext(
        osKey: 'android',
        anonToken: 'test_music_a',
      );
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['Cookie'], contains('MUSIC_A'));
    });
  });

  group('eapi UA 特殊处理', () {
    test('osx 用桌面 Chrome UA', () {
      final ctx = NeteaseRequestContext(osKey: 'osx');
      final prep = buildRequest(
        '/api/song/enhance/player/url/v1',
        {'ids': '[1]'},
        NeteaseMode.eapi,
        ctx: ctx,
      );
      expect(prep.headers['User-Agent'], contains('Chrome'));
      expect(prep.headers['User-Agent'], isNot(contains('iPhone')));
    });
  });
}
