import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/backup_service.dart';
import 'package:fluxwave/core/playback_stats/database_helper.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 模拟 path_provider 平台，指向测试临时目录（隔离队列文件）。
class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  MockPathProviderPlatform(this.supportDir, this.tempDir);
  final String supportDir;
  final String tempDir;

  @override
  Future<String?> getApplicationSupportPath() async => supportDir;

  @override
  Future<String?> getTemporaryPath() async => tempDir;
}

/// 播放队列歌曲快照（Song.toJson 格式）。
Map<String, dynamic> _song({
  required int id,
  required String name,
  List<String> artists = const ['歌手'],
  int durationMs = 240000,
  int fee = 0,
}) => {
  'source': 'netease',
  'id': id,
  'name': name,
  'artists': artists,
  'albumId': 1,
  'albumName': '专辑',
  'coverUrl': 'https://example.com/$id.jpg',
  'durationMs': durationMs,
  'fee': fee,
};

/// 播放统计行（playback_stat 表结构）。
Map<String, dynamic> _stat({
  required String sourceId,
  required String name,
  int playCount = 1,
  int totalListenMs = 120000,
}) => {
  'source': 'netease',
  'source_id': sourceId,
  'name': name,
  'artist': '歌手',
  'album': '专辑',
  'cover_url': 'https://example.com/$sourceId.jpg',
  'duration_ms': 240000,
  'play_count': playCount,
  'total_listen_ms': totalListenMs,
  'first_played_at': 1000,
  'last_played_at': 2000,
};

/// 播放统计分桶行（playback_stat_bucket 表结构）。
Map<String, dynamic> _bucket({
  required int dayStart,
  required String sourceId,
  int playCount = 1,
  int totalListenMs = 120000,
}) => {
  'day_start': dayStart,
  'source': 'netease',
  'source_id': sourceId,
  'play_count': playCount,
  'total_listen_ms': totalListenMs,
  'first_played_at': 1000,
  'last_played_at': 2000,
};

