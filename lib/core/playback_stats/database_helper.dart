import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'playback_stats_models.dart';

/// SQLite 数据库助手（播放记录存储）
///
/// 跨平台支持：Android/iOS/macOS 使用原生 sqflite，Windows 使用 FFI。
class DatabaseHelper {
  static DatabaseHelper? _instance;
  static Database? _database;
  static Future<Database>? _initFuture;
  static bool _factoryInitialized = false;

  DatabaseHelper._();

  static DatabaseHelper get instance {
    _instance ??= DatabaseHelper._();
    return _instance!;
  }

  /// 初始化数据库工厂（Windows/Linux 桌面端需要 FFI）
  static void init() {
    if (_factoryInitialized) return;
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _factoryInitialized = true;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    // 防止并发初始化：多个 await database 若同时进入，_initFuture 保证只开一次。
    _initFuture ??= _initDatabase();
    _database = await _initFuture!;
    _initFuture = null;
    return _database!;
  }

  /// 最近播放列表上限（超出直接清理最旧）。
  static const int maxRecentPlays = 500;

  Future<Database> _initDatabase() async {
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'playback.db');
    return openDatabase(
      path,
      version: 4,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createRecentPlayTable(db);
    }
    if (oldVersion < 3) {
      // recent_play 增加 fee 列：还原付费角标（此前无 fee 只能默认免费）。
      // 用 PRAGMA 探测而非直接 ALTER——v1→v3 直达时 _createRecentPlayTable
      // 已建出含 fee 的表，再 ALTER 会 duplicate column name。
      await _addColumnIfMissing(
        db,
        table: 'recent_play',
        column: 'fee',
        definition: 'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 4) {
      await _createLikedSongTable(db);
    }
  }

