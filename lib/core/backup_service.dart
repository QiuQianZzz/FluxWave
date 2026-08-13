import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'logging/app_log.dart';
import 'playback_stats/database_helper.dart';

/// 备份项枚举。
enum BackupItem {
  settings('设置', '应用偏好设置'),
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

  /// 检查本地已有数据（用于冲突检测）。
  static Future<Map<BackupItem, int>> countExisting() async {
    final db = DatabaseHelper.instance;
    final prefs = await SharedPreferences.getInstance();
    return {
      BackupItem.settings: prefs.getKeys().length,
      BackupItem.playbackStats: (await db.getTotalStats()).playCount,
      BackupItem.likedSongs: await db.countLikedSongs(),
      BackupItem.recentPlays: (await db.getRecentPlayed()).length,
    };
  }

  /// 导入备份数据。
  ///
  /// [file] 备份文件。
  /// [items] 要导入的项目。
  /// [strategy] 冲突解决策略。
  static Future<void> import(
    File file,
    List<BackupItem> items,
    ConflictStrategy strategy,
  ) async {
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;

    for (final item in items) {
      switch (item) {
        case BackupItem.settings:
          if (json.containsKey('settings')) {
            await _importSettings(
              json['settings'] as Map<String, dynamic>,
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
    // 跳过内部 key（缓存版本号等非用户设置）
    const skipKeys = {'cache_structure_version'};
    for (final key in prefs.getKeys()) {
      if (skipKeys.contains(key)) continue;
      map[key] = prefs.get(key);
    }
    return map;
  }

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

  // ── 导入 ──

  static Future<void> _importSettings(
    Map<String, dynamic> data,
    ConflictStrategy strategy,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (strategy == ConflictStrategy.overwrite) {
      await prefs.clear();
    }
    // 合并和覆盖都写入备份中的值：
    // - 合并：更新已有 key，保留备份中没有的 key
    // - 覆盖：先清空再写入
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
  }

  static Future<void> _importPlaybackStats(
    List<dynamic> data,
    ConflictStrategy strategy,
  ) async {
    final db = DatabaseHelper.instance;
    final database = await db.database;
    if (strategy == ConflictStrategy.overwrite) {
      await database.delete('playback_stat');
      await database.delete('playback_stat_bucket');
    }
    for (final row in data) {
      final map = Map<String, dynamic>.from(row as Map);
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
    if (strategy == ConflictStrategy.overwrite) {
      await database.delete('liked_song');
    }
    // 合并和覆盖都用 replace：
    // - 合并：备份有的写入（新歌插入，已有歌更新 liked_at）
    // - 覆盖：先清空再写入
    for (final row in data) {
      final map = Map<String, dynamic>.from(row as Map);
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
    if (strategy == ConflictStrategy.overwrite) {
      await database.delete('recent_play');
    }
    for (final row in data) {
      final map = Map<String, dynamic>.from(row as Map);
      await database.insert(
        'recent_play',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
