import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/main.dart';
import 'package:fluxwave/pages/home_page.dart';
import 'package:fluxwave/pages/search_page.dart';
import 'package:fluxwave/providers/settings_provider.dart';

void main() {
  testWidgets('MainScaffold renders bottom nav and home tab', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.init();
    await tester.pumpWidget(FluxWaveApp(settings: settings));
    await tester.pumpAndSettle();
    // 首页推荐歌单启动错峰 300ms：让出整树初始化的首包时间，测试里同样需要
    // 推进这段延时才能放掉定时器（否则 teardown 报 pending timer）。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 首页 Tab 可见
    expect(find.text('FluxWave'), findsWidgets);
    // 底部导航三个 Tab
    expect(find.text('首页'), findsWidgets);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('桌面宽屏：tab 常驻，切走不卸载、切回保留', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.init();
    await tester.pumpWidget(FluxWaveApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 当前是首页：搜索页处于 Offstage（默认 finder 不可见，但已常驻挂树）
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(SearchPage), findsNothing);
    expect(find.byType(SearchPage, skipOffstage: false), findsOneWidget);

    // 切到搜索：搜索页上屏，首页 Offstage 常驻
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
    expect(find.byType(HomePage, skipOffstage: false), findsOneWidget);

    // 切回首页：常驻保证 State/返回栈未被销毁
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(SearchPage, skipOffstage: false), findsOneWidget);
  });
}