  /// 给表补列（幂等）：列已存在则跳过，否则 ALTER TABLE 添加。
  Future<void> _addColumnIfMissing(
    Database db, {
    required String table,
    required String column,
    required String definition,
  }) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final has = cols.any((c) => c['name'] == column);
    if (!has) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE playback_stat (
        source        TEXT NOT NULL,
        source_id     TEXT NOT NULL,
        name          TEXT NOT NULL,
        artist        TEXT,
        album         TEXT,
        cover_url     TEXT,
        duration_ms   INTEGER DEFAULT 0,
        play_count    INTEGER DEFAULT 0,
        total_listen_ms INTEGER DEFAULT 0,
        first_played_at INTEGER NOT NULL,
        last_played_at  INTEGER NOT NULL,
        PRIMARY KEY (source, source_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE playback_stat_bucket (
        day_start     INTEGER NOT NULL,
        source        TEXT NOT NULL,
        source_id     TEXT NOT NULL,
        play_count    INTEGER DEFAULT 0,
        total_listen_ms INTEGER DEFAULT 0,
        first_played_at INTEGER NOT NULL,
        last_played_at  INTEGER NOT NULL,
        PRIMARY KEY (day_start, source, source_id)
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_bucket_day ON playback_stat_bucket(day_start)',
    );
    await db.execute(
      'CREATE INDEX idx_stat_last ON playback_stat(last_played_at)',
    );
    await db.execute(
      'CREATE INDEX idx_stat_first ON playback_stat(first_played_at)',
    );

    await _createRecentPlayTable(db);
    await _createLikedSongTable(db);
  }

  Future<void> _createRecentPlayTable(Database db) async {
    // 最近播放：每首歌一行（去重），重复播放顶到最前（played_at 更新）。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recent_play (
        source        TEXT NOT NULL,
        source_id     TEXT NOT NULL,
        name          TEXT NOT NULL,
        artist        TEXT,
        album         TEXT,
        cover_url     TEXT,
        duration_ms   INTEGER DEFAULT 0,
        fee           INTEGER NOT NULL DEFAULT 0,
        played_at     INTEGER NOT NULL,
        PRIMARY KEY (source, source_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_recent_played ON recent_play(played_at)',
    );
  }

  Future<void> _createLikedSongTable(Database db) async {
    // 我喜欢的音乐：每首歌一行（去重），存整曲快照字段，按收藏时间排序。
    // 与 recent_play 相同的展开列风格，离线可直接渲染列表（不依赖网络）。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS liked_song (
        source        TEXT NOT NULL,
        source_id     TEXT NOT NULL,
        name          TEXT NOT NULL,
        artist        TEXT,
        album         TEXT,
        cover_url     TEXT,
        duration_ms   INTEGER DEFAULT 0,
        fee           INTEGER NOT NULL DEFAULT 0,
        liked_at      INTEGER NOT NULL,
        PRIMARY KEY (source, source_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_liked_at ON liked_song(liked_at)',
    );
  }

  /// 记录播放（更新总表 + 按天分桶表）
  Future<void> recordPlay({
    required String source,
    required String sourceId,
    required String name,
    String? artist,
    String? album,
    String? coverUrl,
    required int durationMs,
    required int listenMs,
    required int nowMs,
  }) async {
    final db = await database;
    final dayStart = _startOfDayMs(nowMs);

    // 更新总表 playback_stat
    final existing = await db.query(
      'playback_stat',
      where: 'source = ? AND source_id = ?',
      whereArgs: [source, sourceId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('playback_stat', {
        'source': source,
        'source_id': sourceId,
        'name': name,
        'artist': artist,
        'album': album,
        'cover_url': coverUrl,
        'duration_ms': durationMs,
        'play_count': 1,
        'total_listen_ms': listenMs,
        'first_played_at': nowMs,
        'last_played_at': nowMs,
      });
    } else {
      final row = existing.first;
      final oldFirst = row['first_played_at'] as int;
      await db.update(
        'playback_stat',
        {
          'name': name,
          'artist': artist,
          'album': album,
          'cover_url': coverUrl,
          'duration_ms': durationMs,
          'play_count': (row['play_count'] as int) + 1,
          'total_listen_ms': (row['total_listen_ms'] as int) + listenMs,
          'first_played_at': oldFirst < nowMs ? oldFirst : nowMs,
          'last_played_at': nowMs,
        },
        where: 'source = ? AND source_id = ?',
        whereArgs: [source, sourceId],
      );
    }

    // 更新按天分桶表 playback_stat_bucket
    final existingBucket = await db.query(
      'playback_stat_bucket',
      where: 'day_start = ? AND source = ? AND source_id = ?',
      whereArgs: [dayStart, source, sourceId],
      limit: 1,
    );

    if (existingBucket.isEmpty) {
      await db.insert('playback_stat_bucket', {
        'day_start': dayStart,
        'source': source,
        'source_id': sourceId,
        'play_count': 1,
        'total_listen_ms': listenMs,
        'first_played_at': nowMs,
        'last_played_at': nowMs,
      });
    } else {
      final bucket = existingBucket.first;
      final oldFirst = bucket['first_played_at'] as int;
      await db.update(
        'playback_stat_bucket',
        {
          'play_count': (bucket['play_count'] as int) + 1,
          'total_listen_ms': (bucket['total_listen_ms'] as int) + listenMs,
          'first_played_at': oldFirst < nowMs ? oldFirst : nowMs,
          'last_played_at': nowMs,
        },
        where: 'day_start = ? AND source = ? AND source_id = ?',
        whereArgs: [dayStart, source, sourceId],
      );
    }
  }

  /// 获取指定日期的播放统计
  Future<PlaybackStats> getStatsForDay(DateTime date) async {
    final db = await database;
    final dayStart = _startOfDayMs(date.millisecondsSinceEpoch);
    final dayEnd = dayStart + 86400000;

    final buckets = await db.rawQuery(
      '''
      SELECT b.*, s.name, s.artist, s.album, s.cover_url, s.duration_ms
      FROM playback_stat_bucket b
      JOIN playback_stat s ON b.source = s.source AND b.source_id = s.source_id
      WHERE b.day_start >= ? AND b.day_start < ?
      ORDER BY b.total_listen_ms DESC
    ''',
      [dayStart, dayEnd],
    );

    return _buildStatsFromBuckets(buckets, [dayStart], dayEnd);
  }

  /// 获取指定周的播放统计
  Future<PlaybackStats> getStatsForWeek(DateTime date) async {
    final db = await database;
    final weekStart = _startOfWeekMs(date.millisecondsSinceEpoch);
    final weekEnd = weekStart + 7 * 86400000;

    final buckets = await db.rawQuery(
      '''
      SELECT b.*, s.name, s.artist, s.album, s.cover_url, s.duration_ms
      FROM playback_stat_bucket b
      JOIN playback_stat s ON b.source = s.source AND b.source_id = s.source_id
      WHERE b.day_start >= ? AND b.day_start < ?
      ORDER BY b.total_listen_ms DESC
    ''',
      [weekStart, weekEnd],
    );

    final days = List.generate(7, (i) => weekStart + i * 86400000);
    return _buildStatsFromBuckets(buckets, days, weekEnd);
  }

  /// 获取指定月的播放统计
  Future<PlaybackStats> getStatsForMonth(int year, int month) async {
    final db = await database;
    final monthStart = DateTime(year, month).millisecondsSinceEpoch;
    final monthEnd = DateTime(year, month + 1).millisecondsSinceEpoch;

    final buckets = await db.rawQuery(
      '''
      SELECT b.*, s.name, s.artist, s.album, s.cover_url, s.duration_ms
      FROM playback_stat_bucket b
      JOIN playback_stat s ON b.source = s.source AND b.source_id = s.source_id
      WHERE b.day_start >= ? AND b.day_start < ?
      ORDER BY b.total_listen_ms DESC
    ''',
      [monthStart, monthEnd],
    );

    final daysCount = DateTime(
      year,
      month + 1,
    ).difference(DateTime(year, month)).inDays;
    final days = List.generate(
      daysCount,
      (i) => DateTime(year, month, i + 1).millisecondsSinceEpoch,
    );
    return _buildStatsFromBuckets(buckets, days, monthEnd);
  }

  /// 获取指定年的播放统计（按月聚合桶数据，再汇总歌曲排行/热力图）
  Future<PlaybackStats> getStatsForYear(int year) async {
    final db = await database;
    final yearStart = DateTime(year).millisecondsSinceEpoch;
    final yearEnd = DateTime(year + 1).millisecondsSinceEpoch;

    // 查出该年内所有日桶（带歌曲信息）
    final buckets = await db.rawQuery(
      '''
      SELECT b.*, s.name, s.artist, s.album, s.cover_url, s.duration_ms
      FROM playback_stat_bucket b
      JOIN playback_stat s ON b.source = s.source AND b.source_id = s.source_id
      WHERE b.day_start >= ? AND b.day_start < ?
      ORDER BY b.total_listen_ms DESC
    ''',
      [yearStart, yearEnd],
    );

    // ── 歌曲排行（与日/周/月共享逻辑）──
    final songMap = <String, _AggregatedSong>{};
    // ── 月级聚合 ──
    final monthMap = <int, _MonthAgg>{};

    for (final row in buckets) {
      final key = '${row['source']}|${row['source_id']}';
      final dayMs = row['day_start'] as int;
      final listenMs = row['total_listen_ms'] as int? ?? 0;
      final count = row['play_count'] as int? ?? 0;
      final firstPlayed = row['first_played_at'] as int;

      // 歌曲聚合（复用与 _buildStatsFromBuckets 相同的逻辑）
      final song = songMap[key] ??= _AggregatedSong(
        source: row['source'] as String,
        sourceId: row['source_id'] as String,
        name: row['name'] as String,
        artist: row['artist'] as String?,
        album: row['album'] as String?,
        coverUrl: row['cover_url'] as String?,
        durationMs: (row['duration_ms'] as int?) ?? 0,
      );
      song.totalListenMs += listenMs;
      song.playCount += count;
      if (song.firstPlayedAt == 0 || firstPlayed < song.firstPlayedAt) {
        song.firstPlayedAt = firstPlayed;
      }

      // 月级聚合：从 dayStart 提取 (year, month) 作为键
      final dt = DateTime.fromMillisecondsSinceEpoch(dayMs);
      final monthKey = DateTime(dt.year, dt.month).millisecondsSinceEpoch;
      final month = monthMap[monthKey] ??= _MonthAgg(monthKey);
      month.totalListenMs += listenMs;
      month.playCount += count;
    }

    // 排行榜
    final topSongs = songMap.values.toList()
      ..sort((a, b) => b.totalListenMs.compareTo(a.totalListenMs));
    final ranking = topSongs
        .take(50)
        .map(
          (s) => RankingItem(
            source: s.source,
            sourceId: s.sourceId,
            name: s.name,
            artist: s.artist,
            album: s.album,
            coverUrl: s.coverUrl,
            durationMs: s.durationMs,
            totalListenMs: s.totalListenMs,
            playCount: s.playCount,
            firstPlayedAt: s.firstPlayedAt,
          ),
        )
        .toList();

    // 每月统计（固定 12 个月）
    final dailyStats = List.generate(12, (i) {
      final monthStart = DateTime(year, i + 1).millisecondsSinceEpoch;
      final agg = monthMap[monthStart];
      return DailyStat(
        date: DateTime(year, i + 1),
        totalListenMs: agg?.totalListenMs ?? 0,
        songCount: 0, // 年视图不细分每月歌曲数，置 0
        playCount: agg?.playCount ?? 0,
      );
    });

    // 热力图（按月聚合）
    final heatmapData = monthMap.entries
        .map(
          (e) => HeatmapEntry(
            date: DateTime.fromMillisecondsSinceEpoch(e.key),
            value: (e.value.totalListenMs / 60000).round(),
          ),
        )
        .toList();

    final totalListenMs = songMap.values.fold<int>(
      0,
      (sum, s) => sum + s.totalListenMs,
    );
    final playCount = songMap.values.fold<int>(
      0,
      (sum, s) => sum + s.playCount,
    );

    return PlaybackStats(
      totalListenMs: totalListenMs,
      uniqueSongs: songMap.length,
      playCount: playCount,
      dailyBreakdown: dailyStats,
      topSongs: ranking,
      heatmapData: heatmapData,
    );
  }

  /// 获取总播放统计
  Future<PlaybackStats> getTotalStats() async {
    final db = await database;

    final stats = await db.rawQuery('''
      SELECT * FROM playback_stat ORDER BY total_listen_ms DESC
    ''');

    final totalListenMs = stats.fold<int>(
      0,
      (sum, r) => sum + (r['total_listen_ms'] as int? ?? 0),
    );
    final playCount = stats.fold<int>(
      0,
      (sum, r) => sum + (r['play_count'] as int? ?? 0),
    );
    final topSongs = stats
        .take(50)
        .map(
          (r) => RankingItem(
            source: r['source'] as String,
            sourceId: r['source_id'] as String,
            name: r['name'] as String,
            artist: r['artist'] as String?,
            album: r['album'] as String?,
            coverUrl: r['cover_url'] as String?,
            durationMs: (r['duration_ms'] as int?) ?? 0,
            totalListenMs: (r['total_listen_ms'] as int?) ?? 0,
            playCount: (r['play_count'] as int?) ?? 0,
            firstPlayedAt: r['first_played_at'] as int,
          ),
        )
        .toList();

    // 热力图数据（按天聚合）
    final heatmapRaw = await db.rawQuery('''
      SELECT day_start, SUM(total_listen_ms) as total_ms
      FROM playback_stat_bucket
      GROUP BY day_start
      ORDER BY day_start
    ''');

    final heatmapData = heatmapRaw
        .map(
          (r) => HeatmapEntry(
            date: DateTime.fromMillisecondsSinceEpoch(r['day_start'] as int),
            value: ((r['total_ms'] as int) / 60000).round(), // 转为分钟
          ),
        )
        .toList();

    return PlaybackStats(
      totalListenMs: totalListenMs,
      uniqueSongs: stats.length,
      playCount: playCount,
      dailyBreakdown: const [],
      topSongs: topSongs,
      heatmapData: heatmapData,
    );
  }

  /// 记录最近播放（去重：同一首重复播放直接更新 played_at 顶到最前）。
  ///
  /// 每首播放过（含未达统计阈值的短播）都会写入；超过 [maxRecentPlays] 条
  /// 时直接删除最旧的记录。与统计表 [recordPlay] 相互独立：统计表只记达到
  /// 阈值的有效播放（喂排行/热力图），此表负责「最近播放」的时间线语义。
  Future<void> recordRecentPlay({
    required String source,
    required String sourceId,
    required String name,
    String? artist,
    String? album,
    String? coverUrl,
    required int durationMs,
    required int fee,
    required int playedAtMs,
  }) async {
    final db = await database;
    await db.rawInsert('''
      INSERT INTO recent_play (
        source, source_id, name, artist, album, cover_url, duration_ms,
        fee, played_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source, source_id) DO UPDATE SET
        name = excluded.name,
        artist = excluded.artist,
        album = excluded.album,
        cover_url = excluded.cover_url,
        duration_ms = excluded.duration_ms,
        fee = excluded.fee,
        played_at = excluded.played_at
    ''', [
      source,
      sourceId,
      name,
      artist,
      album,
      coverUrl,
      durationMs,
      fee,
      playedAtMs,
    ]);

    // 超出上限：删除最旧的记录（保留最新的 maxRecentPlays 行）。
    // 用 rowid 标识行，played_at 并列时按 rowid 决胜，保证恰好保留上限行数。
    await db.rawDelete('''
      DELETE FROM recent_play
      WHERE rowid NOT IN (
        SELECT rowid FROM (
          SELECT rowid FROM recent_play
          ORDER BY played_at DESC, rowid DESC
          LIMIT ?
        )
      )
    ''', [maxRecentPlays]);
  }

  /// 获取最近播放列表（最新在前，played_at 并列时按 rowid 决胜与清理一致）
  Future<List<RecentPlay>> getRecentPlayed({int limit = maxRecentPlays}) async {
    final db = await database;
    final rows = await db.query(
      'recent_play',
      orderBy: 'played_at DESC, rowid DESC',
      limit: limit,
    );
    return rows.map(RecentPlay.fromMap).toList();
  }

  /// 收藏一首歌（UPSERT：已收藏则更新时间与快照字段，不产生重复行）。
  ///
  /// [likedAtMs] 供测试注入确定时间；默认取当前时间戳。
  Future<void> addLikedSong({
    required String source,
    required String sourceId,
    required String name,
    String? artist,
    String? album,
    String? coverUrl,
    required int durationMs,
    required int fee,
    int? likedAtMs,
  }) async {
    final db = await database;
    await db.rawInsert('''
      INSERT INTO liked_song (
        source, source_id, name, artist, album, cover_url, duration_ms,
        fee, liked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source, source_id) DO UPDATE SET
        name = excluded.name,
        artist = excluded.artist,
        album = excluded.album,
        cover_url = excluded.cover_url,
        duration_ms = excluded.duration_ms,
        fee = excluded.fee,
        liked_at = excluded.liked_at
    ''', [
      source,
      sourceId,
      name,
      artist,
      album,
      coverUrl,
      durationMs,
      fee,
      likedAtMs ?? DateTime.now().millisecondsSinceEpoch,
    ]);
  }

  /// 取消收藏一首歌。返回是否确实删除了一行。
  Future<bool> removeLikedSong({
    required String source,
    required String sourceId,
  }) async {
    final db = await database;
    final n = await db.delete(
      'liked_song',
      where: 'source = ? AND source_id = ?',
      whereArgs: [source, sourceId],
    );
    return n > 0;
  }

  /// 是否已收藏某首歌。
  Future<bool> isLikedSong({
    required String source,
    required String sourceId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'liked_song',
      columns: ['source_id'],
      where: 'source = ? AND source_id = ?',
      whereArgs: [source, sourceId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 获取全部收藏（按收藏时间倒序，最新在前）。
  Future<List<LikedSong>> getLikedSongs() async {
    final db = await database;
    final rows = await db.query(
      'liked_song',
      orderBy: 'liked_at DESC, rowid DESC',
    );
    return rows.map(LikedSong.fromMap).toList();
  }

  /// 收藏总数。
  Future<int> countLikedSongs() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM liked_song',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 获取最近一年按天聚合的热力图数据（始终完整52周，不依赖当前选中周期）。
  /// 无活动的天填充 0，保证网格完整。
  Future<List<HeatmapEntry>> getHeatmapForLastYear() async {
    final db = await database;
    final now = DateTime.now();
    final yearAgo = DateTime(now.year - 1, now.month, now.day + 1);
    final rows = await db.rawQuery(
      '''
      SELECT day_start, SUM(total_listen_ms) as total_ms
      FROM playback_stat_bucket
      WHERE day_start >= ?
      GROUP BY day_start
      ORDER BY day_start
    ''',
      [yearAgo.millisecondsSinceEpoch],
    );

    // 构建日期→时长 映射
    final map = <int, int>{};
    for (final r in rows) {
      map[r['day_start'] as int] = ((r['total_ms'] as int) / 60000).round();
    }

    // 填充完整一年（含无活动天 = 0）
    final result = <HeatmapEntry>[];
    var dt = DateTime(yearAgo.year, yearAgo.month, yearAgo.day);
    final today = DateTime(now.year, now.month, now.day);
    while (!dt.isAfter(today)) {
      final key = dt.millisecondsSinceEpoch;
      result.add(HeatmapEntry(date: dt, value: map[key] ?? 0));
      dt = dt.add(const Duration(days: 1));
    }
    return result;
  }

  /// 构建统计结果（聚合桶数据）
  PlaybackStats _buildStatsFromBuckets(
    List<Map<String, dynamic>> buckets,
    List<int> periodDays,
    int periodEnd,
  ) {
    // 聚合每首歌的统计
    final songMap = <String, _AggregatedSong>{};
    final dailyMap = <int, _DailyAgg>{};

    for (final row in buckets) {
      final key = '${row['source']}|${row['source_id']}';
      final dayStart = row['day_start'] as int;
      final listenMs = row['total_listen_ms'] as int? ?? 0;
      final count = row['play_count'] as int? ?? 0;

      // 歌曲聚合
      final song = songMap[key] ??= _AggregatedSong(
        source: row['source'] as String,
        sourceId: row['source_id'] as String,
        name: row['name'] as String,
        artist: row['artist'] as String?,
        album: row['album'] as String?,
        coverUrl: row['cover_url'] as String?,
        durationMs: (row['duration_ms'] as int?) ?? 0,
      );
      song.totalListenMs += listenMs;
      song.playCount += count;
      final firstPlayed = row['first_played_at'] as int;
      if (song.firstPlayedAt == 0 || firstPlayed < song.firstPlayedAt) {
        song.firstPlayedAt = firstPlayed;
      }

      // 每天聚合
      final daily = dailyMap[dayStart] ??= _DailyAgg(dateMs: dayStart);
      daily.totalListenMs += listenMs;
      daily.songCount++;
      daily.playCount += count;
    }

    // 构建排行榜
    final topSongs = songMap.values.toList()
      ..sort((a, b) => b.totalListenMs.compareTo(a.totalListenMs));
    final ranking = topSongs
        .take(50)
        .map(
          (s) => RankingItem(
            source: s.source,
            sourceId: s.sourceId,
            name: s.name,
            artist: s.artist,
            album: s.album,
            coverUrl: s.coverUrl,
            durationMs: s.durationMs,
            totalListenMs: s.totalListenMs,
            playCount: s.playCount,
            firstPlayedAt: s.firstPlayedAt,
          ),
        )
        .toList();

    // 构建每日统计
    final dailyStats = periodDays.map((dayMs) {
      final agg = dailyMap[dayMs];
      return DailyStat(
        date: DateTime.fromMillisecondsSinceEpoch(dayMs),
        totalListenMs: agg?.totalListenMs ?? 0,
        songCount: agg?.songCount ?? 0,
        playCount: agg?.playCount ?? 0,
      );
    }).toList();

    // 热力图数据
    final heatmapData = dailyMap.entries
        .map(
          (e) => HeatmapEntry(
            date: DateTime.fromMillisecondsSinceEpoch(e.key),
            value: (e.value.totalListenMs / 60000).round(),
          ),
        )
        .toList();

    final totalListenMs = songMap.values.fold<int>(
      0,
      (sum, s) => sum + s.totalListenMs,
    );
    final playCount = songMap.values.fold<int>(
      0,
      (sum, s) => sum + s.playCount,
    );

    return PlaybackStats(
      totalListenMs: totalListenMs,
      uniqueSongs: songMap.length,
      playCount: playCount,
      dailyBreakdown: dailyStats,
      topSongs: ranking,
      heatmapData: heatmapData,
    );
  }

  /// 获取某天0点的毫秒时间戳
  static int _startOfDayMs(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(dt.year, dt.month, dt.day).millisecondsSinceEpoch;
  }

  /// 获取某周周一0点的毫秒时间戳
  static int _startOfWeekMs(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final weekday = dt.weekday; // 1=Monday
    final monday = dt.subtract(Duration(days: weekday - 1));
    return DateTime(
      monday.year,
      monday.month,
      monday.day,
    ).millisecondsSinceEpoch;
  }
}

/// 聚合用的歌曲临时数据
class _AggregatedSong {
  final String source;
  final String sourceId;
  final String name;
  final String? artist;
  final String? album;
  final String? coverUrl;
  final int durationMs;
  int totalListenMs = 0;
  int playCount = 0;
  int firstPlayedAt = 0;

  _AggregatedSong({
    required this.source,
    required this.sourceId,
    required this.name,
    this.artist,
    this.album,
    this.coverUrl,
    this.durationMs = 0,
  });
}

/// 聚合用的每日临时数据
class _DailyAgg {
  final int dateMs;
  int totalListenMs = 0;
  int songCount = 0;
  int playCount = 0;

  _DailyAgg({required this.dateMs});
}

/// 聚合用的每月临时数据（年视图）
class _MonthAgg {
  final int monthMs;
  int totalListenMs = 0;
  int playCount = 0;

  _MonthAgg(this.monthMs);
}
