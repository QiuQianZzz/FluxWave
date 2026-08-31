import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/player/playback_storage.dart';
import 'package:fluxwave/models/artist.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';

/// 播放模式回归：随机（洗牌表顺序）与循环（列表/单曲）两个正交状态。
///
/// 关键不变量：
/// - 随机开启 = 以当前歌为锚的全排列顺序表；播放按表推进，同一序列反复轮循；
/// - 列表循环下顺序/随机都永不停止（末尾回绕）；
/// - displayQueue/displayIndex 是纯展示视图，不影响原始队列。
///
/// 测试假设：队列状态（index/洗牌表）都在调用点的同步段生效，直接断言这些
/// 状态即可，不必 await 触发网络加载的返回。测试环境网络被屏蔽，load 会走
/// 自动跳过链并改动 currentIndex，故刻意「断言先于等待」。
///
/// 不调用 dispose()：断言后仍有一次同步落盘（_persistNow）在途，dispose 会让
/// 其 notifyListeners 触发「used after disposed」。改为 pump 推进 300ms 防抖，
/// 让落盘在托管时间内完成。
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

  testWidgets('随机模式：displayQueue 是以当前歌为锚的全排列，原始 queue 不变', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1), song(2), song(3), song(4)], 2));
    player.toggleShuffle();

    expect(player.shuffleMode, isTrue);
    final view = player.displayQueue;
    expect(view.map((e) => e.id).toSet(), {1, 2, 3, 4});
    // 当前歌（原下标 2 → 歌3）锚定在随机视图首位
    expect(view.first.id, 3);
    expect(player.displayIndex, 0);
    // 原始队列顺序未被展示视图影响
    expect(player.queue.map((e) => e.id).toList(), [1, 2, 3, 4]);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('顺序+列表循环：末尾 next 绕回队首，队首 previous 回绕队尾', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1), song(2), song(3)], 2));

    expect(player.currentIndex, 2);
    player.next();
    expect(player.currentIndex, 0);

    player.previous();
    expect(player.currentIndex, 2);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('随机模式：播放按洗牌表顺序推进，previous 回退同表', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1), song(2), song(3), song(4), song(5)], 0));
    player.toggleShuffle();

    final order = player.displayQueue.map((e) => e.id).toList();

    player.next();
    // 下一首 = 洗牌表第 1 项；displayIndex 相应 = 1
    expect(player.currentSong!.id, order[1]);
    expect(player.displayIndex, 1);

    player.previous();
    expect(player.displayIndex, 0);
    expect(player.currentSong!.id, order[0]);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('随机模式：展示视图下原始索引映射仍指向正确歌曲', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(10), song(20), song(30), song(40)], 0));
    player.toggleShuffle();

    final viewPos = player.displayQueue.indexWhere((e) => e.id == 30);
    final original = player.originalIndexAtDisplay(viewPos);
    expect(player.queue[original].id, 30);
    unawaited(player.jumpTo(original));
    expect(player.currentSong!.id, 30);
    expect(player.displayQueue[player.displayIndex].id, 30);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('循环模式：list ⇄ single ⇄ off 三态轮转', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1)], 0));

    expect(player.loopMode, LoopMode.list);
    player.cycleLoopMode();
    expect(player.loopMode, LoopMode.single);
    player.cycleLoopMode();
    expect(player.loopMode, LoopMode.off);
    player.cycleLoopMode();
    expect(player.loopMode, LoopMode.list);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('不循环：队尾 hasNext=false、队首 hasPrevious=false，循环态恢复可切', (
    tester,
  ) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1), song(2), song(3)], 2));

    // 列表循环：边界仍可切（回绕）
    expect(player.hasNext, isTrue);
    expect(player.hasPrevious, isTrue);

    player.cycleLoopMode(); // single
    player.cycleLoopMode(); // off
    expect(player.loopMode, LoopMode.off);
    // 队尾且不循环：无下一首；非队首仍有上一首
    expect(player.hasNext, isFalse);
    expect(player.hasPrevious, isTrue);

    player.cycleLoopMode(); // list
    expect(player.hasNext, isTrue);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('随机+不循环：队尾 next / 队首 previous 不推进、不改游标', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1), song(2), song(3), song(4)], 0));
    player.toggleShuffle(); // anchor 当前(0)，游标=0
    player.cycleLoopMode(); // single
    player.cycleLoopMode(); // off
    expect(player.loopMode, LoopMode.off);

    final n = player.displayQueue.length;
    // 从队首一路 next 到队尾（游标到 n-1）
    for (var i = 0; i < n - 1; i++) {
      player.next();
    }
    expect(player.displayIndex, n - 1);
    final lastOriginal = player.currentIndex!;

    // 队尾 + 不循环：next 返回 null，不推进、不绕回
    player.next();
    expect(player.displayIndex, n - 1);
    expect(player.currentIndex, lastOriginal);
    expect(player.hasNext, isFalse);

    // 一路 previous 退回队首（off 下允许列表内回退）
    for (var i = 0; i < n - 1; i++) {
      player.previous();
    }
    expect(player.displayIndex, 0);

    // 队首 + 不循环：previous 返回 null，不推进、不绕回
    player.previous();
    expect(player.displayIndex, 0);
    expect(player.currentIndex, player.originalIndexAtDisplay(0));
    expect(player.hasPrevious, isFalse);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('playShuffled：自动开启随机，起点随机且在范围内，队列以起点为锚', (tester) async {
    final player = await makePlayer();
    expect(player.shuffleMode, isFalse);
    unawaited(
      player.playShuffled([song(1), song(2), song(3), song(4), song(5)]),
    );
    expect(player.shuffleMode, isTrue);
    // 起点为合法原始下标；displayIndex 恒为 0（洗牌表锚定起点）
    expect(player.currentIndex, inInclusiveRange(0, 4));
    expect(player.displayIndex, 0);
    expect(player.displayQueue.first.id, player.queue[player.currentIndex!].id);
    // 剩余的 displayQueue 是其余歌的全排列
    expect(player.displayQueue.length, 5);
    expect(player.displayQueue.map((s) => s.id).toSet().length, 5);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('playShuffled：显式 startIndex 作为播放起点', (tester) async {
    final player = await makePlayer();
    unawaited(
      player.playShuffled([song(1), song(2), song(3), song(4)], startIndex: 2),
    );
    expect(player.shuffleMode, isTrue);
    expect(player.currentIndex, 2);
    expect(player.displayIndex, 0);
    expect(player.displayQueue.first.id, 3); // 「歌2」起点

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('playShuffled：已开启随机时保持开启且不关随机', (tester) async {
    final player = await makePlayer();
    unawaited(player.playAt([song(1), song(2), song(3), song(4)], 0));
    player.toggleShuffle();
    expect(player.shuffleMode, isTrue);
    unawaited(player.playShuffled([song(9), song(8), song(7), song(6)]));
    expect(player.shuffleMode, isTrue);
    expect(player.queue.length, 4);
    // 新队列以随机起点为锚，展示位 0 即当前
    expect(player.displayIndex, 0);

    await tester.pump(const Duration(milliseconds: 400));
  });

  group('队列去重按 (音源, id)：跨源同 id 不误删', () {
    Song cross(int id, String source) =>
        Song(id: id, name: '跨源$id', artists: const [], source: source);

    testWidgets('addToQueue：同源同 id 去重移末尾，跨源同 id 各自保留', (tester) async {
      final player = await makePlayer();
      player.addToQueue(song(1)); // netease 1
      player.addToQueue(cross(1, 'kugou')); // kugou 1
      expect(player.queue, hasLength(2), reason: '跨源同 id 不应去重');

      player.addToQueue(song(1)); // 同源同 id → 去重并追加末尾
      expect(player.queue, hasLength(2));
      expect(player.queue.last.source, SongSource.netease);
      expect(player.queue.last.id, 1);
      expect(player.queue.map((s) => s.id), [1, 1]);

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('playNext：跨源同 id 都插入，同源同 id 去重', (tester) async {
      final player = await makePlayer();
      unawaited(player.playAt([song(1), song(2)], 0));

      player.playNext(cross(2, 'kugou')); // 插入下一首位置
      expect(player.queue.length, 3, reason: '跨源同 id 不应去重');

      player.playNext(song(2)); // 同源同 id → 移除 netease 2 再插入
      expect(player.queue.length, 3);
      final queue = player.queue;
      expect(queue[1].source, SongSource.netease);
      expect(queue[1].id, 2);

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('addAllToQueue：批量跨源同 id 不误删，同源同 id 去重', (tester) async {
      final player = await makePlayer();
      player.addToQueue(song(1));
      player.addAllToQueue([
        cross(1, 'kugou'), // 跨源 → 保留
        cross(2, 'kugou'),
        song(1), // 同源 → 去重移末尾
      ]);
      expect(player.queue, hasLength(3));
      final ids = player.queue.map((s) => '${s.source}:${s.id}').toList();
      // 跨源 kugou:1 保留；同源 netease:1 去重移末尾
      expect(ids, ['kugou:1', 'kugou:2', 'netease:1']);

      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('随机模式：队列增删不重排洗牌序，保「下一首」语义', () {
    testWidgets('playNext：新歌插入当前歌之后成为真正下一首，其余相对顺序不变', (tester) async {
      final player = await makePlayer();
      unawaited(player.playAt([song(1), song(2), song(3), song(4)], 1));
      player.toggleShuffle();
      final before = player.displayQueue; // [歌2, 其余乱序]

      player.playNext(song(9));

      final view = player.displayQueue;
      expect(view.first.id, 2, reason: '当前歌仍锚定随机视图首位');
      expect(view[1].id, 9, reason: '新歌紧跟当前歌，成为下一首');
      expect(
        view.sublist(2).map((e) => e.id).toList(),
        before.sublist(1).map((e) => e.id).toList(),
        reason: '其余歌曲相对顺序不得被重排',
      );
      expect(player.nextSong?.id, 9, reason: '下一首就是刚插入的歌');

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('addToQueue：新歌追加到洗牌序末尾（最后播放）', (tester) async {
      final player = await makePlayer();
      unawaited(player.playAt([song(1), song(2), song(3)], 0));
      player.toggleShuffle();
      final before = player.displayQueue;

      player.addToQueue(song(9));

      final view = player.displayQueue;
      expect(view.first.id, 1);
      expect(view.last.id, 9, reason: '追加的歌在洗牌序末尾');
      expect(
        view.sublist(0, view.length - 1).map((e) => e.id).toList(),
        before.map((e) => e.id).toList(),
        reason: '原顺序不得被重排',
      );

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('addAllToQueue：批量追加到洗牌序末尾，且按追加顺序', (tester) async {
      final player = await makePlayer();
      unawaited(player.playAt([song(1), song(2), song(3)], 0));
      player.toggleShuffle();
      final before = player.displayQueue;

      player.addAllToQueue([song(9), song(8)]);

      final view = player.displayQueue;
      expect(view.first.id, 1);
      expect(view[view.length - 2].id, 9);
      expect(view.last.id, 8, reason: '批量追加按顺序排在洗牌序末尾');
      expect(
        view.sublist(0, view.length - 2).map((e) => e.id).toList(),
        before.map((e) => e.id).toList(),
        reason: '原顺序不得被重排',
      );

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('playNext 后再追加：上一首设置仍保持', (tester) async {
      final player = await makePlayer();
      unawaited(player.playAt([song(1), song(2), song(3)], 0));
      player.toggleShuffle();

      player.playNext(song(9));
      player.addToQueue(song(8)); // 追加不应把 9 洗掉

      final view = player.displayQueue;
      expect(view.first.id, 1);
      expect(view[1].id, 9, reason: '追加后「下一首」应保持');
      expect(view.last.id, 8);
      expect(player.nextSong?.id, 9);

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('removeAt：只移除该歌，其余相对顺序不变', (tester) async {
      final player = await makePlayer();
      unawaited(
        player.playAt([song(1), song(2), song(3), song(4), song(5)], 0),
      );
      player.toggleShuffle();
      final before = player.displayQueue; // 歌1 锚首
      final target = before[1];

      unawaited(player.removeAt(player.originalIndexAtDisplay(1)));

      final view = player.displayQueue;
      expect(view.length, 4);
      expect(view.first.id, 1);
      expect(view, isNot(contains(target)));
      expect(
        view.map((e) => e.id).toList(),
        before.where((e) => e.id != target.id).map((e) => e.id).toList(),
        reason: '移除后剩余歌曲的相对顺序应保持',
      );

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('playNext 当前播放的歌：空操作，不破坏洗牌序', (tester) async {
      final player = await makePlayer();
      unawaited(player.playAt([song(1), song(2), song(3)], 0));
      player.toggleShuffle();
      final before = player.displayQueue;

      player.playNext(song(1)); // 目标即当前歌

      expect(
        player.displayQueue.map((e) => e.id).toList(),
        before.map((e) => e.id).toList(),
      );
      expect(player.queue.length, 3);

      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('随机模式：恢复持久化洗牌序', () {
    Future<PlayerProvider> makeRestorePlayer(
      PlaybackSnapshot snapshot,
      WidgetTester tester,
    ) async {
      final settings = SettingsProvider();
      await settings.init();
      final netease = NeteaseProvider();
      await netease.init();
      final player = PlayerProvider(
        netease: netease,
        settings: settings,
        liked: LikedSongsProvider(),
        networkRetryAttempts: 0,
        snapshot: snapshot,
      );
      player.init();
      return player;
    }

    testWidgets('合法洗牌序直接恢复：下一首布局跨会话保留', (tester) async {
      final player = await makeRestorePlayer(
        PlaybackSnapshot(
          queue: [song(1), song(2), song(3), song(4)],
          currentIndex: 1,
          positionMs: 0,
          playing: false,
          shuffleMode: true,
          shuffleOrder: const [1, 3, 0, 2],
        ),
        tester,
      );

      expect(player.displayQueue.map((e) => e.id).toList(), [2, 4, 1, 3]);
      expect(player.displayIndex, 0);

      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('非法洗牌序（重复下标）回退重建：当前歌锚定视图首位', (tester) async {
      final player = await makeRestorePlayer(
        PlaybackSnapshot(
          queue: [song(1), song(2), song(3), song(4)],
          currentIndex: 2,
          positionMs: 0,
          playing: false,
          shuffleMode: true,
          shuffleOrder: const [0, 0, 0, 0],
        ),
        tester,
      );

      expect(player.displayQueue.first.id, 3, reason: '当前歌2 锚定随机视图首位');
      expect(player.displayIndex, 0);

      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('nextSong/previousSong 一致性', () {
    testWidgets('与 hasNext/hasPrevious 在循环×随机各组合下一致（起始位）', (tester) async {
      final player = await makePlayer();
      unawaited(player.playAt([song(1), song(2), song(3)], 0));

      // 起始 list，cycleLoopMode 依次到 single/off/list；每次配随机开/关。
      for (var loopCycle = 0; loopCycle < 3; loopCycle++) {
        for (var shuffle = 0; shuffle < 2; shuffle++) {
          if (player.shuffleMode != (shuffle == 1)) player.toggleShuffle();
          expect(
            (player.nextSong != null),
            player.hasNext,
            reason: 'loop#$loopCycle shuffle=$shuffle 下一首存在性与 hasNext 应一致',
          );
          expect(
            (player.previousSong != null),
            player.hasPrevious,
            reason: 'loop#$loopCycle shuffle=$shuffle 上一首存在性与 hasPrevious 应一致',
          );
        }
        player.cycleLoopMode();
      }
      await tester.pump(const Duration(milliseconds: 400));
    });
  });
}
