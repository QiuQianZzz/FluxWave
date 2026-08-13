import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../models/playlist.dart';
import '../models/song.dart';
import 'app_dirs.dart';
import 'logging/app_log.dart';

/// 歌单详情磁盘缓存：每首歌单一个 JSON 文件，LRU 限张数，best-effort。
///
/// 文件名带音源命名空间（`playlist_<source>_<id>.json`），跨音源同 id 歌单
/// 不共用底稿。写入音源取自 [Playlist.source]；读取需传与之一致的 [source]
/// （默认网易云，[SongSource.netease]），未来接其它源时由调用方显式传源。
/// 缓存 header + 曲目，但去掉签名细粒度：只存 `meta + tracks`，由详情页用「先秒显缓存 → 后台刷新
/// 比对 → 有变化才整体替换」消费。
///
/// 写入单张的完整曲目（不分页截断）：首进网络拉到的明细就是权威底稿，缓存它
/// 才能保证二次进入整张秒显；单张 JSON 约 150~300KB，可控。
///
/// LRU 淘汰用内存 [LinkedHashMap] 维护写入顺序：首次使用时从磁盘按 mtime
/// 初始化，之后写入/驱逐都在内存操作，不依赖文件系统时间精度。
/// 读命中不写盘（不加 IO），毫秒级重开同一张详情不担心被挤出。
///
/// 所有异常静默：读失败/写失败/清理失败都不抛到调用方，页面照常降级为网络路径。
/// 测试可用 [PlaylistDetailCache.count] 观察落盘数量。
class PlaylistDetailCache {
  /// 磁盘保留的歌单详情缓存张数上限。
  static const int maxFiles = 10;

  final Directory? directory;

  /// 写入顺序表：key = 文件全路径，首次 [_ensureLoaded] 时按 mtime 排序填入。
  final LinkedHashMap<String, File> _order = LinkedHashMap();
  bool _loaded = false;

  PlaylistDetailCache({this.directory});

  /// 默认根目录：`<appSupport>/playlist_detail_cache`。
  static Future<Directory> defaultRoot() =>
      appSupportDir('playlist_detail_cache');

  Future<Directory> _root() async {
    final dir = directory ?? await defaultRoot();
    await dir.create(recursive: true);
    return dir;
  }

  String _filePath(Directory root, String source, int playlistId) =>
      '${root.path}${Platform.pathSeparator}'
      'playlist_${_sanitize(source)}_$playlistId.json';

  /// 文件名安全化：source 只保留字母数字下划线（防非预期字符进路径）。
  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// 首次使用时从磁盘加载现有文件到 [_order]（按 mtime 升序）。
  /// 之后写入直接追加到末尾，不再读 mtime。
  Future<void> _ensureLoaded(Directory root) async {
    if (_loaded) return;
    _loaded = true;
    final files = await _jsonFiles(root);
    final withMtime = <(File, DateTime)>[];
    for (final f in files) {
      withMtime.add((f, await f.lastModified()));
    }
    withMtime.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _) in withMtime) {
      _order[f.path] = f;
    }
  }

  /// 读取某歌单详情缓存；不存在/损坏/解析失败返回 null（不进 catch 抛错）。
  ///
  /// [source] 需与写入时 [Playlist.source] 一致（默认网易云）；未来接其它源
  /// 时由调用方显式传入对应 [SongSource]。
  Future<PlaylistDetailSnapshot?> read(
    int playlistId, {
    String source = SongSource.netease,
  }) async {
    try {
      final root = await _root();
      final f = File(_filePath(root, source, playlistId));
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      final meta = raw['meta'];
      final tracksRaw = raw['tracks'];
      if (meta is! Map) return null;
      final metaObj = Playlist.fromJson(Map<String, dynamic>.from(meta));
      final tracks = <Song>[];
      if (tracksRaw is List) {
        for (final e in tracksRaw) {
          if (e is Map) {
            tracks.add(Song.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      return PlaylistDetailSnapshot(
        meta: metaObj,
        tracks: List.unmodifiable(tracks),
      );
    } catch (e, st) {
      AppLog.warn(
        '歌单详情缓存读取失败 id=$playlistId',
        tag: 'playlist-detail',
        error: e,
        stack: st,
      );
      return null;
    }
  }

  /// 落盘某歌单详情（meta + 完整曲目）。失败静默，不影响页面。
  ///
  /// 音源取自 [meta.source]（模型自带命名空间，调用方无需另传）。
  /// 先写 `.tmp` 再 rename，避免中途崩溃留下半截 JSON（下次读取会被
  /// [read] 判坏数据忽略，但这比半份内容更干净）。
  Future<void> write(int playlistId, Playlist meta, List<Song> tracks) async {
    try {
      final root = await _root();
      await _ensureLoaded(root);
      final payload = jsonEncode({
        'meta': meta.toJson(),
        'tracks': [for (final s in tracks) s.toJson()],
      });
      final f = File(_filePath(root, meta.source, playlistId));
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(f.path);
      // 写入成功：移到顺序表末尾（最新）
      _order.remove(f.path);
      _order[f.path] = f;
      await _prune();
    } catch (e, st) {
      AppLog.warn(
        '歌单详情缓存写入失败 id=$playlistId',
        tag: 'playlist-detail',
        error: e,
        stack: st,
      );
    }
  }

  /// LRU：从顺序表头部删掉超过 [maxFiles] 的最旧条目。
  ///
  /// 驱逐顺序由 [_order]（LinkedHashMap 插入序）决定，不依赖文件系统 mtime。
  Future<void> _prune() async {
    try {
      while (_order.length > maxFiles) {
        final victim = _order.entries.first;
        _order.remove(victim.key);
        try {
          await victim.value.delete();
        } catch (_) {}
      }
    } catch (e, st) {
      AppLog.warn('歌单详情缓存清理失败', tag: 'playlist-detail', error: e, stack: st);
    }
  }

  /// 当前落盘的歌单缓存文件数（诊断/测试）。
  Future<int> count() async {
    try {
      final root = await _root();
      return (await _jsonFiles(root)).length;
    } catch (_) {
      return 0;
    }
  }

  /// 收集目录里所有歌单缓存 JSON 文件（排除 `.tmp`），异步枚举不阻塞主线程。
  Future<List<File>> _jsonFiles(Directory root) async {
    final out = <File>[];
    await for (final e in root.list()) {
      if (e is File && e.path.endsWith('.json') && !e.path.endsWith('.tmp')) {
        out.add(e);
      }
    }
    return out;
  }

  /// 清空全部歌单详情缓存（登出等场景）。
  Future<void> clearAll() async {
    try {
      final root = await _root();
      _order.clear();
      _loaded = false;
      for (final f in await _jsonFiles(root)) {
        await f.delete();
      }
    } catch (e, st) {
      AppLog.warn('歌单详情缓存清空失败', tag: 'playlist-detail', error: e, stack: st);
    }
  }
}

/// 单集缓存内容：歌单元信息 + 完整曲目。
class PlaylistDetailSnapshot {
  final Playlist meta;
  final List<Song> tracks;
  const PlaylistDetailSnapshot({required this.meta, required this.tracks});
}
