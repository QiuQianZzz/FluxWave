import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:fluxwave/models/artist.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';
import 'package:fluxwave/widgets/mini_player.dart';

/// 迷你播放器滑动切换（信息块滑动 + 目标歌曲进入 + 归正切换）。
///
/// 用 Fake PlayerProvider 覆写歌曲状态，绕开测试环境网络被屏蔽导致的
/// 自动跳过链（避免 currentSong 被清空）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(PlayerProvider player) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: player),
      // 迷你播放器的毛玻璃开关需要 SettingsProvider（真实应用中顶层必给）。
      ChangeNotifierProvider.value(value: SettingsProvider()),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: MiniPlayer()),
      ),
    ),
  );

  /// 信息块（封面+标题）当前的水平位移（Transform.translate 的 dx）。
  double infoOffsetX(WidgetTester tester) {
    final transforms = tester.widgetList<Transform>(
      find.descendant(
        of: find.byType(MiniPlayer),
        matching: find.byType(Transform),
      ),
    );
    expect(transforms, isNotEmpty);
    // 归正后只有当前信息块一个 Transform（邻居隐藏）。
    return transforms.first.transform.getTranslation().x;
  }

  testWidgets('有歌时首次 build 不崩溃（_settle 已初始化）', (tester) async {
    await tester.pumpWidget(wrap(_FakePlayer()));
    await tester.pump();
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('歌1'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('左滑超过阈值：松手归正后切到下一曲，信息块回到原位', (tester) async {
    await tester.pumpWidget(wrap(_FakePlayer()));
    await tester.pump();
    expect(find.text('歌1'), findsOneWidget);

    await tester.drag(find.byType(MiniPlayer), const Offset(-150, 0));
    await tester.pumpAndSettle();

    expect(find.text('歌2'), findsOneWidget, reason: '左滑应切到下一曲');
    expect(infoOffsetX(tester), 0, reason: '切换后信息块应归正到原位');
  });

  testWidgets('左滑未过阈值：松手即归正到原位，不切歌', (tester) async {
    await tester.pumpWidget(wrap(_FakePlayer()));
    await tester.pump();

    await tester.drag(find.byType(MiniPlayer), const Offset(-20, 0));
    await tester.pumpAndSettle();

    expect(find.text('歌1'), findsOneWidget, reason: '未过阈值不应切歌');
    expect(infoOffsetX(tester), 0, reason: '松手后信息块应自动归正');
  });

  testWidgets('3 首当前为 b：左滑到 c 的归正动画中不出现上一首 a（修方向符号错）', (tester) async {
    await tester.pumpWidget(wrap(_FakePlayer3()));
    await tester.pump();
    expect(find.text('歌2'), findsOneWidget);

    await tester.drag(find.byType(MiniPlayer), const Offset(-150, 0));
    // 归正动画进行中：绝不应出现"歌1"（旧版方向符号反了会闪现上一首）。
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('歌1'), findsNothing, reason: '左滑不应闪现上一首');

    await tester.pumpAndSettle();
    expect(find.text('歌3'), findsOneWidget, reason: '归正后切到下一首');
    expect(infoOffsetX(tester), 0);
  });
}

Song _song(int id) => Song(
  id: id,
  name: '歌$id',
  artists: const [ArtistSummary(id: 0, name: '甲')],
  coverUrl: null,
  durationMs: 200000,
  fee: 0,
);

/// 仅覆写 MiniPlayer 用到的状态，不触发任何网络加载。
class _FakePlayer extends PlayerProvider {
  _FakePlayer()
    : super(
        netease: NeteaseProvider(),
        settings: SettingsProvider(),
        liked: LikedSongsProvider(),
      );

  final List<Song> _songs = [_song(1), _song(2)];
  int _i = 0;

  @override
  Song? get currentSong => _songs[_i];
  @override
  Song? get nextSong => _i < _songs.length - 1 ? _songs[_i + 1] : null;
  @override
  Song? get previousSong => _i > 0 ? _songs[_i - 1] : null;
  @override
  bool get playing => true;
  @override
  bool get isTrial => false;
  @override
  bool get hasNext => _i < _songs.length - 1;
  @override
  bool get hasPrevious => _i > 0;

  @override
  Future<void> next() async {
    if (!hasNext) return;
    _i++;
    notifyListeners();
  }

  @override
  Future<void> previous() async {
    if (!hasPrevious) return;
    _i--;
    notifyListeners();
  }

  @override
  Future<void> toggle() async {}
}

/// 三首、当前第 2 首（歌2）：复现"左滑切下一首却闪现上一首"。
class _FakePlayer3 extends PlayerProvider {
  _FakePlayer3()
    : super(
        netease: NeteaseProvider(),
        settings: SettingsProvider(),
        liked: LikedSongsProvider(),
      );

  final List<Song> _songs = [_song(1), _song(2), _song(3)];
  int _i = 1;

  @override
  Song? get currentSong => _songs[_i];
  @override
  Song? get nextSong => _i < _songs.length - 1 ? _songs[_i + 1] : null;
  @override
  Song? get previousSong => _i > 0 ? _songs[_i - 1] : null;
  @override
  bool get playing => true;
  @override
  bool get isTrial => false;
  @override
  bool get hasNext => _i < _songs.length - 1;
  @override
  bool get hasPrevious => _i > 0;

  @override
  Future<void> next() async {
    if (!hasNext) return;
    _i++;
    notifyListeners();
  }

  @override
  Future<void> previous() async {
    if (!hasPrevious) return;
    _i--;
    notifyListeners();
  }

  @override
  Future<void> toggle() async {}
}