void main() {
  late Directory tempDir;
  late DatabaseHelper db;

  /// 写一个测试备份文件并返回 File。
  File writeBackup(Map<String, dynamic> data) {
    final f = File('${tempDir.path}/backup_${DateTime.now().microsecondsSinceEpoch}.json');
    f.writeAsStringSync(jsonEncode(data));
    return f;
  }

  /// 写本地播放队列文件（applicationSupport 目录 = tempDir）。
  void writeLocalQueue(List<Map<String, dynamic>> queue) {
    final f = File('${tempDir.path}/playback_queue.json');
    f.writeAsStringSync(jsonEncode({'v': 1, 'queue': queue, 'currentIndex': 0}));
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('backup_test_');
    PathProviderPlatform.instance = MockPathProviderPlatform(
      tempDir.path,
      tempDir.path,
    );
    await DatabaseHelper.initForTest();
  });

  tearDownAll(() async {
    await DatabaseHelper.resetForTest();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    db = DatabaseHelper.instance;
    final database = await db.database;
    await database.delete('playback_stat');
    await database.delete('playback_stat_bucket');
    await database.delete('recent_play');
    await database.delete('liked_song');
    final queueFile = File('${tempDir.path}/playback_queue.json');
    if (await queueFile.exists()) await queueFile.delete();
  });

  group('detectConflicts', () {
    test('播放队列：备份与本地同一首歌且内容一致，不视为冲突', () async {
      writeLocalQueue([_song(id: 1, name: '歌曲A'), _song(id: 2, name: '歌曲B')]);
      final backup = writeBackup({
        'playlists': {
          'queue': [_song(id: 1, name: '歌曲A'), _song(id: 2, name: '歌曲B')],
        },
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.playlists],
      );
      expect(conflicts, isEmpty);
    });

    test('播放队列：同一首歌但内容不同（改名/时长等），视为冲突', () async {
      writeLocalQueue([_song(id: 1, name: '歌曲A')]);
      final backup = writeBackup({
        'playlists': {
          'queue': [_song(id: 1, name: '歌曲A（改名）')],
        },
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.playlists],
      );
      expect(conflicts[BackupItem.playlists], ['歌曲A（改名）（内容不同）']);
    });

    test('播放队列：仅备份有（本地没有），视为差异（合并时新增）', () async {
      writeLocalQueue([_song(id: 1, name: '歌曲A')]);
      final backup = writeBackup({
        'playlists': {
          'queue': [_song(id: 1, name: '歌曲A'), _song(id: 2, name: '歌曲B')],
        },
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.playlists],
      );
      expect(conflicts[BackupItem.playlists], contains('备份新增 1 项：歌曲B'));
    });

    test('播放队列：仅本地有（备份没有），视为差异（合并保留/覆盖清除）', () async {
      writeLocalQueue([_song(id: 1, name: '歌曲A'), _song(id: 2, name: '歌曲B')]);
      final backup = writeBackup({
        'playlists': {
          'queue': [_song(id: 1, name: '歌曲A')],
        },
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.playlists],
      );
      expect(conflicts[BackupItem.playlists], contains('本地独有 1 项：歌曲B'));
    });

    test('播放记录：内容一致不冲突，play_count 不同也不视为冲突（设备计数差异）', () async {
      final database = await db.database;
      await database.insert('playback_stat', _stat(sourceId: '1', name: '歌曲A'));
      await database.insert('playback_stat', _stat(sourceId: '2', name: '歌曲B'));

      final backupSame = writeBackup({
        'playback_stats': [
          _stat(sourceId: '1', name: '歌曲A'),
          _stat(sourceId: '2', name: '歌曲B'),
        ],
      });
      final conflictsSame = await BackupService.detectConflicts(
        backupSame,
        const [BackupItem.playbackStats],
      );
      expect(conflictsSame, isEmpty, reason: '同一首歌统计一致不应冲突');

      final backupCountDiff = writeBackup({
        'playback_stats': [
          _stat(sourceId: '1', name: '歌曲A', playCount: 9),
          _stat(sourceId: '2', name: '歌曲B'),
        ],
      });
      final conflictsCountDiff = await BackupService.detectConflicts(
        backupCountDiff,
        const [BackupItem.playbackStats],
      );
      expect(
        conflictsCountDiff,
        isEmpty,
        reason: 'play_count 是设备计数差异，不应视为冲突',
      );

      final backupOnly = writeBackup({
        'playback_stats': [_stat(sourceId: '9', name: '歌曲Z')],
      });
      final conflictsOnly = await BackupService.detectConflicts(
        backupOnly,
        const [BackupItem.playbackStats],
      );
      expect(conflictsOnly[BackupItem.playbackStats], contains('备份新增 1 项：歌曲Z'));
    });

    test('播放记录：备份有而本地没有，视为差异（合并时新增）', () async {
      final database = await db.database;
      await database.insert('playback_stat', _stat(sourceId: '1', name: '歌曲A'));

      final backup = writeBackup({
        'playback_stats': [_stat(sourceId: '9', name: '歌曲Z')],
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.playbackStats],
      );
      expect(conflicts[BackupItem.playbackStats], contains('备份新增 1 项：歌曲Z'));
    });

    test('我喜欢的音乐：liked_at 不同视为冲突', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: '1001',
        name: '歌曲甲',
        durationMs: 0,
        fee: 0,
        likedAtMs: 1000,
      );
      final backup = writeBackup({
        'liked_songs': [
          {
            'source': 'netease',
            'source_id': '1001',
            'name': '歌曲甲',
            'artist': null,
            'album': null,
            'cover_url': null,
            'duration_ms': 0,
            'fee': 0,
            'liked_at': 99999,
          },
        ],
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.likedSongs],
      );
      expect(conflicts[BackupItem.likedSongs], ['歌曲甲（内容不同）']);
    });

    test('我喜欢的音乐：备份与本地相同收藏，不视为冲突', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: '1001',
        name: '歌曲甲',
        durationMs: 0,
        fee: 0,
        likedAtMs: 1000,
      );
      final local = (await db.getLikedSongs()).first.toMap();
      final backup = writeBackup({'liked_songs': [local]});
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.likedSongs],
      );
      expect(conflicts, isEmpty);
    });

    test('最近播放：played_at 不同不视为冲突，备份独有视为差异', () async {
      await db.recordRecentPlay(
        source: 'netease',
        sourceId: '2001',
        name: '歌曲乙',
        durationMs: 180000,
        fee: 0,
        playedAtMs: 5000,
      );
      final local = (await db.getRecentPlayed()).first.toMap();

      final backupSame = writeBackup({'recent_plays': [local]});
      final conflictsSame = await BackupService.detectConflicts(
        backupSame,
        const [BackupItem.recentPlays],
      );
      expect(conflictsSame, isEmpty, reason: 'played_at 一致不应冲突');

      final backupTimeDiff = writeBackup({
        'recent_plays': [
          {
            ...local,
            'played_at': 99999,
          },
        ],
      });
      final conflictsTimeDiff = await BackupService.detectConflicts(
        backupTimeDiff,
        const [BackupItem.recentPlays],
      );
      expect(
        conflictsTimeDiff,
        isEmpty,
        reason: 'played_at 是设备时间差异，不应视为冲突',
      );

      final backupOnly = writeBackup({
        'recent_plays': [
          {
            'source': 'netease',
            'source_id': '2002',
            'name': '备份独有',
            'artist': null,
            'album': null,
            'cover_url': null,
            'duration_ms': 0,
            'fee': 0,
            'played_at': 1234,
          },
        ],
      });
      final conflictsOnly = await BackupService.detectConflicts(
        backupOnly,
        const [BackupItem.recentPlays],
      );
      expect(conflictsOnly[BackupItem.recentPlays], contains('备份新增 1 项：备份独有'));
    });

    test('播放队列：备份 22 首、本地删 2 首，应检测到备份新增差异', () async {
      final backupSongs = [for (var i = 1; i <= 22; i++) _song(id: i, name: '歌$i')];
      // 本地 = 备份删掉 id 21、22
      writeLocalQueue([for (var i = 1; i <= 20; i++) _song(id: i, name: '歌$i')]);
      final backup = writeBackup({
        'playlists': {'queue': backupSongs},
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.playlists],
      );
      expect(conflicts[BackupItem.playlists], contains('备份新增 2 项：歌21、歌22'));
    });

    test('播放队列：本地队列为空时备份全部为备份独有，视为差异', () async {
      final backup = writeBackup({
        'playlists': {
          'queue': [_song(id: 1, name: '歌曲A')],
        },
      });
      final conflicts = await BackupService.detectConflicts(
        backup,
        const [BackupItem.playlists],
      );
      expect(conflicts[BackupItem.playlists], contains('备份新增 1 项：歌曲A'));
    });

    test('设置：某 key 值不同视为冲突，一致则不冲突', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark', 'seed_color': 1});

      final backupDiff = writeBackup({
        'settings': {'theme_mode': 'light', 'seed_color': 1},
      });
      final conflictsDiff = await BackupService.detectConflicts(
        backupDiff,
        const [BackupItem.settings],
      );
      expect(conflictsDiff[BackupItem.settings], contains('theme_mode（内容不同）'));
      expect(conflictsDiff[BackupItem.settings], isNot(contains('seed_color')));

      final backupSame = writeBackup({
        'settings': {'theme_mode': 'dark', 'seed_color': 1},
      });
      final conflictsSame = await BackupService.detectConflicts(
        backupSame,
        const [BackupItem.settings],
      );
      expect(conflictsSame, isEmpty);
    });
  });

  group('import（合并语义）', () {
    test('播放记录合并：保留本地已有行，只追加备份独有行', () async {
      final database = await db.database;
      await database.insert('playback_stat', _stat(sourceId: '1', name: '本地版本', playCount: 3));

      final backup = writeBackup({
        'playback_stats': [
          _stat(sourceId: '1', name: '备份版本', playCount: 9),
          _stat(sourceId: '2', name: '备份独有'),
        ],
      });
      await BackupService.import(backup, {
        BackupItem.playbackStats: ConflictStrategy.merge,
      });

      final rows = await database.query('playback_stat');
      expect(rows.length, 2);
      final byId = {for (final r in rows) r['source_id']: r};
      expect(byId['1']?['name'], '本地版本', reason: '已有行应保留本地数据');
      expect(byId['1']?['play_count'], 3);
      expect(byId['2']?['name'], '备份独有', reason: '备份独有行应被追加');
    });

    test('播放记录覆盖：清空本地后写入备份全部数据', () async {
      final database = await db.database;
      await database.insert('playback_stat', _stat(sourceId: '1', name: '本地版本'));

      final backup = writeBackup({
        'playback_stats': [
          _stat(sourceId: '2', name: '备份独有'),
        ],
      });
      await BackupService.import(backup, {
        BackupItem.playbackStats: ConflictStrategy.overwrite,
      });

      final rows = await database.query('playback_stat');
      expect(rows.length, 1);
      expect(rows.first['source_id'], '2');
    });

    test('播放队列合并：追加备份中本地没有的歌曲', () async {
      writeLocalQueue([_song(id: 1, name: '歌曲A')]);
      final backup = writeBackup({
        'playlists': {
          'queue': [
            _song(id: 1, name: '歌曲A'),
            _song(id: 2, name: '歌曲B'),
          ],
        },
      });
      await BackupService.import(backup, {
        BackupItem.playlists: ConflictStrategy.merge,
      });

      final f = File('${tempDir.path}/playback_queue.json');
      final decoded = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final ids = (decoded['queue'] as List).map((s) => (s as Map)['id']).toList();
      expect(ids, containsAll([1, 2]));
    });

    test('播放队列覆盖：直接写入备份队列', () async {
      writeLocalQueue([_song(id: 1, name: '歌曲A')]);
      final backup = writeBackup({
        'playlists': {
          'queue': [_song(id: 2, name: '歌曲B')],
        },
      });
      await BackupService.import(backup, {
        BackupItem.playlists: ConflictStrategy.overwrite,
      });

      final f = File('${tempDir.path}/playback_queue.json');
      final decoded = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final ids = (decoded['queue'] as List).map((s) => (s as Map)['id']).toList();
      expect(ids, [2]);
    });

    test('播放队列合并：跨源同 id 不误判去重', () async {
      writeLocalQueue([_song(id: 1, name: '歌曲A')]);
      final backup = writeBackup({
        'playlists': {
          'queue': [
            {
              ..._song(id: 1, name: '歌曲A'),
              'source': 'local',
            },
          ],
        },
      });
      await BackupService.import(backup, {
        BackupItem.playlists: ConflictStrategy.merge,
      });

      final f = File('${tempDir.path}/playback_queue.json');
      final decoded = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final queue = (decoded['queue'] as List).cast<Map<String, dynamic>>();
      expect(queue.length, 2, reason: 'netease/1 与 local/1 是两条不同歌曲');
      expect(
        queue.map((s) => '${s['source']}|${s['id']}').toSet(),
        containsAll(['netease|1', 'local|1']),
      );
    });

    test('导入：resolutions 缺省的项被跳过，不产生任何改动', () async {
      final database = await db.database;
      await database.insert('playback_stat', _stat(sourceId: '1', name: '本地'));

      final backup = writeBackup({
        'playback_stats': [_stat(sourceId: '2', name: '备份独有')],
      });
      await BackupService.import(backup, {});

      final rows = await database.query('playback_stat');
      expect(rows.length, 1);
      expect(rows.first['source_id'], '1', reason: '跳过时本地数据保持不变');
    });

    test('设置导入：合并写入备份中的值，且不清除备份没有的本地 key', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      final prefs = await SharedPreferences.getInstance();

      final backup = writeBackup({
        'settings': {'theme_mode': 'light', 'seed_color': 123456},
      });
      await BackupService.import(backup, {
        BackupItem.settings: ConflictStrategy.merge,
      });

      expect(prefs.getString('theme_mode'), 'light');
      expect(prefs.getInt('seed_color'), 123456);
      expect(
        prefs.getString('playback_quality'),
        isNull,
        reason: '备份中没有的 key 不应被写入',
      );
    });

    test('导出含分桶表；清库后覆盖导入可完整恢复图表数据', () async {
      final database = await db.database;
      await database.insert('playback_stat', _stat(sourceId: '1', name: '歌曲A'));
      await database.insert(
        'playback_stat_bucket',
        _bucket(dayStart: 1000000, sourceId: '1'),
      );
      await database.insert(
        'playback_stat_bucket',
        _bucket(dayStart: 2000000, sourceId: '1'),
      );

      final file = await BackupService.export(const [BackupItem.playbackStats]);
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(json['playback_stats'], isA<List>());
      expect(
        (json['playback_stats_buckets'] as List).length,
        2,
        reason: '分桶表应随 playbackStats 一起导出',
      );

      await database.delete('playback_stat');
      await database.delete('playback_stat_bucket');
      await BackupService.import(file, {
        BackupItem.playbackStats: ConflictStrategy.overwrite,
      });

      final buckets = await database.query('playback_stat_bucket');
      expect(buckets.length, 2, reason: '覆盖导入后分桶表应有数据（图表可用）');
    });

    test('播放记录合并：分桶表按 天|歌 去重，保留本地并追加备份独有', () async {
      final database = await db.database;
      await database.insert(
        'playback_stat_bucket',
        _bucket(dayStart: 100, sourceId: '1'),
      );

      final backup = writeBackup({
        'playback_stats': [_stat(sourceId: '1', name: '歌曲A')],
        'playback_stats_buckets': [
          _bucket(dayStart: 100, sourceId: '1'), // 本地已有 → 跳过
          _bucket(dayStart: 200, sourceId: '1'), // 备份独有（同歌不同天）→ 追加
          _bucket(dayStart: 100, sourceId: '2'), // 备份独有 → 追加
        ],
      });
      await BackupService.import(backup, {
        BackupItem.playbackStats: ConflictStrategy.merge,
      });

      final buckets = await database.query('playback_stat_bucket');
      expect(buckets.length, 3);
      final keys = buckets
          .map((b) => '${b['day_start']}|${b['source_id']}')
          .toSet();
      expect(keys, containsAll(['100|1', '200|1', '100|2']));
    });

    test('DB 项导入原子性：中途失败整体回滚', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: 'keep',
        name: '本地收藏',
        durationMs: 0,
        fee: 0,
        likedAtMs: 1,
      );

      final backup = writeBackup({
        'liked_songs': [
          {
            'source': 'netease',
            'source_id': 'backup',
            'name': '备份收藏',
            'artist': null,
            'album': null,
            'cover_url': null,
            'duration_ms': 0,
            'fee': 0,
            'liked_at': 2,
          },
        ],
        // 结构错误（非 Map 行）→ 触发事务回滚
        'recent_plays': ['notamap'],
      });
      expect(
        () => BackupService.import(backup, {
          BackupItem.likedSongs: ConflictStrategy.overwrite,
          BackupItem.recentPlays: ConflictStrategy.overwrite,
        }),
        throwsFormatException,
      );

      final liked = await db.getLikedSongs();
      expect(
        liked.map((s) => s.sourceId),
        contains('keep'),
        reason: 'recent_plays 失败时 liked_song 的覆盖也应回滚',
      );
      expect(
        liked.map((s) => s.sourceId),
        isNot(contains('backup')),
      );
    });
  });

  group('错误处理', () {
    test('检测冲突：JSON 语法损坏抛出 FormatException', () async {
      final f = File('${tempDir.path}/corrupt.json');
      f.writeAsStringSync('{"manifest": ');
      expect(
        () => BackupService.detectConflicts(f, const [BackupItem.playlists]),
        throwsFormatException,
      );
    });

    test('检测冲突：结构错误（playlists 为数组而非对象）抛出 FormatException', () async {
      final backup = writeBackup({
        'playlists': [_song(id: 1, name: '歌曲A')],
      });
      expect(
        () => BackupService.detectConflicts(
          backup,
          const [BackupItem.playlists],
        ),
        throwsFormatException,
      );
    });

    test('导入：备份文件损坏抛出 FormatException', () async {
      final f = File('${tempDir.path}/corrupt_import.json');
      f.writeAsStringSync('not json');
      expect(
        () => BackupService.import(
          f,
          {BackupItem.playlists: ConflictStrategy.merge},
        ),
        throwsFormatException,
      );
    });
  });
}
