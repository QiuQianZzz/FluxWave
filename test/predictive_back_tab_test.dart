import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/navigation/app_nav.dart';
import 'package:fluxwave/main.dart';
import 'package:fluxwave/pages/playback_stats/playback_stats_page.dart';
import 'package:fluxwave/pages/tab_navigator.dart';
import 'package:fluxwave/providers/settings_provider.dart';

const _codec = StandardMethodCodec();

Future<void> _sendBackGesture(
  WidgetTester tester,
  String method, [
  Map<String, Object?>? args,
]) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    _codec.encodeMethodCall(MethodCall(method, args ?? const {})),
    (_) {},
  );
}

Map<String, Object?> _swipe(double progress) => {
      'progress': progress,
      'touchOffset': [100.0, 500.0],
      'swipeEdge': 0,
    };

void main() {
  testWidgets('预测性返回手势弹 A 子页不应连累 B 子页', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.init();
    await tester.pumpWidget(FluxWaveApp(settings: settings));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    Finder navIcon(IconData icon) => find.descendant(
          of: find.byType(NavigationBar),
          matching: find.byIcon(icon),
        );

    Future<void> settleTab() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final tabs = tester
        .widgetList<TabNavigator>(find.byType(TabNavigator, skipOffstage: false))
        .toList();

    // A：我的 tab 打开播放记录
    await tester.tap(navIcon(Icons.person_outline_rounded));
    await settleTab();
    await tester.tap(find.text('播放记录'));
    await settleTab();
    expect(find.byType(PlaybackStatsPage), findsOneWidget);

    // B：首页 tab push 子页（走 AppNav.push 同款 TabAwarePageRoute，模拟真实场景）
    tabs[0].navigatorKey.currentState!.push(
      TabAwarePageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('HOME-SUB'))),
      ),
    );
    await tester.pump();
    await settleTab();

    // A（我的 tab）仍活跃，模拟预测性返回手势：start → update → commit
    await _sendBackGesture(tester, 'startBackGesture', _swipe(0.2));
    await _sendBackGesture(tester, 'updateBackGestureProgress', _swipe(0.9));
    await tester.pump();
    await _sendBackGesture(tester, 'commitBackGesture');
    await settleTab();

    // A 子页（播放记录）应被弹掉
    expect(
      find.byType(PlaybackStatsPage),
      findsNothing,
      reason: '预测性返回应弹掉 A 的子页',
    );

    // 切到首页：B 子页应保留
    await tester.tap(navIcon(Icons.home_outlined));
    await settleTab();
    expect(
      find.text('HOME-SUB', skipOffstage: false),
      findsOneWidget,
      reason: '预测性返回弹 A 子页不应连累 B 的子页',
    );
  });
}
