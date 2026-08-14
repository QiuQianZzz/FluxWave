import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'logging/app_log.dart';
import 'playback_stats/database_helper.dart';

/// 备份项枚举。
enum BackupItem {
  settings('设置', '个性化配置（主题、播放、网络等）'),
  playlists('播放列表', '当前播放队列'),
  playbackStats('播放记录', '播放统计数据'),
  likedSongs('我喜欢的音乐', '收藏的歌曲'),
  recentPlays('最近播放', '最近播放的歌曲');

  final String label;
  final String description;
  const BackupItem(this.label, this.description);
}

/// 冲突解决策略。
enum ConflictStrategy {
  merge('合并', '保留已有数据，追加新数据'),
  overwrite('覆盖', '清除已有数据，导入备份数据');

  final String label;
  final String description;
  const ConflictStrategy(this.label, this.description);
}

/// 备份服务：导出/导入用户数据。
class BackupService {
  BackupService._();

  /// 导出备份文件。返回备份文件路径。
  ///
  /// [items] 选择要备份的项目。
  static Future<File> export(List<BackupItem> items) async {
    final manifest = <String, dynamic>{
      'version': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'items': items.map((e) => e.name).toList(),
    };

    final data = <String, dynamic>{'manifest': manifest};

    for (final item in items) {
      switch (item) {
        case BackupItem.settings:
          data['settings'] = await _exportSettings();
          break;
        case BackupItem.playlists:
          data['playlists'] = await _exportPlaylists();
          break;
        case BackupItem.playbackStats:
          data['playback_stats'] = await _exportPlaybackStats();
          break;
        case BackupItem.likedSongs:
          data['liked_songs'] = await _exportLikedSongs();
          break;
        case BackupItem.recentPlays:
          data['recent_plays'] = await _exportRecentPlays();
          break;
      }
    }

    final json = const JsonEncoder.withIndent('  ').convert(data);
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now();
    final name = 'fluxwave_backup_'
        '${ts.year}${_two(ts.month)}${_two(ts.day)}'
        '_${_two(ts.hour)}${_two(ts.minute)}${_two(ts.second)}'
        '.json';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(json, flush: true);
    return file;
  }

