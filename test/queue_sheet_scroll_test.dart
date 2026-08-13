import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';
import 'package:fluxwave/widgets/queue_sheet.dart';

/// 播放队列面板「视图切换滚动定位」回归：
/// 切到随机顺序视图后，列表应自动滚动到当前播放项（与初始打开一致），
/// 而不是停在切换前的滚动位置。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Song song(int id) => Song(
    id: id,
    name: '歌$id',
    artists: const ['甲'],
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
    );
    player.init();
    return player;
  }

  Widget app({
    required ThemeProvider theme,
    required PlayerProvider player,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: player),
      ],
      child: Consumer<ThemeProvider>(
        builder: (_, tp, _) => MaterialApp(
          theme: tp.lightTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => QueueSheet.show(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('切到随机视图自动滚动到当前项', (tester) async {
    final player = await makePlayer();
    // 20 首：随机视图下当前项位置足够深，若未滚动则不可见。
    final ids = List.generate(20, (i) => i + 1);
    unawaited(player.playAt(ids.map(song).toList(), 0));
    player.toggleShuffle();

    final theme = ThemeProvider()..init();
    await tester.pumpWidget(app(theme: theme, player: player));
    await tester.pump(const Duration(milliseconds: 50));

    // 打开队列面板（shuffle 开启，默认显示原始序）
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 原始序视图 → 按钮文案为「按随机顺序」
    expect(find.text('按随机顺序'), findsOneWidget);

    // 切到随机视图：应自动滚动到当前项（随机序里当前歌锚定在首位附近）
    await tester.tap(find.text('按随机顺序'));
    await tester.pumpAndSettle();

    final displayIndex = player.displayIndex;
    final expected =
        (displayIndex - 2).clamp(0, player.displayQueue.length - 1) * 58.0;
    final state = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(QueueSheet),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      state.position.pixels,
      closeTo(expected, 2.0),
      reason: '切到随机视图后应滚动到当前项位置($expected)',
    );
  });

  testWidgets('随机视图切回原始视图也重新定位当前项', (tester) async {
    final player = await makePlayer();
    final ids = List.generate(20, (i) => i + 1);
    unawaited(player.playAt(ids.map(song).toList(), 0));
    player.toggleShuffle();

    final theme = ThemeProvider()..init();
    await tester.pumpWidget(app(theme: theme, player: player));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 原始序 → 随机序
    await tester.tap(find.text('按随机顺序'));
    await tester.pumpAndSettle();

    // 随机序 → 原始序：重新定位到原始序的 currentIndex
    await tester.tap(find.text('按原始顺序'));
    await tester.pumpAndSettle();

    final expected =
        ((player.currentIndex ?? 0) - 2).clamp(0, player.queue.length - 1) *
        58.0;
    final state = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(QueueSheet),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      state.position.pixels,
      closeTo(expected, 58.0),
      reason: '切回原始视图后应滚动到当前项位置($expected)',
    );
  });
}
