// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_auth.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/storage/netease_session_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dart 命令行集成测试：QR 登录完整闭环 + 持久化模拟重启验证。
///
/// 步骤：
///   1) SharedPreferences.setMockInitialValues({}) 提供纯 Dart 可用的内存 SP；
///   2) NeteaseSessionStorage.init + createContextFromSnapshot 构造持久化上下文；
///   3) newKey() → 打印扫码 URL（控制台 + 复制剪贴板提示）；
///   4) Timer.periodic 2s 调 check(key) → 按 code 打印 800 过期/801 待扫/802 待确认/803 成功；
///   5) 803 后 profile() → 打印 nickname / userId / avatar；
///   6) refresh() → 续期并重新 persistIfMutating 保存；
///   7) ⭐ 模拟「应用重启」：重新走 storage.load() → 构造新 client+api+qrlogin；
///   8) 对比重启前后：deviceId 一致、isLoggedIn==true、musicU 一致、MUSIC_A 持久化（如果做了匿名）。
Future<void> main() async {
  // 1) 给纯 Dart 命令行准备内存 SP（真实 Flutter app 不需要，这里集成测试专用）
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final storage = await NeteaseSessionStorage.init();
  final snapshot0 = storage.load();
  print(
    '[init] 初始快照: isEmpty=${snapshot0.isEmpty}, deviceId=${snapshot0.deviceId ?? 'NULL (将自动生成)'}',
  );

  // 2) 用快照初始化 ctx（首次启动 deviceId 为空，自动 generate；后续"模拟重启"会走快照里的）
  final ctx1 = createContextFromSnapshot(snapshot0);
  final client1 = NeteaseClient(context: ctx1, storage: storage);
  final api1 = NeteaseApi(client1);
  final qr1 = NeteaseQrLogin(api1);

  print(
    '[init] 初始 client: isLoggedIn=${qr1.isLoggedIn}, deviceId=${ctx1.deviceId.substring(0, 8)}...',
  );

  // 3) newKey → 打印扫码 URL
  final key = await qr1.newKey();
  final url = qr1.qrUrl(key);
  print('\n📱 请打开网易云音乐 App → 侧边栏「扫一扫」→ 扫描或复制下面 URL 到手机浏览器打开授权：');
  print('   $url');
  try {
    // Windows: 尝试输出到剪贴板提示（仅提示，不强制）
    if (Platform.isWindows) {
      final encoded = Uri.encodeQueryComponent(url);
      print('   [Windows 提示] 可用 echo|set /p="$url"| clip  手动复制到剪贴板: $encoded');
    }
  } catch (_) {}
  print('\n⏳ 开始轮询（每 2 秒一次，超时 5 分钟后自动退出）...\n');

  // 4) Timer 轮询 2s × 150 = 5 分钟
  final sw = Stopwatch()..start();
  const maxMs = 5 * 60 * 1000;
  String? lastStatusText;
  Timer? running;
  running = Timer.periodic(const Duration(seconds: 2), (timer) async {
    running ??= timer;
    if (sw.elapsedMilliseconds > maxMs) {
      print('\n⌛ 超时 5 分钟仍未完成扫码，退出。');
      timer.cancel();
      exit(2);
    }
    try {
      final r = await qr1.check(key);
      final msg = switch (r.code) {
        800 => '❌ 二维码已过期，请重新启动本脚本',
        801 =>
          '⏳ 等待扫码中 (801)${r.nickname != null ? '，nickname=${r.nickname}' : ''}',
        802 =>
          '📝 手机端已扫码，等待点「确认」(802)${r.nickname != null ? '，nickname=${r.nickname}' : ''}',
        803 => '✅ 扫码授权成功！(803)',
        _ => '❓ 未知状态码 ${r.code}',
      };
      if (msg != lastStatusText) print(' [${sw.elapsed.inSeconds}s] $msg');
      lastStatusText = msg;
      if (r.code == 800) {
        timer.cancel();
        exit(3);
      }
      if (r.code == 803) {
        timer.cancel();
        await _postLogin(qr1, storage);
        exit(0);
      }
    } catch (e) {
      print('  [${sw.elapsed.inSeconds}s] ⚠️  轮询异常: $e');
    }
  });
}

Future<void> _postLogin(
  NeteaseQrLogin qr1,
  NeteaseSessionStorage storage,
) async {
  print('\n=== 5) profile()：拉取用户信息 ===');
  final prof = await qr1.profile();
  if (prof == null) {
    print('❌ 扫码成功但 profile 为空（半登录态），请重新扫码或检查 cookie。');
    return;
  }
  print('userId=${prof['userId']}');
  print('nickname=${prof['nickname']}');
  print(
    'avatarUrl=${(prof['avatarUrl'] ?? '').toString().substring(0, (prof['avatarUrl'] ?? '').toString().length > 60 ? 60 : (prof['avatarUrl'] ?? '').toString().length)}...',
  );
  print('vipType=${prof['vipType']}');

  print('\n=== 6) refresh()：续期并重新保存 ===');
  await qr1.refresh();
  final snapBefore = storage.load();
  print(
    '存储后快照: cookies.keys=${snapBefore.cookies.keys.toList()}, updatedAt=${snapBefore.updatedAt}, deviceId=${snapBefore.deviceId?.substring(0, 8)}...',
  );

  // ⭐ 核心：模拟应用杀掉后重启——重新 load() + 重新构造整套 ctx/client/api/qrlogin
  print('\n=== 7) 模拟「重启应用」：new client 从 storage.load() 重建 ===');
  final snapRestart = storage.load();
  final ctx2 = createContextFromSnapshot(snapRestart);
  final client2 = NeteaseClient(context: ctx2, storage: storage);
  final api2 = NeteaseApi(client2);
  final qr2 = NeteaseQrLogin(api2);
  final prof2 = await qr2.profile();

  final eqDeviceId = ctx2.deviceId == qr1.api.client.ctx.deviceId;
  final eqLoggedIn = qr2.isLoggedIn;
  final eqUserId = prof2?['userId'].toString() == prof['userId'].toString();
  print('重启后 deviceId 一致? ${eqDeviceId ? '✅' : '❌  (风控根因：每次启动换设备=高频新设备)'}');
  print('重启后 isLoggedIn=true? ${eqLoggedIn ? '✅' : '❌  (MUSIC_U 未持久化)'}');
  print('重启后 profile.userId 一致? ${eqUserId ? '✅' : '❌  (续期未保存成功或 cookie 损坏)'}');
  print('重启后 userId=${prof2?['userId']}, nickname=${prof2?['nickname']}');
  print(
    '\n🍻 持久化验证完成：${eqDeviceId && eqLoggedIn && eqUserId ? '✅ 三要素全部持久化' : '❌ 存在缺口，需修复'}',
  );

  // 辅助：把 snapshot dump JSON 打印到 stdout 尾部
  print('\n=== storage.dump (调试用) ===');
  print(
    JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'deviceId': snapRestart.deviceId,
      'cookies_keys': snapRestart.cookies.keys.toList(),
      'cookies_MUSIC_U_len': (snapRestart.cookies['MUSIC_U'] ?? '').length,
      'cookies_MUSIC_A_len': (snapRestart.cookies['MUSIC_A'] ?? '').length,
      'anonToken_len': (snapRestart.anonToken ?? '').length,
      'updatedAt_iso': snapRestart.updatedAt?.toIso8601String(),
    }),
  );
}
