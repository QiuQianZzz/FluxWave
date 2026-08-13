import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/logging/app_log.dart';
import 'package:fluxwave/pages/settings/sections/logs/log_detail_page.dart';

void main() {
  late Directory tempDir;
  late LogFileMetadata meta;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('log_detail_test');
    final f = File('${tempDir.path}${Platform.pathSeparator}2026-08-07.log')
      ..writeAsStringSync(
        '[INFO] 2026-08-07 10:00:00 queue restored\n'
        '[ERROR] 2026-08-07 10:00:01 failed url\n'
        '[WARN] 2026-08-07 10:00:02 retry\n'
        '    at some.stack.frame\n'
        '[DEBUG] 2026-08-07 10:00:03 detail\n',
      );
    meta = LogFileMetadata(
      name: '2026-08-07.log',
      path: f.path,
      sizeBytes: f.lengthSync(),
      modified: DateTime.now(),
      date: '2026-08-07',
    );
  });

  tearDown(() {
    AppLog.resetForTest();
    // Windows 下文件可能仍被句柄占用：重试几次。
    for (var i = 0; i < 5 && tempDir.existsSync(); i++) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // 稍后重试
        sleep(const Duration(milliseconds: 20));
      }
    }
  });

  Future<void> pumpDetail(WidgetTester tester) async {
    // initState 里 readLogFile 的真实 IO 需在真实事件循环完成：
    // 把整个 pump 包进 runAsync，让 _load 的 future 能推进。
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: LogDetailPage(file: meta)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    // 等 loading 消失（spinner 是无限动画，不能用 pumpAndSettle 等它自己停）。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (tester.any(find.byType(CircularProgressIndicator)) == false) break;
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }

  testWidgets('筛选菜单多选不自动关闭，取消勾选后对应级别隐藏', (tester) async {
    await pumpDetail(tester);

    // 默认全选：五类行都在（含堆栈续行）。
    expect(find.textContaining('queue restored'), findsOneWidget);
    expect(find.textContaining('failed url'), findsOneWidget);
    expect(find.textContaining('retry'), findsOneWidget);
    expect(find.textContaining('some.stack.frame'), findsOneWidget);

    // 打开筛选菜单。
    await tester.tap(find.byIcon(Icons.filter_list_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ERROR 级'), findsOneWidget);

    // 取消勾选 ERROR（第一次点击）。
    await tester.tap(find.text('ERROR 级'));
    await tester.pump(const Duration(milliseconds: 100));
    // 菜单仍未关闭：能继续看到其他级别项。
    expect(find.text('WARN 级'), findsOneWidget);
    expect(find.text('INFO 级'), findsOneWidget);

    // 再取消勾选 DEBUG（第二次点击，验证菜单保持打开、可连续操作）。
    await tester.tap(find.text('DEBUG 级'));
    await tester.pump(const Duration(milliseconds: 100));

    // 关闭菜单后验证：ERROR/DEBUG 行被隐藏，WARN/INFO/堆栈行仍显示。
    await tester.tapAt(const Offset(200, 400)); // 菜单外部区域
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('failed url'), findsNothing);
    expect(find.textContaining('detail'), findsNothing);
    expect(find.textContaining('queue restored'), findsOneWidget);
    expect(find.textContaining('retry'), findsOneWidget);
    expect(find.textContaining('some.stack.frame'), findsOneWidget);
  });
}
