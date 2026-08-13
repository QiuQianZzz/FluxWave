// 网易云公开接口示例脚本：/api/cloudsearch/pc 搜索 + /eapi songUrl 播放地址。
// 运行（需联网）：dart run tool/try_netease_api.dart
import 'dart:convert';

import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';

Future<void> main() async {
  final api = NeteaseApi(NeteaseClient());

  // 1) 搜索（weapi /api/cloudsearch/pc）
  print('===== 搜索 "周杰伦" =====');
  final s = await api.search('周杰伦', limit: 3);
  print('code: ${s['code']}');
  final songs = (s['result'] as Map?)?['songs'] as List? ?? [];
  for (final song in songs.take(3)) {
    final m = song as Map;
    final name = m['name'];
    final artists = ((m['ar'] ?? m['artists']) as List?)
            ?.map((e) => (e as Map)['name'])
            .join('、') ??
        '';
    final album = (m['al'] ?? m['album']) is Map
        ? ((m['al'] ?? m['album']) as Map)['name']
        : '';
    print('  - $name / $artists / 专辑:$album  id=${m['id']}');
  }

  // 2) 播放地址（eAPI；未登录受版权/试听限制，url 可能为 null）
  print('');
  print('===== songUrl(30293905) 明文 =====');
  var u = await api.songUrl([30293905]);
  print('code: ${u['code']}');
  final d0 = (u['data'] as List?)?.cast<Map>()[0];
  print('url: ${d0?['url']}  level=${d0?['level']}  br=${d0?['br']}  code=${d0?['code']}');

  // 3) 同一接口：e_r=true 走"服务端加密->本地 AES 解密"路径，验证解密正确
  print('');
  print('===== songUrl 且 useER=true(加密响应,本地解密) =====');
  u = await api.songUrl([30293905], useER: true);
  print('code: ${u['code']}  (解密成功且与上一条一致即正确)');
  final d1 = (u['data'] as List?)?.cast<Map>().firstOrNull;
  print('url: ${d1?['url']}');

  // 完整 JSON 前 N 个字符便于人工核对
  print('');
  print('---- 第一个返回值原始 JSON(前 300 字符) ----');
  print(pretty(s).substring(0, 300));
}

String pretty(Map m) => const JsonEncoder.withIndent('  ').convert(m);