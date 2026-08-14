import 'dart:async';
import 'dart:io';

import '../app_dirs.dart';
import '../logging/app_log.dart';

/// 封面磁盘缓存：按歌曲 key + 尺寸存储 JPEG 文件。
///
/// 目录结构：`cache/<songKey>/cover_<size>.jpg`
///
/// 按尺寸独立落盘，避免「小尺寸请求先写入、污染同一文件，导致全屏封面
/// 用 300/100 的小图拉伸变糊」。读取时：
/// - 优先命中精确尺寸 `cover_<size>.jpg`；
/// - 缺失时回退到最大尺寸 `cover_1000.jpg`（小尺寸展示用大图，保证清晰）；
/// - 大尺寸请求绝不回退到小图。
///
/// 与音频缓存共用歌曲目录，驱逐时随目录一起删除。
class CoverCache {
  CoverCache._();

  static final instance = CoverCache._();

  /// 尺寸回退上限：请求小图而精确尺寸缺失时，用该最大尺寸文件兜底。
  static const maxSize = 1000;

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
  String filePath(String songKey, int size) =>
      '${_cacheRoot!.path}${Platform.pathSeparator}$songKey${Platform.pathSeparator}cover_$size.jpg';

  /// 读取封面文件。精确尺寸缺失时，小尺寸请求回退到最大尺寸
  /// `cover_1000.jpg`；大尺寸请求绝不读小图。不存在返回 null。
  Future<File?> read(String songKey, int size) async {
    final root = _cacheRoot;
    if (root == null) return null;
    try {
      var f = File(filePath(songKey, size));
      if (await f.exists()) return f;
      if (size != maxSize) {
        f = File(filePath(songKey, maxSize));
        if (await f.exists()) return f;
      }
    } catch (_) {}
    return null;
  }

  /// 写入封面文件。[bytes] 为 JPEG 数据。
  Future<void> write(String songKey, int size, List<int> bytes) async {
    final root = _cacheRoot;
    if (root == null || bytes.isEmpty) return;
    try {
      final f = File(filePath(songKey, size));
      await f.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    } catch (e) {
      AppLog.warn(
        '封面缓存写入失败 key=$songKey size=$size',
        tag: 'cover-cache',
        error: e,
      );
    }
  }

  /// 删除指定歌曲的封面（所有尺寸）。
  Future<void> delete(String songKey) async {
    final root = _cacheRoot;
    if (root == null) return;
    try {
      final dir = Directory(
        '${root.path}${Platform.pathSeparator}$songKey',
      );
      if (!await dir.exists()) return;
      await for (final f in _coverFiles(dir)) {
        await f.delete();
      }
    } catch (_) {}
  }

  /// 清空全部封面缓存。
  Future<void> clearAll() async {
    final root = _cacheRoot;
    if (root == null) return;
    try {
      await for (final entity in root.list()) {
        if (entity is Directory) {
          await for (final f in _coverFiles(entity)) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// 当前封面文件总数（诊断/测试）。
  Future<int> count() async {
    final root = _cacheRoot;
    if (root == null) return 0;
    var n = 0;
    try {
      await for (final entity in root.list()) {
        if (entity is Directory) {
          await for (final _ in _coverFiles(entity)) {
            n++;
          }
        }
      }
    } catch (_) {}
    return n;
  }

  /// 当前封面缓存总字节（诊断/测试）。
  Future<int> totalBytes() async {
    final root = _cacheRoot;
    if (root == null) return 0;
    var total = 0;
    try {
      await for (final entity in root.list()) {
        if (entity is Directory) {
          await for (final f in _coverFiles(entity)) {
            total += await f.length();
          }
        }
      }
    } catch (_) {}
    return total;
  }

  /// 歌曲目录下的封面文件：`cover_<size>.jpg`（兼容旧版单文件 `cover.jpg`）。
  Stream<File> _coverFiles(Directory dir) async* {
    try {
      final legacy = File('${dir.path}${Platform.pathSeparator}cover.jpg');
      if (await legacy.exists()) yield legacy;
      final prefix = '${dir.path}${Platform.pathSeparator}cover_';
      await for (final entity in dir.list()) {
        if (entity is File &&
            entity.path.startsWith(prefix) &&
            entity.path.endsWith('.jpg')) {
          yield entity;
        }
      }
    } catch (_) {}
  }
}
