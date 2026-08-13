import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/pages/home_page.dart';
import 'package:fluxwave/providers/home_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// 假客户端：回放预设推荐歌单响应（仅测首页，重放一次）。
class FakeHomeClient extends NeteaseClient {
  FakeHomeClient()
    : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  Object? response;

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    return response ?? const {'code': 404};
  }
}

/// 回归：下拉出刷新指示器（armed）后，同一手势再上拉，内容不得正向滚进视口。
/// 首页用 bouncing 语义承载下拉刷新：下拉内容随指示器下移（pixels<0）、
/// 再上拉收回即回顶（pixels=0），全程 pixels 不会越过顶部转为正滚动
/// （clamping 下会「反向即把内容正向滚入视口」）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<HomeProvider> loadedHome() async {
    final client = FakeHomeClient();
    final api = NeteaseApi(client);
    client.response = {
      'code': 200,
      'result': [
        for (var i = 0; i < 24; i++)
          {'id': 9000000000 + i, 'name': '歌单 $i', 'trackCount': 12},
      ],
    };
    final home = HomeProvider();
    await home.load(api);
    return home;
  }

  Future<void> pumpHome(WidgetTester tester, HomeProvider home) async {
    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();
    final netease = NeteaseProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: netease),
          ChangeNotifierProvider.value(value: home),
        ],
        child: MaterialApp(theme: theme.lightTheme, home: const HomePage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  double pixels(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

  testWidgets('armed 阶段同手势上拉，内容位置保持 <= 顶部，不正向滚动', (tester) async {
    final home = await loadedHome();
    await pumpHome(tester, home);

    final g = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await g.moveBy(Offset(0, 80)); // 下拉 → 内容下移 + 指示器浮现
    await tester.pump(const Duration(milliseconds: 50));
    final armedPixels = pixels(tester);

    await g.moveBy(Offset(0, -80)); // 同一手势反向 → 上拉收回
    await tester.pump(const Duration(milliseconds: 50));
    final afterUpPixels = pixels(tester);

    await g.up();
    await tester.pumpAndSettle();

    expect(armedPixels, lessThan(0), reason: 'armed 期间内容随下拉下移（bounce 语义）');
    expect(
      afterUpPixels,
      lessThanOrEqualTo(0),
      reason: 'armed 上拉只收回内容，不得正向滚动进视口',
    );
    expect(pixels(tester), 0, reason: '松手归位后应停在顶部');
  });
}
