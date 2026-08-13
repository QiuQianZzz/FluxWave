import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/main.dart';
import 'package:fluxwave/pages/playback_stats/playback_stats_page.dart';
import 'package:fluxwave/pages/tab_navigator.dart';
import 'package:fluxwave/providers/settings_provider.dart';

/// 复现：两个 tab 都有子页时，A 返回弹掉自己的子页，不应连累 B 的子页。
void main() {
  testWidgets('两个 tab 都有子页：A 返回弹子页不应连累 B 的子页', (tester) async {
    // 窄屏（手机）：走底部导航栏
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

    // 底部导航图标 finder（限定在 NavigationBar 内）
    Finder navIcon(IconData icon) => find.descendant(
          of: find.byType(NavigationBar),
          matching: find.byIcon(icon),
        );

    // 推进 tab 切换动画（300ms）直至停稳
    Future<void> settleTab() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 找到全部 TabNavigator（顺序即 _pages：首页/搜索/我的/设置）
    final tabs = tester
        .widgetList<TabNavigator>(find.byType(TabNavigator, skipOffstage: false))
        .toList();
    expect(tabs.length, greaterThanOrEqualTo(3), reason: '应有 4 个 tab');

    // A 侧：我的 tab（index 2）打开播放记录子页
    await tester.tap(navIcon(Icons.person_outline_rounded));
    await settleTab();
    await tester.tap(find.text('播放记录'));
    await settleTab();
    expect(find.byType(PlaybackStatsPage), findsOneWidget, reason: 'A 子页已打开');

    // B 侧：首页 tab（index 0）的 Navigator 直接 push 一个子页
    final homeTab = tabs[0];
    homeTab.navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('HOME-SUB'))),
      ),
    );
    await tester.pump();
    await settleTab();

    // 切到首页：B 子页可见
    await tester.tap(navIcon(Icons.home_outlined));
    await settleTab();
    expect(find.text('HOME-SUB'), findsOneWidget, reason: 'B 子页在首页可见');

    // 切回我的 tab
    await tester.tap(navIcon(Icons.person_outline_rounded));
    await settleTab();

    // 系统返回弹掉 A 的子页（播放记录）
    final handled = await tester.binding.handlePopRoute();
    await settleTab();
    expect(handled, isTrue, reason: '系统返回应被 tab Navigator 处理');
    expect(find.byType(PlaybackStatsPage), findsNothing, reason: 'A 子页被弹掉');

    // 切到首页：B 子页应保留
    await tester.tap(navIcon(Icons.home_outlined));
    await settleTab();
    expect(
      find.text('HOME-SUB', skipOffstage: false),
      findsOneWidget,
      reason: 'A 返回弹子页不应连累 B 的子页',
    );
  });

  testWidgets('A(我的)返回播放记录后，B(设置)的 in-page 详情应保留', (tester) async {
    // 窄屏（手机）：走底部导航栏
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

    // B 侧：设置 tab 打开「播放」详情（in-page _selected 状态）
    await tester.tap(navIcon(Icons.settings_outlined));
    await settleTab();
    await tester.tap(find.text('播放'));
    await settleTab();
    expect(find.text('音质'), findsOneWidget, reason: '设置详情已打开');

    // A 侧：我的 tab 打开播放记录
    await tester.tap(navIcon(Icons.person_outline_rounded));
    await settleTab();
    await tester.tap(find.text('播放记录'));
    await settleTab();
    expect(find.byType(PlaybackStatsPage), findsOneWidget, reason: 'A 子页已打开');

    // 切回设置：详情应先保留（验证 _PageSwitcher 不销毁 tab State）
    await tester.tap(navIcon(Icons.settings_outlined));
    await settleTab();
    expect(find.text('音质'), findsOneWidget, reason: 'B in-page 详情在切 tab 后保留');

    // 切回我的，返回弹掉 A 子页
    await tester.tap(navIcon(Icons.person_outline_rounded));
    await settleTab();
    final handled = await tester.binding.handlePopRoute();
    await settleTab();
    expect(handled, isTrue);
    expect(find.byType(PlaybackStatsPage), findsNothing, reason: 'A 子页被弹掉');

    // 切到设置：B in-page 详情应仍保留
    await tester.tap(navIcon(Icons.settings_outlined));
    await settleTab();
    expect(
      find.text('音质', skipOffstage: false),
      findsOneWidget,
      reason: 'A 返回弹子页后，B 的 in-page 详情不应丢失',
    );
  });
}
