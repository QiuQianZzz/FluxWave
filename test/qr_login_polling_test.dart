import 'dart:collection';

import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_auth.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/pages/login/qr_login_page.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 二维码登录轮询优化回归：
/// - 瞬时网络故障：退避重试、不置终态错误（不弹「重新获取」按钮）、不清二维码；
/// - 终态（800 过期 / 803 成功）：停止轮询；
/// - 退后台：停止轮询，回前台立即恢复。
class _FakeQrLogin extends NeteaseQrLogin {
  _FakeQrLogin() : super(NeteaseApi(NeteaseClient()));

  bool networkDown = false;
  int checkCalls = 0;
  final Queue<QrCheckResult> responses = Queue<QrCheckResult>();

  @override
  Future<String> newKey() async => 'fake-unikey';

  @override
  String qrUrl(String key) => 'https://music.163.com/login?codekey=$key';

  @override
  Future<QrCheckResult> check(String key) async {
    checkCalls++;
    if (networkDown) {
      throw NeteaseException('网络断开', isNetwork: true);
    }
    if (responses.isNotEmpty) return responses.removeFirst();
    return const QrCheckResult(code: 801);
  }

  @override
  Future<Map<String, dynamic>?> profile() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 推进到「首轮轮询已完成」：init → newKey → 触发零时差定时器 → 轮询结果落定。
  Future<void> settleFirstPoll(WidgetTester tester) async {
    await tester.pump(); // init → newKey 完成 → 安排零时差定时器
    await tester.pump(Duration.zero); // 触发零时差定时器 → 首次轮询
    await tester.pump(); // 轮询结果 setState 落定
  }

  /// 构建页面并推进到「首轮轮询已完成」。
  Future<_FakeQrLogin> pumpPage(WidgetTester tester) async {
    final fake = _FakeQrLogin();
    final provider = NeteaseProvider();
    await provider.init();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(home: QrLoginPage(qrOverride: fake)),
      ),
    );
    await settleFirstPoll(tester);
    return fake;
  }

  testWidgets('瞬时网络故障：退避重试，不置终态错误、不清二维码', (tester) async {
    final fake = _FakeQrLogin()..networkDown = true;
    final provider = NeteaseProvider();
    await provider.init();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(home: QrLoginPage(qrOverride: fake)),
      ),
    );
    await settleFirstPoll(tester); // 首轮轮询失败 → 2s 后重试

    expect(find.text('重新获取二维码'), findsNothing, reason: '瞬态网络故障不应触发「重新获取」终态按钮');
    expect(find.text('重试中'), findsOneWidget, reason: '应显示弱提示而非终态错误');
    expect(find.byType(QrImageView), findsOneWidget, reason: '不清二维码');
    final calls = fake.checkCalls;
    expect(calls, 1, reason: '首轮已发起一次轮询');

    // 退避：首次失败后间隔 2s，1s 内不得再请求。
    await tester.pump(const Duration(milliseconds: 1100));
    expect(fake.checkCalls, calls, reason: '退避期不应再轮询');
    expect(find.text('重新获取二维码'), findsNothing);

    // 2s 后触发下一次轮询（再次失败 → 4s）。
    await tester.pump(const Duration(seconds: 1));
    expect(fake.checkCalls, calls + 1, reason: '退避结束后应继续轮询');

    // 恢复网络：下一轮成功回到等待扫码，错误提示清除。
    fake.networkDown = false;
    await tester.pump(const Duration(seconds: 8)); // 覆盖 4s 退避
    expect(find.text('重试中'), findsNothing);
    expect(find.text('等待扫码'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('800 过期：停止轮询并展示重试按钮', (tester) async {
    final fake = _FakeQrLogin()..responses.add(const QrCheckResult(code: 800));
    final provider = NeteaseProvider();
    await provider.init();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(home: QrLoginPage(qrOverride: fake)),
      ),
    );
    await settleFirstPoll(tester); // 首轮轮询 → 800

    expect(find.text('已过期'), findsOneWidget);
    expect(find.text('重新获取二维码'), findsOneWidget);

    final calls = fake.checkCalls;
    await tester.pump(const Duration(seconds: 5));
    expect(fake.checkCalls, calls, reason: '过期后应停止轮询');

    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('803 成功：停止轮询并进入成功态', (tester) async {
    final fake = _FakeQrLogin()..responses.add(const QrCheckResult(code: 803));
    final provider = NeteaseProvider();
    await provider.init();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(home: QrLoginPage(qrOverride: fake)),
      ),
    );
    await settleFirstPoll(tester); // 首轮轮询 → 803

    expect(find.text('登录成功'), findsWidgets);

    final calls = fake.checkCalls;
    await tester.pump(const Duration(seconds: 5));
    expect(fake.checkCalls, calls, reason: '成功后应停止轮询');

    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('退后台停止轮询，回前台立即恢复', (tester) async {
    final fake = await pumpPage(tester);
    expect(fake.checkCalls, 1, reason: '前台已发起首轮轮询');

    // 退后台：取消定时器，作废在途轮询。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    expect(fake.checkCalls, 1, reason: '后台期间不得轮询');

    // 回前台：立即恢复轮询。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(Duration.zero); // 触发恢复后的零时差定时器
    await tester.pump();
    expect(fake.checkCalls, 2, reason: '回前台应立即恢复轮询');

    await tester.pump(const Duration(milliseconds: 300));
  });
}
