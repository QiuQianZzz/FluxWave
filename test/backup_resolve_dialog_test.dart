import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/backup_service.dart';
import 'package:fluxwave/widgets/backup_resolve_dialog.dart';

void main() {
  const playlistsConflicts = <BackupItem, List<String>>{
    BackupItem.playlists: ['备份新增 1 项：歌曲C', '本地独有 2 项：歌曲A、歌曲B'],
  };

  Map<BackupItem, ConflictStrategy>? result;

  Future<void> openDialog(
    WidgetTester tester, {
    Map<BackupItem, List<String>>? conflicts,
  }) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  result = await BackupResolveDialog.show(
                    context,
                    conflicts ?? playlistsConflicts,
                  );
                },
                child: const Text('打开弹窗'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();
  }

  testWidgets('默认选中「合并」，确认后返回 merge', (tester) async {
    await openDialog(tester);

    expect(find.text('数据冲突'), findsOneWidget);
    expect(find.textContaining('备份新增 1 项：歌曲C'), findsOneWidget);
    expect(find.textContaining('本地独有 2 项'), findsOneWidget);

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, {BackupItem.playlists: ConflictStrategy.merge});
  });

  testWidgets('点「覆盖」分段可切换，确认后返回 overwrite（回归：分段点击须生效）', (tester) async {
    await openDialog(tester);

    await tester.tap(find.text('覆盖'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, {BackupItem.playlists: ConflictStrategy.overwrite});
  });

  testWidgets('选「跳过」后该项不进入返回结果', (tester) async {
    await openDialog(tester);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, isEmpty);
  });

  testWidgets('设置项只有 跳过/合并，无「覆盖」，且展示合并语义提示', (tester) async {
    await openDialog(tester, conflicts: {
      BackupItem.settings: ['theme_mode（内容不同）'],
    });

    expect(find.text('覆盖'), findsNothing);
    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('合并'), findsOneWidget);
    expect(find.textContaining('选「合并」会用备份中的值覆盖本地对应项'), findsOneWidget);

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, {BackupItem.settings: ConflictStrategy.merge});
  });

  testWidgets('取消返回 null', (tester) async {
    await openDialog(tester);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
