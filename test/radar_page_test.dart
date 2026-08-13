import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/netease/config.dart';
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/pages/radar/radar_page.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/radar_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/providers/theme_provider.dart';

/// 假客户端：按歌单 id 回放详情响应。
class FakeRadarClient extends NeteaseClient {
  FakeRadarClient()
    : super(context: NeteaseRequestContext(deviceId: 'TEST-DEVICE'));

  Map<String, Map<String, dynamic>> byId = {};

  @override
  Future<Object?> request(
    String uri,
    Map<String, Object> data,
    NeteaseMode mode, {
    bool useER = kEncryptResponse,
  }) async {
    final id = data['id']?.toString() ?? '?';
    return byId[id] ?? const {'code': 404};
  }
}

Map<String, dynamic> _radar(int id, String name) => {
  'code': 200,
  'playlist': {
    'id': id,
    'name': name,
    'coverImgUrl': 'https://p1.music.126.net/mock/$id.jpg',
    'description': '为 $name 描述',
    'trackCount': 30,
  },
};

/// 渲染回归：雷达合集页在竖屏（单列宽卡）与宽屏（多列）都不溢出；
/// 首项横幅 + 其余横卡在默认字号与 2x 大字号下均渲染、无溢出。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpRadarPage(
    WidgetTester tester,
    Size size, {
    TextScaler? textScaler,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final client = FakeRadarClient();
    final api = NeteaseApi(client);
    client.byId = {
      for (final id in radarPlaylistIds) '$id': _radar(id, '雷达-${id % 10000}'),
    };
    final radar = RadarProvider();
    await radar.load(api);

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
          ChangeNotifierProvider.value(value: radar),
        ],
        child: MaterialApp(
          theme: theme.lightTheme,
          home: const RadarPage(),
          builder: textScaler == null
              ? null
              : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: child!,
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('竖屏：横幅 + 单列宽卡渲染无溢出', (tester) async {
    await pumpRadarPage(tester, const Size(400, 900));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('雷达-'), findsWidgets);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('宽屏：自适应多列渲染无溢出', (tester) async {
    await pumpRadarPage(tester, const Size(1400, 900));
    expect(tester.takeException(), isNull);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('2x 大字号：横幅 + 横卡不溢出', (tester) async {
    await pumpRadarPage(
      tester,
      const Size(400, 900),
      textScaler: TextScaler.linear(2),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SliverGrid), findsOneWidget);
  });
}
