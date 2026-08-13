import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:fluxwave/pages/settings/sections/network_section.dart';
import 'package:fluxwave/providers/settings_provider.dart';

/// 网络与风控设置 section 的平台门控测试。
void main() {
  Future<void> pump(WidgetTester tester, TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider(),
        child: const MaterialApp(home: Scaffold(body: NetworkSection())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('非 Android：显示「使用系统/环境代理」与「注入国内 IP」', (tester) async {
    try {
      await pump(tester, TargetPlatform.windows);
      expect(find.text('使用系统/环境代理'), findsOneWidget);
      expect(find.text('注入国内 IP'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android：隐藏代理与 IP 注入开关（恒直连门控）', (tester) async {
    try {
      await pump(tester, TargetPlatform.android);
      expect(find.text('使用系统/环境代理'), findsNothing);
      expect(find.text('注入国内 IP'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
