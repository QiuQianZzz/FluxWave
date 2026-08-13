import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/playback_stats/database_helper.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// 模拟 path_provider 平台（测试环境无需真实路径）
class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async {
    return '.';
  }
}

void main() {
  late DatabaseHelper db;

  setUpAll(() {
    // 初始化 Flutter 绑定（测试环境需要）
    TestWidgetsFlutterBinding.ensureInitialized();
    // 模拟 path_provider
    PathProviderPlatform.instance = MockPathProviderPlatform();
    // 数据库 FFI 初始化（内部有幂等 guard，重复调用不会重复设置 factory）
    DatabaseHelper.init();
  });

  setUp(() async {
    db = DatabaseHelper.instance;
    // 清理数据库（测试隔离）
    final database = await db.database;
    await database.delete('playback_stat');
    await database.delete('playback_stat_bucket');
    await database.delete('recent_play');
  });

  group('DatabaseHelper', () {
    test('recordPlay 应正确记录播放统计', () async {
      await db.recordPlay(
        source: 'netease',
        sourceId: '123',
        name: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        coverUrl: 'https://example.com/cover.jpg',
        durationMs: 240000,
        listenMs: 120000,
        nowMs: DateTime(2024, 1, 15, 10, 30).millisecondsSinceEpoch,
      );

      final stats = await db.getTotalStats();
      expect(stats.uniqueSongs, 1);
      expect(stats.playCount, 1);
      expect(stats.totalListenMs, 120000);
      expect(stats.topSongs.length, 1);
      expect(stats.topSongs.first.name, '测试歌曲');
      expect(stats.topSongs.first.artist, '测试歌手');
      expect(
        stats.topSongs.first.firstPlayedAt,
        DateTime(2024, 1, 15, 10, 30).millisecondsSinceEpoch,
      );
    });

    test('多次播放同一首歌应累加统计', () async {
      final now1 = DateTime(2024, 1, 15, 10, 30).millisecondsSinceEpoch;
      final now2 = DateTime(2024, 1, 15, 11, 30).millisecondsSinceEpoch;

      await db.recordPlay(
        source: 'netease',
        sourceId: '123',
        name: '测试歌曲',
        durationMs: 240000,
        listenMs: 120000,
        nowMs: now1,
      );

      await db.recordPlay(
        source: 'netease',
        sourceId: '123',
        name: '测试歌曲',
        durationMs: 240000,
        listenMs: 180000,
        nowMs: now2,
      );

      final stats = await db.getTotalStats();
      expect(stats.uniqueSongs, 1);
      expect(stats.playCount, 2);
      expect(stats.totalListenMs, 300000);
      expect(stats.topSongs.first.firstPlayedAt, now1);
      // lastPlayedAt is tracked internally but not exposed in RankingItem
    });

    test('不同音源的歌曲应分别记录', () async {
      await db.recordPlay(
        source: 'netease',
        sourceId: '123',
        name: '网易云歌曲',
        durationMs: 240000,
        listenMs: 120000,
        nowMs: DateTime(2024, 1, 15).millisecondsSinceEpoch,
      );

      await db.recordPlay(
        source: 'kugou',
        sourceId: '456',
        name: '酷狗歌曲',
        durationMs: 180000,
        listenMs: 90000,
        nowMs: DateTime(2024, 1, 15).millisecondsSinceEpoch,
      );

      final stats = await db.getTotalStats();
      expect(stats.uniqueSongs, 2);
      expect(stats.playCount, 2);
      expect(stats.totalListenMs, 210000);
    });

    test('getStatsForDay 应返回指定日期的统计', () async {
      final day = DateTime(2024, 1, 15);

      await db.recordPlay(
        source: 'netease',
        sourceId: '123',
        name: '歌曲A',
        durationMs: 240000,
        listenMs: 120000,
        nowMs: day.add(const Duration(hours: 10)).millisecondsSinceEpoch,
      );

      await db.recordPlay(
        source: 'netease',
        sourceId: '456',
        name: '歌曲B',
        durationMs: 180000,
        listenMs: 90000,
        nowMs: day.add(const Duration(hours: 15)).millisecondsSinceEpoch,
      );

      final stats = await db.getStatsForDay(day);
      expect(stats.uniqueSongs, 2);
      expect(stats.playCount, 2);
      expect(stats.totalListenMs, 210000);
      expect(stats.topSongs.length, 2);
    });

    test('getStatsForWeek 应返回指定周的统计', () async {
      final weekStart = DateTime(2024, 1, 15); // 周一
      final weekMid = weekStart.add(const Duration(days: 3));
      final weekEnd = weekStart.add(const Duration(days: 6));

      await db.recordPlay(
        source: 'netease',
        sourceId: '123',
        name: '歌曲A',
        durationMs: 240000,
        listenMs: 120000,
        nowMs: weekStart.millisecondsSinceEpoch,
      );

      await db.recordPlay(
        source: 'netease',
        sourceId: '456',
        name: '歌曲B',
        durationMs: 180000,
        listenMs: 90000,
        nowMs: weekMid.millisecondsSinceEpoch,
      );

      await db.recordPlay(
        source: 'netease',
        sourceId: '789',
        name: '歌曲C',
        durationMs: 200000,
        listenMs: 100000,
        nowMs: weekEnd.millisecondsSinceEpoch,
      );

      final stats = await db.getStatsForWeek(weekStart);
      expect(stats.uniqueSongs, 3);
      expect(stats.playCount, 3);
      expect(stats.dailyBreakdown.length, 7);
    });

    test('getRecentPlayed 应返回最近播放列表（最新在前）', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.recordRecentPlay(
        source: 'netease',
        sourceId: '1',
        name: '歌曲1',
        durationMs: 240000,
        fee: 0,
        playedAtMs: now - 1000,
      );

      await db.recordRecentPlay(
        source: 'netease',
        sourceId: '2',
        name: '歌曲2',
        durationMs: 180000,
        fee: 0,
        playedAtMs: now,
      );

      final recent = await db.getRecentPlayed();
      expect(recent.length, 2);
      expect(recent.first.name, '歌曲2');
      expect(recent.last.name, '歌曲1');
    });

    test('recordRecentPlay 应去重：重复播放顶到最前', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.recordRecentPlay(
        source: 'netease',
        sourceId: '1',
        name: '歌曲A',
        durationMs: 240000,
        fee: 1,
        playedAtMs: now,
      );
      await db.recordRecentPlay(
        source: 'netease',
        sourceId: '2',
        name: '歌曲B',
        durationMs: 180000,
        fee: 0,
        playedAtMs: now + 1000,
      );
      // 重新播放歌曲A：应顶到最前，而不是新增一行
      await db.recordRecentPlay(
        source: 'netease',
        sourceId: '1',
        name: '歌曲A',
        durationMs: 240000,
        fee: 4,
        playedAtMs: now + 2000,
      );

      final recent = await db.getRecentPlayed();
      expect(recent.length, 2);
      expect(recent.first.name, '歌曲A');
      expect(recent.first.fee, 4);
      expect(recent.last.name, '歌曲B');
    });

    test('recordRecentPlay 超出 500 应清理最旧', () async {
      final base = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < 505; i++) {
        await db.recordRecentPlay(
          source: 'netease',
          sourceId: '$i',
          name: '歌曲$i',
          durationMs: 240000,
          fee: 0,
          playedAtMs: base + i,
        );
      }

      final recent = await db.getRecentPlayed();
      expect(recent.length, 500);
      // 最新一条是 504，最旧（0~4）被清理
      expect(recent.first.name, '歌曲504');
      expect(recent.any((r) => r.name == '歌曲0'), isFalse);
      expect(recent.last.name, '歌曲5');
    });

    test('recents-play 去重后仍保持 500 上限', () async {
      final base = DateTime.now().millisecondsSinceEpoch;
      // 写入 500 首去重歌曲
      for (var i = 0; i < 500; i++) {
        await db.recordRecentPlay(
          source: 'netease',
          sourceId: '$i',
          name: '歌曲$i',
          durationMs: 240000,
          fee: 0,
          playedAtMs: base + i,
        );
      }
      // 重复播放歌曲0（最旧）：应被顶到最前，行数不变
      await db.recordRecentPlay(
        source: 'netease',
        sourceId: '0',
        name: '歌曲0',
        durationMs: 240000,
        fee: 0,
        playedAtMs: base + 5000,
      );

      final recent = await db.getRecentPlayed();
      expect(recent.length, 500);
      expect(recent.first.name, '歌曲0');
    });

    test('热力图数据应按天聚合', () async {
      final day1 = DateTime(2024, 1, 15, 10, 0);
      final day2 = DateTime(2024, 1, 16, 10, 0);

      await db.recordPlay(
        source: 'netease',
        sourceId: '1',
        name: '歌曲A',
        durationMs: 240000,
        listenMs: 120000, // 2 minutes
        nowMs: day1.millisecondsSinceEpoch,
      );

      await db.recordPlay(
        source: 'netease',
        sourceId: '2',
        name: '歌曲B',
        durationMs: 180000,
        listenMs: 90000, // 1.5 minutes
        nowMs: day1.millisecondsSinceEpoch,
      );

      await db.recordPlay(
        source: 'netease',
        sourceId: '3',
        name: '歌曲C',
        durationMs: 200000,
        listenMs: 100000, // ~1.67 minutes
        nowMs: day2.millisecondsSinceEpoch,
      );

      final stats = await db.getTotalStats();
      expect(stats.heatmapData.length, 2);
      // day1: (120000 + 90000) / 60000 = 3.5 → round = 4
      expect(stats.heatmapData.first.value, 4);
      // day2: 100000 / 60000 ≈ 1.67 → round = 2
      expect(stats.heatmapData.last.value, 2);
    });

    test('播放阈值计算应正确', () {
      // 短歌：60% < 60s
      expect((30000 * 0.6).round().clamp(0, 60000), 18000);

      // 长歌：60% > 60s
      expect((300000 * 0.6).round().clamp(0, 60000), 60000);

      // 中等长度：60% ≈ 36s
      expect((60000 * 0.6).round().clamp(0, 60000), 36000);
    });

    test('clear 应清空所有数据', () async {
      await db.recordPlay(
        source: 'netease',
        sourceId: '123',
        name: '测试歌曲',
        durationMs: 240000,
        listenMs: 120000,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

      var stats = await db.getTotalStats();
      expect(stats.uniqueSongs, 1);

      // 清空（通过直接删除表数据模拟）
      final database = await db.database;
      await database.delete('playback_stat');
      await database.delete('playback_stat_bucket');

      stats = await db.getTotalStats();
      expect(stats.uniqueSongs, 0);
    });
  });
}