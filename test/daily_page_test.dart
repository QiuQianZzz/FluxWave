import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/pages/daily/daily_page.dart';
import 'package:fluxwave/providers/daily_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// 假客户端：回放每日推荐响应。
class FakeDailyClient extends NeteaseClient {
  FakeDailyClient()
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

Map<String, dynamic> _song(int id, String name) => {
  'id': id,
  'name': name,
  'ar': [
    {'name': '歌手$id'},
  ],
  'al': {
    'id': id,
    'name': '专辑$id',
    'picUrl': 'https://p1.music.126.net/mock/$id.jpg',
  },
  'dt': 210000,
  'fee': 0,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpDailyPage(WidgetTester tester, {Object? response}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final client = FakeDailyClient()..response = response;
    final api = NeteaseApi(client);
    final daily = DailyProvider();
    // 进入页面前完成拉取，页面 postFrame 看到已 loaded 不再触发网络请求，
    // 渲染路径与实际加载态一致。
    await daily.load(api);

    final settings = SettingsProvider();
    await settings.init();
    final theme = ThemeProvider()..init();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: NeteaseProvider()),
          ChangeNotifierProvider.value(value: daily),
        ],
        child: MaterialApp(theme: theme.lightTheme, home: const DailyPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('已加载：头部 + 歌曲列表渲染无溢出', (tester) async {
    await pumpDailyPage(
      tester,
      response: {
        'code': 200,
        'data': {
          'dailySongs': [_song(1, '日推A'), _song(2, '日推B')],
        },
      },
    );

    expect(tester.takeException(), isNull);
    expect(find.text('每日推荐'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.text('日推A'), findsOneWidget);
    expect(find.text('日推B'), findsOneWidget);
  });

  testWidgets('空列表：空态文案', (tester) async {
    await pumpDailyPage(
      tester,
      response: {
        'code': 200,
        'data': {'dailySongs': <Object>[]},
      },
    );
    expect(tester.takeException(), isNull);
    expect(find.text('今天还没有每日推荐'), findsOneWidget);
  });

  testWidgets('加载失败：错误态 + 重试按钮', (tester) async {
    // response 为 null → 假客户端返回 code 404 → load 落 error，loaded 保持 false。
    await pumpDailyPage(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('每日推荐加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
