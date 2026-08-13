import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/pages/settings/sections/icon_section.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// 桌面图标选择面板的切换逻辑测试（底部面板点选 → launcherIconId 变更）。
void main() {
  testWidgets('面板预览可点选切换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.init();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: ThemeProvider()..init()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showLauncherIconPickerSheet(context),
                  child: const Text('选择图标'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 打开面板
    await tester.tap(find.text('选择图标'));
    await tester.pumpAndSettle();
    expect(find.text('默认图标'), findsOneWidget);
    expect(find.text('备选图标'), findsOneWidget);
    expect(settings.launcherIconId, 'default');

    // 选备选：需先确认
    await tester.tap(find.text('备选图标'));
    await tester.pumpAndSettle();
    expect(find.text('切换桌面图标'), findsOneWidget);
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(settings.launcherIconId, 'alt');

    // 取消：保持当前
    await tester.tap(find.text('默认图标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(settings.launcherIconId, 'alt');

    // 确认切回默认
    await tester.tap(find.text('默认图标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(settings.launcherIconId, 'default');
  });
}
