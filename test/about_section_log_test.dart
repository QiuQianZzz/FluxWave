import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/logging/app_log.dart';
import 'package:fluxwave/pages/settings/sections/about_section.dart';
import 'package:fluxwave/pages/settings/sections/logs/log_list_page.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'canLaunch') return true;
        if (methodCall.method == 'launch') return true;
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  testWidgets('关于页：日志开关默认开启并可切换，管理日志进入列表页', (tester) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.init();

    AppLog.setUserEnabled(true);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: ThemeProvider()..init()),
        ],
        child: const MaterialApp(home: Scaffold(body: AboutSection())),
      ),
    );
    // 先 pump 多帧确保 widget tree 完成构建
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('记录日志'), findsOneWidget);

    expect(settings.logEnabled, isTrue);

    await tester.tap(find.text('记录日志'));
    await tester.pumpAndSettle();
    expect(settings.logEnabled, isFalse);
    expect(AppLog.userEnabled, isFalse);

    await tester.tap(find.text('记录日志'));
    await tester.pumpAndSettle();
    expect(settings.logEnabled, isTrue);
    expect(AppLog.userEnabled, isTrue);

    await tester.tap(find.text('运行日志'));
    await tester.pumpAndSettle();
    final list = tester.widget<LogListPage>(find.byType(LogListPage));
    expect(list.kind, LogSourceKind.runtime);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('崩溃日志'));
    await tester.pumpAndSettle();
    final crashList = tester.widget<LogListPage>(find.byType(LogListPage));
    expect(crashList.kind, LogSourceKind.crash);
    expect(find.text('崩溃日志'), findsWidgets);
  });
}
