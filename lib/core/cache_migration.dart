import 'dart:io';

import 'app_dirs.dart';
import 'audio_cache/cache_index.dart';
import 'logging/app_log.dart';

/// 缓存目录结构迁移。
///
/// 版本历史：
/// - v1：旧 `audio_cache/` 目录（音频 bin + index.json）
/// - v2：`cache/audio/` 目录（音频 bin + index.json）
/// - v3：`cache/<songKey>/audio.bin`（每首歌一个目录）
///
/// 启动时调用 [migrate]，幂等执行未完成的迁移步骤。
class CacheMigration {
  CacheMigration._();

  /// 当前缓存结构版本号。每次目录结构变更递增。
  static const currentVersion = 3;

  /// SharedPreferences 存储键。
  static const _versionKey = 'cache_structure_version';

  /// 执行迁移。幂等；已完成则跳过。
  static Future<void> migrate() async {
    try {
      final prefs = await _getPrefs();
      final from = prefs.getInt(_versionKey);
      if (from >= currentVersion) return;

      AppLog.info('缓存迁移：v$from → v$currentVersion', tag: 'cache-migration');

      if (from < 2) await _migrateV1ToV2();
      if (from < 3) await _migrateV2ToV3();

      await prefs.setInt(_versionKey, currentVersion);
      AppLog.info('缓存迁移完成：v$currentVersion', tag: 'cache-migration');
    } catch (e, st) {
      AppLog.warn('缓存迁移失败（下次启动重试）', tag: 'cache-migration', error: e, stack: st);
    }
  }

  /// v1 → v2：`audio_cache/` → `cache/audio/`。
  static Future<void> _migrateV1ToV2() async {
    final oldDir = await appSupportDir('audio_cache');
    if (!await oldDir.exists()) return;

    final newCache = await appSupportDir('cache');
    final newAudio = Directory('${newCache.path}${Platform.pathSeparator}audio');
    await newAudio.create(recursive: true);

    await for (final entity in oldDir.list()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        final newPath = '${newAudio.path}${Platform.pathSeparator}$name';
        await entity.rename(newPath);
      }
    }

    try {
      await oldDir.delete(recursive: true);
    } catch (_) {}

    AppLog.info('v1→v2 迁移完成：audio_cache/ → cache/audio/', tag: 'cache-migration');
  }

  /// v2 → v3：`cache/audio/<key>.bin` → `cache/<songKey>/<level>_<type>.bin`。
  ///
  /// 同时清理旧的 `cache/cover/` 和 `cache/lyrics/` 目录（v2 实验性实现遗留）。
  static Future<void> _migrateV2ToV3() async {
    final cacheDir = await appSupportDir('cache');
    final audioDir = Directory('${cacheDir.path}${Platform.pathSeparator}audio');

    if (await audioDir.exists()) {
      // 复制旧索引到新位置（保留 br 等字段）
      final oldIndex = File(
        '${audioDir.path}${Platform.pathSeparator}index.json',
      );
      final newIndex = File(
        '${cacheDir.path}${Platform.pathSeparator}index.json',
      );
      if (await oldIndex.exists() && !await newIndex.exists()) {
        await oldIndex.copy(newIndex.path);
      }

      // 迁移 .bin 文件
      await for (final entity in audioDir.list()) {
        if (entity is File && entity.path.endsWith('.bin')) {
          final name = entity.uri.pathSegments.last;
          final audioKey = name.replaceAll('.bin', '');
          final songKey = CacheIndex.songKeyFromAudioKey(audioKey) ?? audioKey;
          final songDir = Directory(
            '${cacheDir.path}${Platform.pathSeparator}$songKey',
          );
          await songDir.create(recursive: true);
          // 还原音质后缀：去掉 songKey 前缀
          final prefix = '${songKey}_';
          final suffix = audioKey.startsWith(prefix)
              ? audioKey.substring(prefix.length)
              : audioKey;
          final newPath = '${songDir.path}${Platform.pathSeparator}$suffix.bin';
          await entity.rename(newPath);
        }
      }

      // 删除旧的 audio 目录（含 index.json，已复制到新位置）
      try {
        if (await audioDir.exists()) await audioDir.delete(recursive: true);
      } catch (_) {}
    }

    // 清理旧的 cover/lyrics 目录（v2 实验性实现遗留，文件已无用）
    for (final name in ['cover', 'lyrics']) {
      final dir = Directory('${cacheDir.path}${Platform.pathSeparator}$name');
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }

    AppLog.info('v2→v3 迁移完成：cache/audio/ → cache/<songKey>/', tag: 'cache-migration');
  }

  static Future<_SimplePrefs> _getPrefs() async {
    final support = await appSupportDir('');
    final file = File(
      '${support.path}${Platform.pathSeparator}.cache_version',
    );
    return _SimplePrefs(file);
  }
}

/// 轻量版本号存储，避免引入 SharedPreferences 依赖。
class _SimplePrefs {
  final File _file;
  _SimplePrefs(this._file);

  int getInt(String key) {
    try {
      if (!_file.existsSync()) return 1;
      final content = _file.readAsStringSync().trim();
      return int.tryParse(content) ?? 1;
    } catch (_) {
      return 1;
    }
  }

  Future<void> setInt(String key, int value) async {
    await _file.writeAsString('$value', flush: true);
  }
}
