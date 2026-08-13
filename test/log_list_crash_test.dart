import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/logging/app_crash.dart';
import 'package:fluxwave/core/logging/app_log.dart';
import 'package:fluxwave/pages/settings/sections/logs/log_list_page.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('crash_list_test');
    AppCrash.configureForTest(tempDir.path);
    // 造一个真实的崩溃日志文件。
    File(
      '${tempDir.path}${Platform.pathSeparator}crash_202608071234567.log',
    ).writeAsStringSync('=== Crash Report ===\nSource: Zone\nError: boom\n');
  });

  tearDown(() {
    AppCrash.resetForTest();
    for (var i = 0; i < 5 && tempDir.existsSync(); i++) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        sleep(const Duration(milliseconds: 20));
      }
    }
  });

  testWidgets('崩溃日志列表页展示崩溃文件并可进入详情', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: LogListPage(kind: LogSourceKind.crash)),
      );
      // listCrashLogFiles 的真实 IO 需在真实事件循环完成。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    // 等 loading 消失（spinner 是无限动画，不能用 pumpAndSettle）。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (tester.any(find.byType(CircularProgressIndicator)) == false) break;
    }

    expect(find.text('崩溃日志'), findsWidgets);
    // 加载后应显示文件名。
    final fileFinder = find.textContaining('crash_');
    expect(fileFinder, findsWidgets);
    expect(find.text('暂无崩溃日志'), findsNothing);

    // 点击进入详情页。
    await tester.tap(find.byType(ListTile).first, warnIfMissed: true);
    // 在真实事件循环里推进：既让路由过渡完成，也让详情页 initState 的真实 IO 完成。
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // 等详情页 loading 消失（spinner 是无限动画）。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (tester.any(find.byType(CircularProgressIndicator)) == false) break;
    }
    expect(find.textContaining('=== Crash Report ==='), findsWidgets);
  });
}
