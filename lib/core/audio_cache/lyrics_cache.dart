import 'dart:async';
import 'dart:io';

import '../app_dirs.dart';
import '../logging/app_log.dart';

/// 歌词磁盘缓存：按歌曲 key 存储歌词文本。
///
/// 目录结构：`cache/<songKey>/lyrics.txt`
/// 歌词为纯文本（LRC/YRC/NRC 格式），体积小（1-10KB），不参与 LRU 驱逐。
/// 随音频缓存一起清理：音频被驱逐时随歌曲目录一起删除。
class LyricsCache {
  LyricsCache._();

  static final instance = LyricsCache._();

  Directory? _cacheRoot; // .../cache
  bool _initAttempted = false;

  /// 是否可用。
  bool get enabled => _cacheRoot != null;

  /// 初始化歌词缓存（`<appSupport>/cache`）。幂等；失败静默禁用。
  static Future<void> init({String? directory}) async {
    final cache = instance;
    if (cache._initAttempted) return;
    cache._initAttempted = true;
    try {
      final root = directory != null
          ? Directory(directory)
          : await appSupportDir('cache');
      await root.create(recursive: true);
      cache._cacheRoot = root;
    } catch (_) {
      cache._cacheRoot = null;
    }
  }

  /// 供测试直接指定目录。
  static void configureForTest(String directory) {
    final cache = instance;
    cache._cacheRoot = Directory(directory);
    cache._initAttempted = true;
  }

  /// 复位（测试 tearDown）。
  static void resetForTest() {
    final cache = instance;
    cache._cacheRoot = null;
    cache._initAttempted = false;
  }

  /// 歌词文件路径（不存在也返回路径）。
  /// [isTtml] 为 true 时返回 TTML 专用缓存文件，否则返回平台歌词文件。
  String filePath(String songKey, {bool isTtml = false}) =>
      '${_cacheRoot!.path}${Platform.pathSeparator}$songKey${Platform.pathSeparator}${isTtml ? 'lyrics_ttml.txt' : 'lyrics.txt'}';

  /// 读取歌词文本。不存在返回 null。
  /// [isTtml] 为 true 时读取 TTML 缓存，否则读取平台歌词缓存。
  Future<String?> read(String songKey, {bool isTtml = false}) async {
    final root = _cacheRoot;
    if (root == null) return null;
    try {
      final f = File(filePath(songKey, isTtml: isTtml));
      if (await f.exists()) return await f.readAsString();
    } catch (_) {}
    return null;
  }

  /// 写入歌词文本。
  /// [isTtml] 为 true 时写入 TTML 缓存，否则写入平台歌词缓存。
  Future<void> write(String songKey, String lyrics, {bool isTtml = false}) async {
    final root = _cacheRoot;
    if (root == null || lyrics.isEmpty) return;
    try {
      final f = File(filePath(songKey, isTtml: isTtml));
      await f.create(recursive: true);
      await f.writeAsString(lyrics, flush: true);
    } catch (e) {
      AppLog.warn('歌词缓存写入失败 key=$songKey', tag: 'lyrics-cache', error: e);
    }
  }

  /// 删除指定歌曲的歌词（平台 + TTML 缓存一并删除）。
  Future<void> delete(String songKey) async {
    final root = _cacheRoot;
    if (root == null) return;
    try {
      for (final name in ['lyrics.txt', 'lyrics_ttml.txt']) {
        final f = File(
          '${root.path}${Platform.pathSeparator}$songKey${Platform.pathSeparator}$name',
        );
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  /// 清空全部歌词缓存（平台 + TTML）。
  Future<void> clearAll() async {
    final root = _cacheRoot;
    if (root == null) return;
    try {
      await for (final entity in root.list()) {
        if (entity is Directory) {
          for (final name in ['lyrics.txt', 'lyrics_ttml.txt']) {
            final f = File(
              '${entity.path}${Platform.pathSeparator}$name',
            );
            if (await f.exists()) await f.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// 当前歌词文件总数（诊断/测试）。统计平台 + TTML 缓存。
  Future<int> count() async {
    final root = _cacheRoot;
    if (root == null) return 0;
    try {
      var n = 0;
      await for (final entity in root.list()) {
        if (entity is Directory) {
          for (final name in ['lyrics.txt', 'lyrics_ttml.txt']) {
            final f = File(
              '${entity.path}${Platform.pathSeparator}$name',
            );
            if (await f.exists()) n++;
          }
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }
}