  /// 读取备份文件的 manifest（不含数据），用于展示备份内容。
  static Future<Map<String, dynamic>?> readManifest(File file) async {
    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json['manifest'] as Map<String, dynamic>?;
    } catch (e) {
      AppLog.warn('读取备份 manifest 失败', tag: 'backup', error: e);
      return null;
    }
  }

  /// 检查备份文件中包含哪些项目。
  static Future<List<BackupItem>> readItems(File file) async {
    final manifest = await readManifest(file);
    if (manifest == null) return [];
    final items = manifest['items'] as List<dynamic>? ?? [];
    return items
        .map((name) => BackupItem.values.where((e) => e.name == name).firstOrNull)
        .whereType<BackupItem>()
        .toList();
  }

  /// 检测具体冲突：返回每个项目中「备份与本地存在差异」的摘要列表。
  ///
  /// 差异包含三类，任一存在即视为冲突、需要用户抉择合并/覆盖：
  /// - 备份独有（本地没有，合并会新增）
  /// - 本地独有（备份没有，合并保留、覆盖清除）
  /// - 同一条目内容不同（同一首歌但数据不一致）
  ///
  /// 完全一致（两边都有且数据相同）不算差异，导入时静默保留。
  static Future<Map<BackupItem, List<String>>> detectConflicts(
    File file,
    List<BackupItem> items,
  ) async {
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    final db = DatabaseHelper.instance;
    final conflicts = <BackupItem, List<String>>{};

    for (final item in items) {
      switch (item) {
        case BackupItem.settings:
          final backupSettings = json['settings'] as Map<String, dynamic>? ?? {};
          final backupEntries = [
            for (final e in backupSettings.entries)
              {'name': e.key, 'value': e.value},
          ];
          final localEntries = await _loadLocalSettings();
          final conflicts_ = _itemDiffs(
            backup: backupEntries,
            local: localEntries,
            keyOf: (m) => m['name'] as String,
            compareKeys: const ['value'],
          );
          debugPrint(
            '[conflict] 设置: 备份=${backupEntries.length}, 本地=${localEntries.length}, 差异=${conflicts_.length}',
          );
          if (conflicts_.isNotEmpty) conflicts[item] = conflicts_;
          break;

        case BackupItem.playlists:
          final queue =
              (json['playlists'] as Map<String, dynamic>?)?['queue'] as List? ?? [];
          final backupQueue = queue
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          final localQueue = await _loadLocalQueue();
          final conflicts_ = _itemDiffs(
            backup: backupQueue,
            local: localQueue,
            keyOf: (m) => '${m['source']?.toString() ?? ''}|${m['id']}',
            compareKeys: _queueCompareKeys,
          );
          debugPrint(
            '[conflict] 播放队列: 备份=${backupQueue.length}, 本地=${localQueue.length}, 差异=${conflicts_.length}',
          );
          if (conflicts_.isNotEmpty) conflicts[item] = conflicts_;
          break;

        case BackupItem.playbackStats:
          final stats = json['playback_stats'] as List? ?? [];
          final backupStats = stats
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          final localRows = await db.database.then((d) => d.query('playback_stat'));
          final localStats = localRows
              .map((r) => Map<String, dynamic>.from(r))
              .toList();
          final conflicts_ = _itemDiffs(
            backup: backupStats,
            local: localStats,
            keyOf: (m) => '${m['source']}|${m['source_id']}',
            // 播放计数/收听时长等本就会因设备而异，不比对内容，只看集合差异
            compareKeys: const [],
          );
          debugPrint(
            '[conflict] 播放记录: 备份=${backupStats.length}, 本地=${localStats.length}, 差异=${conflicts_.length}',
          );
          if (conflicts_.isNotEmpty) conflicts[item] = conflicts_;
          break;

        case BackupItem.likedSongs:
          final liked = json['liked_songs'] as List? ?? [];
          final backupLiked = liked
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          final localLiked = (await db.getLikedSongs()).map((s) => s.toMap()).toList();
          final conflicts_ = _itemDiffs(
            backup: backupLiked,
            local: localLiked,
            keyOf: (m) => '${m['source']}|${m['source_id']}',
            compareKeys: const [
              'name', 'artist', 'album', 'cover_url',
              'duration_ms', 'fee', 'liked_at',
            ],
          );
          debugPrint(
            '[conflict] 我喜欢的音乐: 备份=${backupLiked.length}, 本地=${localLiked.length}, 差异=${conflicts_.length}',
          );
          if (conflicts_.isNotEmpty) conflicts[item] = conflicts_;
          break;

        case BackupItem.recentPlays:
          final recent = json['recent_plays'] as List? ?? [];
          final backupRecent = recent
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          final localRecent = (await db.getRecentPlayed(limit: 999999))
              .map((p) => p.toMap())
              .toList();
          final conflicts_ = _itemDiffs(
            backup: backupRecent,
            local: localRecent,
            keyOf: (m) => '${m['source']}|${m['source_id']}',
            // 最近播放时间本就会因设备而异，不比对内容，只看集合差异
            compareKeys: const [],
          );
          debugPrint(
            '[conflict] 最近播放: 备份=${backupRecent.length}, 本地=${localRecent.length}, 差异=${conflicts_.length}',
          );
          if (conflicts_.isNotEmpty) conflicts[item] = conflicts_;
          break;
      }
    }
    return conflicts;
  }

  /// 计算某类数据备份与本地之间的差异摘要列表。
  ///
  /// - 同一条目内容不同：`名称（内容不同）`
  /// - 备份独有：`备份新增 N 项：…`
  /// - 本地独有：`本地独有 N 项：…`
  static List<String> _itemDiffs({
    required List<Map<String, dynamic>> backup,
    required List<Map<String, dynamic>> local,
    required String Function(Map<String, dynamic>) keyOf,
    required List<String> compareKeys,
  }) {
    final localById = {for (final l in local) keyOf(l): l};
    final backupById = {for (final b in backup) keyOf(b): b};
    final result = <String>[];

    // 同一条目内容不同
    for (final b in backup) {
      final l = localById[keyOf(b)];
      if (l != null && _differs(b, l, compareKeys)) {
        result.add('${_nameOf(b)}（内容不同）');
      }
    }

    // 备份独有（本地没有，合并会新增 / 覆盖会写入）
    final backupOnly = backup.where((b) => !localById.containsKey(keyOf(b))).toList();
    if (backupOnly.isNotEmpty) {
      result.add('备份新增 ${backupOnly.length} 项：${_namesPreview(backupOnly)}');
    }

    // 本地独有（备份没有，合并保留 / 覆盖会清除）
    final localOnly = local.where((l) => !backupById.containsKey(keyOf(l))).toList();
    if (localOnly.isNotEmpty) {
      result.add('本地独有 ${localOnly.length} 项：${_namesPreview(localOnly)}');
    }

    return result;
  }

  static String _nameOf(Map<String, dynamic> m) {
    final name = m['name'];
    return (name == null || name.toString().isEmpty) ? '未知' : name.toString();
  }

  /// 最多展示 5 个名称，超出显示「等 N 项」。
  static String _namesPreview(List<Map<String, dynamic>> items) {
    final names = items.map(_nameOf).toList();
    if (names.length <= 5) return names.join('、');
    return '${names.take(5).join('、')} 等 ${names.length} 项';
  }

  /// 队列歌曲需参与比对的字段（不含标识键 source/id）。
  static const _queueCompareKeys = [
    'name', 'artists', 'albumId', 'albumName', 'coverUrl', 'durationMs', 'fee',
  ];

  /// 两条同键记录是否在某字段上不一致（列表用内容比较，其余按值比较）。
  static bool _differs(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    List<String> keys,
  ) {
    for (final key in keys) {
      final va = a[key];
      final vb = b[key];
      if (va is List || vb is List) {
        if (va is! List || vb is! List || !listEquals(va, vb)) return true;
      } else if (va != vb) {
        return true;
      }
    }
    return false;
  }

  /// 读取本地播放队列
  static Future<List<Map<String, dynamic>>> _loadLocalQueue() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}playback_queue.json');
      if (!await file.exists()) return [];
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (json['queue'] as List? ?? []).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// 导入备份数据。
  ///
  /// [file] 备份文件。
  /// [resolutions] 每项导入决策：key 为要导入的项目，value 为其冲突策略。
  /// 不在 map 中的项目将被跳过（不导入）。
  static Future<void> import(
    File file,
    Map<BackupItem, ConflictStrategy> resolutions,
  ) async {
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;

    for (final entry in resolutions.entries) {
      final item = entry.key;
      final strategy = entry.value;
      switch (item) {
        case BackupItem.settings:
          if (json.containsKey('settings')) {
            await _importSettings(json['settings'] as Map<String, dynamic>);
          }
          break;
        case BackupItem.playlists:
          if (json.containsKey('playlists')) {
            await _importPlaylists(
              json['playlists'] as Map<String, dynamic>,
              strategy,
            );
          }
          break;
        case BackupItem.playbackStats:
          if (json.containsKey('playback_stats')) {
            await _importPlaybackStats(
              json['playback_stats'] as List<dynamic>,
              strategy,
            );
          }
          break;
        case BackupItem.likedSongs:
          if (json.containsKey('liked_songs')) {
            await _importLikedSongs(
              json['liked_songs'] as List<dynamic>,
              strategy,
            );
          }
          break;
        case BackupItem.recentPlays:
          if (json.containsKey('recent_plays')) {
            await _importRecentPlays(
              json['recent_plays'] as List<dynamic>,
              strategy,
            );
          }
          break;
      }
    }
  }

  // ── 导出 ──

  static Future<Map<String, dynamic>> _exportSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    // 只导出个性化配置项（不含账号、图标、缓存、歌单等）
    for (final key in _settingsKeys) {
      if (prefs.containsKey(key)) {
        map[key] = prefs.get(key);
      }
    }
    return map;
  }

  /// 个性化配置 key 白名单（不含账号/图标/缓存/歌单等）
  static const _settingsKeys = [
    // 主题
    'theme_mode',
    'seed_color',
    'custom_colors',
    'predictive_back',
    'theme_dynamic_color',
    // 播放
    'playback_quality',
    'windows_volume_percent',
    'haptic_feedback',
    'auto_play_on_open',
    'audio_cache_max_mb',
    'line_lyric_reveal_mode',
    'lyric_depth_blur',
    'glass_blur',
    // 网络
    'netease_real_ip',
    'bypass_system_proxy',
    // 更新
    'check_update_on_start',
    'update_channel',
  ];

  static Future<List<Map<String, dynamic>>> _exportPlaybackStats() async {
    final db = DatabaseHelper.instance;
    final database = await db.database;
    final rows = await database.query('playback_stat');
    return rows;
  }

  static Future<List<Map<String, dynamic>>> _exportLikedSongs() async {
    final db = DatabaseHelper.instance;
    final songs = await db.getLikedSongs();
    return songs.map((s) => s.toMap()).toList();
  }

  static Future<List<Map<String, dynamic>>> _exportRecentPlays() async {
    final db = DatabaseHelper.instance;
    final plays = await db.getRecentPlayed(limit: 999999);
    return plays.map((p) => p.toMap()).toList();
  }

  /// 读取本地白名单内的设置项（key 不存在则不导出、不参与比对）。
  static Future<List<Map<String, dynamic>>> _loadLocalSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return [
      for (final key in _settingsKeys)
        if (prefs.containsKey(key)) {'name': key, 'value': prefs.get(key)},
    ];
  }

  /// 导出播放队列（playback_queue.json）
  static Future<Map<String, dynamic>?> _exportPlaylists() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}playback_queue.json');
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      debugPrint('[backup] 导出播放队列: ${(json['queue'] as List?)?.length ?? 0} 首');
      return json;
    } catch (e) {
      debugPrint('[backup] 导出播放队列失败: $e');
      return null;
    }
  }

  // ── 导入 ──

  static Future<void> _importSettings(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    // 设置项只有合并语义：写入备份中的值，保留本地多出的配置
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is bool) {
        await prefs.setBool(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      } else if (value is double) {
        await prefs.setDouble(key, value);
      } else if (value is String) {
        await prefs.setString(key, value);
      } else if (value is List) {
        await prefs.setStringList(key, value.cast<String>());
      }
    }
    AppLog.info('设置已导入: ${data.keys.length} 项', tag: 'backup');
  }

  static Future<void> _importPlaybackStats(
    List<dynamic> data,
    ConflictStrategy strategy,
  ) async {
    final db = DatabaseHelper.instance;
    final database = await db.database;
    final existingKeys = <String>{};
    if (strategy == ConflictStrategy.merge) {
      final rows = await database.query('playback_stat', columns: ['source', 'source_id']);
      existingKeys.addAll(rows.map((r) => '${r['source']}|${r['source_id']}'));
    } else {
      await database.delete('playback_stat');
      await database.delete('playback_stat_bucket');
    }
    for (final row in data) {
      final map = Map<String, dynamic>.from(row as Map);
      // 合并：保留本地已有条目，只追加备份中有而本地没有的
      if (existingKeys.contains('${map['source']}|${map['source_id']}')) continue;
      await database.insert(
        'playback_stat',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static Future<void> _importLikedSongs(
    List<dynamic> data,
    ConflictStrategy strategy,
  ) async {
    final db = DatabaseHelper.instance;
    final database = await db.database;
    final existingKeys = <String>{};
    if (strategy == ConflictStrategy.merge) {
      final rows = await database.query('liked_song', columns: ['source', 'source_id']);
      existingKeys.addAll(rows.map((r) => '${r['source']}|${r['source_id']}'));
    } else {
      await database.delete('liked_song');
    }
    for (final row in data) {
      final map = Map<String, dynamic>.from(row as Map);
      // 合并：保留本地已有收藏，只追加备份中有而本地没有的
      if (existingKeys.contains('${map['source']}|${map['source_id']}')) continue;
      await database.insert(
        'liked_song',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static Future<void> _importRecentPlays(
    List<dynamic> data,
    ConflictStrategy strategy,
  ) async {
    final db = DatabaseHelper.instance;
    final database = await db.database;
    final existingKeys = <String>{};
    if (strategy == ConflictStrategy.merge) {
      final rows = await database.query('recent_play', columns: ['source', 'source_id']);
      existingKeys.addAll(rows.map((r) => '${r['source']}|${r['source_id']}'));
    } else {
      await database.delete('recent_play');
    }
    for (final row in data) {
      final map = Map<String, dynamic>.from(row as Map);
      // 合并：保留本地已有记录，只追加备份中有而本地没有的
      if (existingKeys.contains('${map['source']}|${map['source_id']}')) continue;
      await database.insert(
        'recent_play',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// 导入播放队列（playback_queue.json）
  static Future<void> _importPlaylists(
    Map<String, dynamic> data,
    ConflictStrategy strategy,
  ) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}playback_queue.json');

      if (strategy == ConflictStrategy.merge) {
        // 合并：如果已有队列，追加备份中没有的歌曲
        if (await file.exists()) {
          final existing = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          final existingQueue = (existing['queue'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final importedQueue = (data['queue'] as List?)?.cast<Map<String, dynamic>>() ?? [];

          // 合并去重键与冲突检测一致：source|id（跨源同 id 不误判）
          final existingKeys = existingQueue
              .map((s) => '${s['source']?.toString() ?? ''}|${s['id']}')
              .toSet();
          for (final song in importedQueue) {
            final key = '${song['source']?.toString() ?? ''}|${song['id']}';
            if (!existingKeys.contains(key)) {
              existingQueue.add(song);
            }
          }

          debugPrint('[backup] 合并播放队列: 本地=${existingQueue.length} 首');
          final merged = {
            'v': data['v'] ?? 1,
            'queue': existingQueue,
            'currentIndex': existing['currentIndex'] ?? 0,
          };
          await file.writeAsString(jsonEncode(merged), flush: true);
          return;
        }
      }

      // 覆盖：直接写入备份数据
      debugPrint('[backup] 导入播放队列: ${(data['queue'] as List?)?.length ?? 0} 首');
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (e) {
      debugPrint('[backup] 导入播放队列失败: $e');
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
