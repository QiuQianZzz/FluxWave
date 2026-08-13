// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';

/// 对比「FluxWave 直连网易云」和「社区 api-enhanced 代理服务器」返回的字段一致性。
///
/// 用法（必须先启动 api-enhanced）：
///   cd d:\Desktop\flutter\musicplayer\api-enhanced && pnpm install && pnpm start
///   # 默认监听 http://localhost:3000
///   # 然后另一个终端：
///   cd d:\Desktop\flutter\musicplayer\fluxwave && dart run bin/verify_against_api_enhanced.dart
///
/// 输出「差异统计」，主要校验：
/// - search / songUrl 的响应 body.code；
/// - loginQrKey 的 unikey 字段存在性 + type=3；
/// - 不校验"字节完全一致"（api-enhanced 外层会多包一层 `{code:200, data: <raw>}`，对比时需要剥 data 外壳）。
Future<void> main(List<String> args) async {
  final proxyBase = args.isNotEmpty ? args.first : 'http://localhost:3000';
  print('[verify] api-enhanced proxy: $proxyBase');
  print('[verify] 检查 $proxyBase/login/qr/key 是否返回 200...');
  try {
    final proxyCheck = await _get('$proxyBase/login/qr/key');
    print(
      '[verify]   proxy check: code=${proxyCheck?['code']}, keys=${proxyCheck?.keys.toList()}',
    );
  } catch (e) {
    print(
      '[verify] ⚠️  无法连接 api-enhanced ($e)，请先 `cd api-enhanced && pnpm start`。',
    );
    print('[verify]    跳过仅代理侧的对比，仍可直连网易云做单端自检。');
  }

  final client = NeteaseClient(
    context: NeteaseRequestContext(osKey: 'android'),
  );
  final api = NeteaseApi(client);

  final report = <String>[];

  // --- Case 1: loginQrKey (eapi type=3) ---
  print('\n=== Case 1: loginQrKey (eapi type=3) ===');
  final k1 = await api.loginQrKey();
  print(
    'FluxWave 直连: code=${k1['code']}, unikey_len=${(k1['unikey'] as String?)?.length}, qrimg?=${k1['qrimg'] != null}',
  );
  if (k1['code'] == 200 && (k1['unikey'] as String?)?.isNotEmpty == true) {
    report.add('✅ loginQrKey: code=200 且 unikey 非空');
  } else {
    report.add('❌ loginQrKey: 异常 code=${k1['code']}');
  }
  await _cmp(
    report,
    'login_qr_key',
    await _get(
      '$proxyBase/login/qr/key?timestamp=${DateTime.now().millisecondsSinceEpoch}',
    ),
    <String, dynamic>{
      'code': k1['code'],
      'hasUnikey': (k1['unikey'] as String?)?.isNotEmpty ?? false,
    },
    stripDataShell: true,
  );

  // --- Case 2: search weapi ---
  print('\n=== Case 2: cloudsearch weapi ===');
  const kw = '周杰伦';
  final s1 = await api.search(kw, limit: 3);
  final songs = s1['result'] is Map ? (s1['result'] as Map)['songs'] : null;
  print(
    'FluxWave 直连: code=${s1['code']}, songs count=${songs is List ? songs.length : 'null'}',
  );
  if (s1['code'] == 200 && songs is List && songs.isNotEmpty) {
    report.add('✅ search: code=200 且至少返回一首《$kw》');
  } else {
    report.add('❌ search: 异常 code=${s1['code']}');
  }
  await _cmp(
    report,
    'search',
    await _get(
      '$proxyBase/cloudsearch?keywords=${Uri.encodeQueryComponent(kw)}&limit=3&type=1&timestamp=${DateTime.now().millisecondsSinceEpoch}',
    ),
    <String, dynamic>{
      'code': s1['code'],
      'hasSongs': (songs is List) && songs.isNotEmpty,
    },
    stripDataShell: true,
  );

  // --- Case 3: songUrl eapi (未登录场景走版权试听) ---
  print('\n=== Case 3: song/enhance/player/url/v1 eapi ===');
  const testId = 347230; // 《晴天》经典测试 ID
  final u1 = await api.songUrl(
    [testId],
    level: 'standard',
    useER: kEncryptResponse,
  );
  final data = u1['data'] is List
      ? (u1['data'] as List).cast<Map?>().firstWhere(
          (e) => (e?['id'] as num?) == testId,
          orElse: () => null,
        )
      : null;
  print(
    'FluxWave 直连: code=${u1['code']}, url=${data == null ? null : (data['url'] as String?)?.substring(0, data['url'].toString().length > 50 ? 50 : data['url'].toString().length)}...',
  );
  if (u1['code'] == 200 &&
      data != null &&
      (data['url'] as String?)?.isNotEmpty == true) {
    report.add('✅ songUrl: code=200 且 id=$testId 有播放 URL');
  } else {
    report.add('⚠️  songUrl: code=${u1['code']}, url may empty (未登录试听受限属正常)');
  }
  await _cmp(
    report,
    'songUrl',
    await _get(
      '$proxyBase/song/url/v1?id=$testId&level=standard&encodeType=flac&timestamp=${DateTime.now().millisecondsSinceEpoch}',
    ),
    <String, dynamic>{
      'code': u1['code'],
      'hasUrl': data != null && (data['url'] as String?)?.isNotEmpty == true,
    },
    stripDataShell: true,
  );

  // 收尾：匿名注册（不对比只自检）
  print('\n=== Case 4: registerAnon (xeapi) 自检 ===');
  try {
    final ok = await client.registerAnon();
    final token = client.ctx.anonToken;
    final hasMA = client.ctx.cookies['MUSIC_A']?.isNotEmpty ?? false;
    report.add(
      ok && token != null && hasMA
          ? '✅ registerAnon: MUSIC_A 已落 ctx.cookies'
          : '❌ registerAnon: ok=$ok, token=$token, hasMA=$hasMA',
    );
  } catch (e) {
    report.add('⚠️  registerAnon: 异常 $e (xeapi 对国内 IP 有风控，属正常)');
  }

  print('\n========== REPORT ==========');
  for (final r in report) {
    print(r);
  }
  exit(report.any((e) => e.startsWith('❌')) ? 1 : 0);
}

