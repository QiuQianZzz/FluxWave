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

  /// 检查本地已有数据（用于冲突检测）。
  static Future<Map<BackupItem, int>> countExisting() async {
    final db = DatabaseHelper.instance;
    final prefs = await SharedPreferences.getInstance();

    // 播放队列歌曲数
    int queueCount = 0;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}playback_queue.json');
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        queueCount = (json['queue'] as List?)?.length ?? 0;
      }
    } catch (_) {}

    return {
      BackupItem.settings: prefs.getKeys().length,
      BackupItem.playlists: queueCount,
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

  static Future<void> _importSettings(
    Map<String, dynamic> data,
    ConflictStrategy strategy,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (strategy == ConflictStrategy.overwrite) {
      // 只清除白名单内的 key，不影响歌单缓存、账号等
      for (final key in _settingsKeys) {
        await prefs.remove(key);
      }
    }
    // 合并和覆盖都写入备份中的值
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

          final existingIds = existingQueue.map((s) => s['id']).toSet();
          for (final song in importedQueue) {
            if (!existingIds.contains(song['id'])) {
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
