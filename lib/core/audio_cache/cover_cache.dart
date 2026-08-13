import 'dart:async';
import 'dart:io';

import '../app_dirs.dart';
import '../logging/app_log.dart';

/// 封面磁盘缓存：按歌曲 key 存储 JPEG 文件。
///
/// 目录结构：`cache/<songKey>/cover.jpg`
/// 与音频缓存共用歌曲目录，驱逐时随目录一起删除。
class CoverCache {
  CoverCache._();

  static final instance = CoverCache._();

  Directory? _cacheRoot; // .../cache
  bool _initAttempted = false;

  /// 是否可用。
  bool get enabled => _cacheRoot != null;

  /// 初始化封面缓存（`<appSupport>/cache`）。幂等；失败静默禁用。
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

  /// 封面文件路径（不存在也返回路径）。
  String filePath(String songKey) =>
      '${_cacheRoot!.path}${Platform.pathSeparator}$songKey${Platform.pathSeparator}cover.jpg';

  /// 读取封面文件。不存在返回 null。
  Future<File?> read(String songKey) async {
    final root = _cacheRoot;
    if (root == null) return null;
    try {
      final f = File(filePath(songKey));
      if (await f.exists()) return f;
    } catch (_) {}
    return null;
  }

  /// 写入封面文件。[bytes] 为 JPEG 数据。
  Future<void> write(String songKey, List<int> bytes) async {
    final root = _cacheRoot;
    if (root == null || bytes.isEmpty) return;
    try {
      final f = File(filePath(songKey));
      await f.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    } catch (e) {
      AppLog.warn('封面缓存写入失败 key=$songKey', tag: 'cover-cache', error: e);
    }
  }

  /// 删除指定歌曲的封面。
  Future<void> delete(String songKey) async {
    final root = _cacheRoot;
    if (root == null) return;
    try {
      final f = File(filePath(songKey));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 清空全部封面缓存。
  Future<void> clearAll() async {
    final root = _cacheRoot;
    if (root == null) return;
    try {
      await for (final entity in root.list()) {
        if (entity is Directory) {
          final cover = File(
            '${entity.path}${Platform.pathSeparator}cover.jpg',
          );
          if (await cover.exists()) await cover.delete();
        }
      }
    } catch (_) {}
  }

  /// 当前封面文件总数（诊断/测试）。
  Future<int> count() async {
    final root = _cacheRoot;
    if (root == null) return 0;
    try {
      var n = 0;
      await for (final entity in root.list()) {
        if (entity is Directory) {
          final cover = File(
            '${entity.path}${Platform.pathSeparator}cover.jpg',
          );
          if (await cover.exists()) n++;
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 当前封面缓存总字节（诊断/测试）。
  Future<int> totalBytes() async {
    final root = _cacheRoot;
    if (root == null) return 0;
    try {
      var total = 0;
      await for (final entity in root.list()) {
        if (entity is Directory) {
          final cover = File(
            '${entity.path}${Platform.pathSeparator}cover.jpg',
          );
          if (await cover.exists()) total += await cover.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