Future<Map<String, dynamic>?> _get(String url) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await http.getUrl(Uri.parse(url));
    final res = await req.close();
    final raw = await res.transform(utf8.decoder).join();
    try {
      final o = jsonDecode(raw);
      return o is Map ? Map<String, dynamic>.from(o) : null;
    } catch (_) {
      return null;
    }
  } finally {
    http.close(force: true);
  }
}

/// api-enhanced 返回 `{code: 200, data: {...<raw body>}}` 的外壳，
/// 对 body.code 直接取外层，而 hasXxx 等需要剥 data 取里面的字段
Future<void> _cmp(
  List<String> report,
  String name,
  Map<String, dynamic>? proxy,
  Map<String, dynamic> direct, {
  required bool stripDataShell,
}) async {
  if (proxy == null) {
    report.add('⚠️  $name vs proxy: 代理不可用（跳过），直连结果：$direct');
    return;
  }
  final proxyCode = proxy['code'];
  final directCode = direct['code'];
  final mismatches = <String>[];
  if (proxyCode != directCode) {
    mismatches.add('code: proxy=$proxyCode vs direct=$directCode');
  }
  for (final k in direct.keys.where((k) => k != 'code')) {
    Object? pv;
    if (stripDataShell && proxy['data'] is Map) {
      pv = (proxy['data'] as Map)[k];
    } else {
      pv = proxy[k];
    }
    if (pv is bool && direct[k] is bool) {
      if (pv != direct[k]) {
        mismatches.add('$k: proxy=$pv vs direct=${direct[k]}');
      }
    }
  }
  if (mismatches.isEmpty) {
    report.add('✅ $name vs proxy: 一致 (direct=$direct, proxy.code=$proxyCode)');
  } else {
    report.add('❌ $name vs proxy: 差异 → ${mismatches.join(' | ')}');
  }
}
