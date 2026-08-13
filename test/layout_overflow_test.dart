import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/pages/home_page.dart';
import 'package:fluxwave/pages/main_scaffold.dart';
import 'package:fluxwave/pages/player_page.dart';
import 'package:fluxwave/pages/profile_page.dart';
import 'package:fluxwave/pages/radar/radar_page.dart';
import 'package:fluxwave/pages/search_page.dart';
import 'package:fluxwave/pages/settings/sections/about_section.dart';
import 'package:fluxwave/pages/settings/sections/account_section.dart';
import 'package:fluxwave/pages/settings/sections/network_section.dart';
import 'package:fluxwave/pages/settings/sections/play_section.dart';
import 'package:fluxwave/pages/settings/sections/storage_section.dart';
import 'package:fluxwave/pages/settings/sections/theme_section.dart';
import 'package:fluxwave/pages/settings/settings_page.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/playlist_provider.dart';
import 'package:fluxwave/providers/home_provider.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/radar_provider.dart';
import 'package:fluxwave/providers/search_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// 布局溢出回归：在不同屏幕尺寸与超大字号下渲染各页，断言无 RenderFlex overflow。
///
/// 目的：不用逐台真机测试，这里用多种 viewport 尺寸 × 大字体（2x）
/// 一次覆盖所有页面，任何固定尺寸/硬约束导致的溢出都会在此失败。
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

  Widget buildShell(
    Widget home,
    TextScaler scale, {
    required SettingsProvider settings,
    required ThemeProvider theme,
    required NeteaseProvider netease,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: netease),
        ChangeNotifierProvider(create: (_) => LikedSongsProvider()),
        ChangeNotifierProvider(
          create: (ctx) => PlayerProvider(
            netease: ctx.read<NeteaseProvider>(),
            settings: ctx.read<SettingsProvider>(),
            liked: ctx.read<LikedSongsProvider>(),
          )..init(),
        ),
        ChangeNotifierProvider(create: (_) => SearchProvider()),
        ChangeNotifierProvider(create: (_) => PlaylistProvider()),
        ChangeNotifierProvider(create: (_) => HomeProvider()),
        ChangeNotifierProvider(create: (_) => RadarProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (_, tp, _) => MaterialApp(
          theme: tp.lightTheme,
          // 覆盖子树 textScaler：模拟系统超大字体导致的溢出风险。
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: scale),
              child: home,
            ),
          ),
        ),
      ),
    );
  }

  const scales = <TextScaler>[TextScaler.noScaling, TextScaler.linear(2)];
  const sizes = [
    Size(320, 568), // 窄屏小手机
    Size(360, 800), // 主流手机
    Size(1280, 800), // 桌面/宽屏
  ];

  /// 在导航容器（NavigationBar 或侧边栏 ListView）内查找图标，
  /// 避免与页面内容中的同名图标（如设置页的 person_outline_rounded）冲突。
  Finder navIconFinder(IconData icon) {
    final navBar = find.byType(NavigationBar);
    if (navBar.evaluate().isNotEmpty) {
      return find.descendant(of: navBar, matching: find.byIcon(icon));
    }
    // 宽屏侧边栏：nav tile 在 ListView 内
    final list = find.byType(ListView);
    if (list.evaluate().isNotEmpty) {
      return find.descendant(of: list, matching: find.byIcon(icon));
    }
    return find.byIcon(icon);
  }

  testWidgets('整机：不同尺寸下渲染 + 切换各 Tab，无布局溢出', (tester) async {
    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();
    final netease = NeteaseProvider();

    for (final size in sizes) {
      await setViewSize(tester, size);
      // 用 ValueKey 强制每个尺寸重建 MainScaffold State，
      // 避免 _currentIndex 跨尺寸残留导致 settings 页与导航栏图标重复。
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider(create: (_) => theme),
            ChangeNotifierProvider(create: (_) => netease),
            ChangeNotifierProvider(create: (_) => LikedSongsProvider()),
            ChangeNotifierProvider(
              create: (ctx) => PlayerProvider(
                netease: ctx.read<NeteaseProvider>(),
                settings: ctx.read<SettingsProvider>(),
                liked: ctx.read<LikedSongsProvider>(),
              )..init(),
            ),
            ChangeNotifierProvider(create: (_) => SearchProvider()),
            ChangeNotifierProvider(create: (_) => PlaylistProvider()),
            ChangeNotifierProvider(create: (_) => HomeProvider()),
            ChangeNotifierProvider(create: (_) => RadarProvider()),
          ],
          child: MaterialApp(
            theme: theme.lightTheme,
            home: MainScaffold(key: ValueKey(size)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull, reason: '首页@$size');

      // 依次切到 搜索 / 我的 / 设置（用未选中图标点击，两种导航模式通用）
      for (final icon in const [
        Icons.search_outlined,
        Icons.person_outline_rounded,
        Icons.settings_outlined,
      ]) {
        final target = navIconFinder(icon);
        if (target.evaluate().isNotEmpty) {
          await tester.tap(target);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$icon @$size');
        }
      }
    }
  });

  testWidgets('逐页：多种尺寸 × 超大字号渲染无溢出', (tester) async {
    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();
    final netease = NeteaseProvider();
    // 确保 loading=false，Profile 渲染真实内容而非无限 spinner
    await netease.init();

    final pages = <String, Widget>{
      'HomePage': const HomePage(),
      'SearchPage': const SearchPage(),
      'ProfilePage': const ProfilePage(),
      'PlayerPage': const PlayerPage(),
      'RadarPage': const RadarPage(),
    };

    for (final entry in pages.entries) {
      for (final size in sizes) {
        for (final scale in scales) {
          await setViewSize(tester, size);
          await tester.pumpWidget(
            buildShell(
              entry.value,
              scale,
              settings: settings,
              theme: theme,
              netease: netease,
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          final factor = scale.scale(10) / 10;
          expect(
            tester.takeException(),
            isNull,
            reason:
                '${entry.key} @${size.width.toInt()}x${size.height.toInt()}'
                ' scale=${factor.toStringAsFixed(1)}',
          );
        }
      }
    }
  });

  testWidgets('设置子页面：多种尺寸 × 超大字号渲染无溢出', (tester) async {
    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();
    final netease = NeteaseProvider();
    await netease.init();

    // 各 settings section 的 builder，包在 Scaffold 内模拟详情页环境
    final sections = <String, WidgetBuilder>{
      'ThemeSection': ThemeSection.builder,
      'PlaySection': PlaySection.builder,
      'StorageSection': StorageSection.builder,
      'NetworkSection': NetworkSection.builder,
      'AccountSection': AccountSection.builder,
      'AboutSection': AboutSection.builder,
    };

    for (final entry in sections.entries) {
      for (final size in sizes) {
        for (final scale in scales) {
          await setViewSize(tester, size);
          await tester.pumpWidget(
            buildShell(
              Scaffold(
                body: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 20, 4),
                        child: Row(
                          children: [
                            const IconButton(
                              icon: Icon(Icons.arrow_back_rounded),
                              onPressed: null,
                            ),
                            Flexible(
                              child: Text(
                                entry.key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.lightTheme.textTheme.headlineSmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: Builder(builder: entry.value)),
                    ],
                  ),
                ),
              ),
              scale,
              settings: settings,
              theme: theme,
              netease: netease,
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          final factor = scale.scale(10) / 10;
          expect(
            tester.takeException(),
            isNull,
            reason:
                '${entry.key} @${size.width.toInt()}x${size.height.toInt()}'
                ' scale=${factor.toStringAsFixed(1)}',
          );
        }
      }
    }
  });

  testWidgets('SettingsPage：列表 ↔ 详情切换无溢出', (tester) async {
    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();
    final netease = NeteaseProvider();
    await netease.init();

    for (final size in sizes) {
      await setViewSize(tester, size);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider(create: (_) => theme),
            ChangeNotifierProvider(create: (_) => netease),
          ],
          child: Consumer<ThemeProvider>(
            builder: (_, tp, _) => MaterialApp(
              theme: tp.lightTheme,
              home: SettingsPage(key: ValueKey(size)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'SettingsList@$size');

      // 点击第一个设置项进入详情
      final firstTile = find.byType(ListTile);
      if (firstTile.evaluate().isNotEmpty) {
        await tester.tap(firstTile.first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'SettingsDetail@$size');
      }
    }
  });
}
