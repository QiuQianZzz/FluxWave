import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/logging/app_log.dart';
import 'package:fluxwave/pages/settings/sections/about_section.dart';
import 'package:fluxwave/pages/settings/sections/logs/log_list_page.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

void main() {
  testWidgets('关于页：日志开关默认开启并可切换，管理日志进入列表页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.init();

    // 默认 AppLog 用户开关也是开启态。
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
    await tester.pump();

    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('记录日志'), findsOneWidget);

    // 默认开启。
    expect(settings.logEnabled, isTrue);

    // 关闭开关 → 持久化 + 同步 AppLog。
    await tester.tap(find.text('记录日志'));
    await tester.pumpAndSettle();
    expect(settings.logEnabled, isFalse);
    expect(AppLog.userEnabled, isFalse);

    // 再开回来。
    await tester.tap(find.text('记录日志'));
    await tester.pumpAndSettle();
    expect(settings.logEnabled, isTrue);
    expect(AppLog.userEnabled, isTrue);

    // 「运行日志」应 push 到日志列表页（运行日志 kind）。
    await tester.tap(find.text('运行日志'));
    await tester.pumpAndSettle();
    final list = tester.widget<LogListPage>(find.byType(LogListPage));
    expect(list.kind, LogSourceKind.runtime);
    // 返回后点「崩溃日志」。
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('崩溃日志'));
    await tester.pumpAndSettle();
    final crashList = tester.widget<LogListPage>(find.byType(LogListPage));
    expect(crashList.kind, LogSourceKind.crash);
    expect(find.text('崩溃日志'), findsWidgets);
  });
}
