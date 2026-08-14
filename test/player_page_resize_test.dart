import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/pages/player_page.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// PlayerPage 宽窄屏分支切换的回归测试：
/// 1. 运行中跨 600px 断点反复缩放，分支在 `_buildWideContent` 与
///    AnimatedBuilder 插值布局间切换，不产生布局异常。
/// 2. 全程宽屏直接卸载：`_lyricsTransition` 全程不被引用，initState 显式初始化
///    规避 flutter#153644（SDK 3.44.2 未含 #185248 修复）在 dispose 期首访
///    `late final` AnimationController 时的 TickerMode ancestor 崩溃。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const song = Song(
    id: 1,
    name: 'Demo Song',
    artists: ['Demo Artist'],
    coverUrl: 'https://example.com/cover.png',
    durationMs: 345000,
    fee: 0,
  );

  Widget buildApp({
    required SettingsProvider settings,
    required ThemeProvider theme,
    required NeteaseProvider netease,
    required PlayerProvider player,
  }) {
    return MultiProvider(
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
    );
  }

  Future<(SettingsProvider, ThemeProvider, NeteaseProvider, PlayerProvider)>
  setup() async {
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
    return (settings, theme, netease, player);
  }

  testWidgets('运行中宽↔窄跨断点缩放无 TickerMode ancestor 异常', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final (settings, theme, netease, player) = await setup();
    await tester.runAsync(() => player.playAt([song], 0));

    // 初始窄屏渲染
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpWidget(
      buildApp(settings: settings, theme: theme, netease: netease, player: player),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: '初始窄屏渲染');

    final sizes = [
      Size(1280, 800), // 宽
      Size(400, 800), // 窄
      Size(1024, 768), // 宽
      Size(340, 700), // 窄
      Size(1920, 1080), // 宽
      Size(390, 844), // 窄
    ];
    for (final size in sizes) {
      tester.view.physicalSize = size;
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.takeException(),
        isNull,
        reason: '缩放至 ${size.width.toInt()}x${size.height.toInt()} 后应有异常',
      );
    }

    // 快速连续跨断点：不插帧直接改尺寸，强制同帧 element 移动（re-parent 路径）
    const rapid = [Size(360, 800), Size(1280, 800), Size(360, 800), Size(1280, 800)];
    for (var i = 0; i < rapid.length; i++) {
      tester.view.physicalSize = rapid[i];
    }
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.takeException(),
      isNull,
      reason: '同帧连续跨断点后应有异常',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '动画结束收尾');
  });

  testWidgets('全程宽屏从未引用歌词控制器，卸载不触发 TickerMode ancestor 异常', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final (settings, theme, netease, player) = await setup();
    await tester.runAsync(() => player.playAt([song], 0));

    // 直接以宽屏进入：`_lyricsTransition` 全程不被 AnimatedBuilder / 歌词按钮引用。
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(
      buildApp(settings: settings, theme: theme, netease: netease, player: player),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: '宽屏渲染');

    // 卸载页面：若控制器是 `late final` 惰性，dispose 首访 → flutter#153644 崩溃。
    await tester.pumpWidget(const SizedBox());
    expect(
      tester.takeException(),
      isNull,
      reason: '宽屏直接卸载 PlayerPage 不应有 TickerMode ancestor 异常'
          '（flutter#153644，SDK 3.44.2 未含 #185248 修复）',
    );
  });
}
