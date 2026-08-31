import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/models/artist.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/pages/player_page.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// 歌词页上下滑动手势冲突回归：竖直滚动歌词不应误触发 播放页⇄歌词页 的水平
/// 切换。歌词页外层有 onHorizontalDrag 切换手势，真实手指滑动总有轻微横向
/// 漂移，若不做方向分流，滚动歌词时容易误切回播放页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const song = Song(
    id: 1,
    name: '测试歌曲',
    artists: [ArtistSummary(id: 0, name: '测试歌手')],
    coverUrl: null,
    durationMs: 345000,
    fee: 0,
  );

  Future<void> pumpPlayer(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();
    final netease = NeteaseProvider();
    await netease.init();
    final player = PlayerProvider(
      netease: netease,
      settings: settings,
      liked: LikedSongsProvider(),
      networkRetryAttempts: 0,
    );
    player.init();
    await tester.runAsync(() => player.playAt([song], 0));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: netease),
          ChangeNotifierProvider.value(value: player),
          ChangeNotifierProvider(create: (_) => LikedSongsProvider()),
        ],
        child: Consumer<ThemeProvider>(
          builder: (_, tp, _) => MaterialApp(
            theme: tp.lightTheme,
            home: const PlayerPage(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  }

  /// 顶部栏歌词切换按钮的图标只会在 setState/整树重建时更新（不随动画逐帧
  /// 重建），故用轻微改 viewport 强制一次重建后再断言当前所处模式。
  Future<IconData> lyricsIcon(WidgetTester tester) async {
    tester.view.physicalSize = const Size(361, 800);
    await tester.pump();
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    final tips = find.byTooltip('歌词').evaluate().isNotEmpty
        ? find.byTooltip('歌词')
        : find.byTooltip('关闭歌词');
    final icons = tester
        .widgetList<Icon>(find.descendant(of: tips, matching: find.byType(Icon)))
        .toList();
    return icons.single.icon!;
  }

  testWidgets('歌词页竖直滚动：不应误切回播放页', (tester) async {
    await pumpPlayer(tester);

    // 进入歌词页（t=1）
    await tester.tap(find.byTooltip('歌词'));
    await tester.pump(); // 启动动画 ticker 的基线帧
    await tester.pump(const Duration(milliseconds: 400)); // 推进到完成
    expect(await lyricsIcon(tester), Icons.lyrics_rounded, reason: '应处于歌词页');

    // 歌词面板区域竖直滚动（带明显横向漂移，模拟真实手指滚动时的抖动；
    // 无方向分流时该横移足以误切回播放页）
    final empty = find.text('暂无歌词');
    if (empty.evaluate().isNotEmpty) {
      await tester.drag(empty, const Offset(90, -300), warnIfMissed: false);
    } else {
      await tester.dragFrom(const Offset(180, 500), const Offset(90, -300));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(await lyricsIcon(tester), Icons.lyrics_rounded, reason: '竖直滚动歌词不应切回播放页');
  });
}