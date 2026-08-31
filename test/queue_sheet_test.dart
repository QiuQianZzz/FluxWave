import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/models/artist.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/widgets/queue_sheet.dart';

/// 播放队列面板样式回归：行首序号、标题区（标题+数量+定位按钮）、
/// 右下角悬浮快捷操作（清空/顺序切换）。
///
/// 测试假设同 player_mode_test：playAt 的队列/索引在同步段生效，断言先于
/// 自动跳过链导致的索引变化；结束时 pump 推进防抖落盘，不调用 dispose。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Song song(int id) => Song(
    id: id,
    name: '歌$id',
    artists: const [ArtistSummary(id: 0, name: '甲')],
    coverUrl: null,
    durationMs: 200000,
    fee: 0,
  );

  Future<PlayerProvider> makePlayer() async {
    final settings = SettingsProvider();
    await settings.init();
    final netease = NeteaseProvider();
    await netease.init();
    final player = PlayerProvider(
      netease: netease,
      settings: settings,
      liked: LikedSongsProvider(),
      networkRetryAttempts: 0,
    );
    player.init();
    return player;
  }

  /// 铺一个 3 首队列、当前在第 1 首的播放面板。
  Future<PlayerProvider> pumpSheet(
    WidgetTester tester, {
    PlayerProvider? provider,
  }) async {
    final player = provider ?? await makePlayer();
    if (provider == null) {
      unawaited(player.playAt([song(1), song(2), song(3)], 0));
    }
    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player,
        child: const MaterialApp(home: Scaffold(body: QueueSheet())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return player;
  }

  testWidgets('标题区：标题+数量分列上下，右侧定位按钮显示当前位置', (tester) async {
    await pumpSheet(tester);

    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('共 3 首'), findsOneWidget);
    expect(find.text('第 1 首'), findsOneWidget);
    // 行首序号（与歌曲名/时长的整段文本精确匹配，不会误中）
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // 当前项行尾播放指示（graphic_eq 或 pause 二选一）
    expect(
      find.byIcon(Icons.graphic_eq_rounded).evaluate().isNotEmpty ||
          find.byIcon(Icons.pause_rounded).evaluate().isNotEmpty,
      isTrue,
      reason: '当前播放项应显示行尾播放/暂停指示',
    );

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('点击第 3 行跳转播放，定位按钮更新为第 3 首', (tester) async {
    await pumpSheet(tester);

    await tester.tap(find.text('歌3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('第 3 首'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('空队列：显示空态提示，无序号、无定位按钮、无悬浮按钮', (tester) async {
    final player = await makePlayer();
    await pumpSheet(tester, provider: player);

    expect(find.text('播放列表为空'), findsOneWidget);
    expect(find.text('共 0 首'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(find.textContaining('第 '), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('悬浮按钮：默认收起，展开后露出清空队列', (tester) async {
    await pumpSheet(tester);

    // 收起态：看不到快捷项
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('清空队列'), findsNothing);
    expect(find.text('清空'), findsNothing);

    // 展开 → 露出「清空队列」
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('清空队列'), findsOneWidget);

    // 点击清空 → 弹确认框
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('确定清空当前播放列表吗？将停止播放。'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('随机模式：悬浮按钮可切换原始/随机视图', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1), song(2), song(3), song(4)], 0));
    player.toggleShuffle();
    await pumpSheet(tester, provider: player);

    // 展开悬浮按钮 → 有「按随机顺序」（当前为原始序视图）与清空
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('按随机顺序'), findsOneWidget);
    expect(find.text('清空队列'), findsOneWidget);

    // 点击切换到随机视图 → 按钮文案反转
    await tester.tap(find.byIcon(Icons.swap_horiz_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('按原始顺序'), findsOneWidget);
    // 随机视图下仍显示当前项定位按钮
    expect(find.textContaining('第 '), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
  });
}
