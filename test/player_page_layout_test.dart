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

/// PlayerPage 全屏页**实歌场景**回归：多种屏幕尺寸 × 超大字号下渲染有真实曲目
/// 的完整布局（封面/标题/进度条/控制按钮/音质行），断言无 RenderFlex overflow。
///
/// 区别于 [layout_overflow_test] 里 PlayerPage 的空态，这里专门覆盖有歌的路径。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> setViewSize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  const scales = <TextScaler>[TextScaler.noScaling, TextScaler.linear(2)];
  const sizes = [
    Size(280, 480), // 极窄小屏（播放页最小受测宽度）
    Size(320, 568), // 窄屏小手机
    Size(360, 800), // 主流手机
    Size(1280, 800), // 桌面/宽屏
  ];

  const song = Song(
    id: 1,
    name: '一首标题非常非常长需要被省略展示的示例歌曲名称测试贯穿省略',
    artists: [ArtistSummary(id: 0, name: '歌手甲'), ArtistSummary(id: 0, name: '歌手乙'), ArtistSummary(id: 0, name: '歌手丙')],
    coverUrl: 'https://example.com/cover.png',
    durationMs: 345000,
    fee: 0,
  );

  testWidgets('实歌内容：多种尺寸 × 超大字号渲染无溢出', (tester) async {
    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();
    final netease = NeteaseProvider();
    await netease.init();

    for (final size in sizes) {
      for (final scale in scales) {
        final player = PlayerProvider(
          netease: netease,
          settings: settings,
          liked: LikedSongsProvider(),
          networkRetryAttempts: 0,
        );
        player.init();
        // 实歌走网络解析（测试环境被屏蔽，会快速落入 NoPlayableUrlException），
        // 用 runAsync 让真实异步完成，避免 fake async 下挂起。
        await tester.runAsync(() => player.playAt([song], 0));

        await setViewSize(tester, size);
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
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: scale),
                    child: const PlayerPage(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        final factor = scale.scale(10) / 10;
        expect(
          tester.takeException(),
          isNull,
          reason:
              'PlayerPage 实歌 @${size.width.toInt()}x${size.height.toInt()}'
              ' scale=${factor.toStringAsFixed(1)}',
        );
      }
    }
  });
}
