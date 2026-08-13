import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/player/song_url.dart';
import 'package:fluxwave/models/song.dart';

/// 未登录公开接口的联网冒烟测试。
/// 需要本机网络；离线时自动 skip(用 [live] 控制)。
void main() async {
  final online = await _canReachNetwork();
  if (!online) {
    // ignore: avoid_print
    print('⚠️ 无法访问 music.163.com，联网用例将跳过。');
  }

  test('未登录可用：weapi /api/search 返回 code=200 与 result', () async {
    final api = NeteaseApi(NeteaseClient());
    final r = await api.search('周杰伦', limit: 5);
    final s = r.toString();
    // ignore: avoid_print
    print('SEARCH raw: ${s.substring(0, s.length > 160 ? 160 : s.length)}');
    expect(r['code'], 200);
    final result = r['result'];
    expect(result, isNotNull);
    expect((result as Map)['songs'], isA<List>());
  }, skip: !online);

  test('未登录可用：eapi 播放地址接口返回 data 列表(可解密)', () async {
    final api = NeteaseApi(NeteaseClient());
    final r = await api.songUrl([30293905]);
    // ignore: avoid_print
    print(
      'SONGURL(raw) raw: ${r.toString().substring(0, r.toString().length.clamp(0, 160))}',
    );
    expect(r['code'] == 200, isTrue);
    expect(r['data'], isA<List>());
  }, skip: !online);

  test('songUrl 返回 http 地址，升 https 后 CDN 可探活(audio/*)', () async {
    final api = NeteaseApi(NeteaseClient());
    final r = await api.songUrl([2709812973]);
    final result = SongUrlResolver.parse(r);
    expect(result, isNotNull, reason: '匿名 standard 应返回可播地址:\n${r.toString()}');
    final url = result!.url;
    expect(url.startsWith('https://'), isTrue, reason: '应已升级 https');
    // 对 CDN 发 Range 探活：期望 200/206 且为音频类型（确认 https 真能拉流）
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final ct = res.headers.contentType?.mimeType ?? 'unknown';
      // ignore: avoid_print
      print('CDN status=${res.statusCode} type=$ct url=$url');
      expect(res.statusCode, anyOf(200, 206));
      expect(ct.startsWith('audio/'), isTrue, reason: 'mime=$ct');
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  }, skip: !online);

  test('e_r=true 时 eapi 响应被服务端加密、本地 AES 解密成功', () async {
    final api = NeteaseApi(NeteaseClient());
    final r = await api.songUrl([30293905], useER: true);
    // ignore: avoid_print
    print(
      'SONGURL(encrypted->decrypted): code=${r['code']} data=${(r['data'] as List?)?.length}',
    );
    expect(r['code'] == 200, isTrue);
    expect(r['data'], isA<List>());
  }, skip: !online);

  test('二维码登录:获取 unikey(code=200, 含 unikey)', () async {
    final api = NeteaseApi(NeteaseClient());
    final r = await api.loginQrKey();
    // ignore: avoid_print
    print(
      'QRKEY raw: ${r.toString().substring(0, r.toString().length.clamp(0, 120))}',
    );
    expect(r['code'], 200);
    expect(r['unikey'], isA<String>());
  }, skip: !online);

  test('二维码登录:轮询状态为 800/801/802/803 之�?且 URL 正确', () async {
    final api = NeteaseApi(NeteaseClient());
    final r = await api.loginQrKey();
    final key = r['unikey'] as String;
    expect(api.loginQrUrl(key), 'https://music.163.com/login?codekey=$key');
    final st = await api.loginQrCheck(key);
    final code = st['code'];
    // ignore: avoid_print
    print('QRCHECK code=$code msg=${st['message']}');
    expect(<int>[800, 801, 802, 803], contains(code));
  }, skip: !online);

  test('搜索封面缩略图: coverSmall 返回真实小尺寸(解析图片头)', () async {
    final api = NeteaseApi(NeteaseClient());
    final r = await api.search('周杰伦', limit: 1);
    final songs = ((r['result'] as Map)['songs'] as List).cast<Map>();
    final song = Song.fromSearch(Map<String, dynamic>.from(songs.first));
    expect(song.coverSmall, isNotNull, reason: '应能拿到缩略 URL');
    expect(
      song.coverSmall,
      isNot(equals(song.coverUrl)),
      reason: '缩略 URL 应与原图 URL 不同',
    );
    // ignore: avoid_print
    print('原图: ${song.coverUrl}\n缩略: ${song.coverSmall}');

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .getUrl(Uri.parse(song.coverSmall!))
          .timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      expect(res.statusCode, 200, reason: 'CDN 应直接返回 200');
      final bytes = await res
          .fold<List<int>>([], (acc, c) => acc..addAll(c))
          .timeout(const Duration(seconds: 15));
      final dim = _imageSize(bytes);
      // ignore: avoid_print
      print('THUMB real-size=$dim bytes=${bytes.length}');
      expect(dim, isNotNull, reason: '应能解析出图片头');
      expect(dim!.$1, inInclusiveRange(1, 300), reason: '宽度应为小图');
      expect(dim.$2, dim.$1, reason: 'param=200y200 应为方形');
    } finally {
      client.close(force: true);
    }
  }, skip: !online);
}

/// 解析 JPEG/PNG 头部得到像素尺寸；无法识别返回 null。
(int, int)? _imageSize(List<int> b) {
  // PNG: IHDR 固定位于 16..23（宽 16-19，高 20-23，大端）
  if (b.length > 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return (_be(b, 16), _be(b, 20));
  }
  // JPEG: 找 SOF 段（FF C0-C3 / C5-C7 / C9-CB / CD-CF），其内容为高、宽
  for (var i = 2; i + 9 < b.length;) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    final isSof =
        (marker >= 0xC0 && marker <= 0xC3) ||
        (marker >= 0xC5 && marker <= 0xC7) ||
        (marker >= 0xC9 && marker <= 0xCB) ||
        (marker >= 0xCD && marker <= 0xCF);
    if (isSof) {
      final h = _u16(b, i + 5);
      final w = _u16(b, i + 7);
      return (w, h);
    }
    i += 2 + _u16(b, i + 2);
  }
  return null;
}

int _u16(List<int> b, int i) => (b[i] << 8) | b[i + 1];

int _be(List<int> b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

Future<bool> _canReachNetwork() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client
        .getUrl(Uri.parse('https://music.163.com/'))
        .timeout(const Duration(seconds: 5));
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();
    return res.statusCode < 500;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
