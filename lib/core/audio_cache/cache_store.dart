import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../app_dirs.dart';

/// 音频磁盘缓存：本地代理的数据落盘层。
///
/// 设计：
/// - **每首歌一个文件** `<key>.bin`，按**字节偏移**写入（`RandomAccessFile`），
///   seek 到哪段就补哪段，不做预取/不做整曲搬运。
/// - **范围位图**：内存 + 持久化记录已缓存区间（合并后的 `[start,end)` 列表），
///   用于「命中读本地 / 未命中回源」判定，重启后已缓存段仍可离线播。
/// - **总量上限**：默认 [defaultMaxBytes]（3GB），运行时经 [setMaxBytes] 调整，
///   按 `lastAccess` LRU 驱逐最久未触碰的整首文件。初始化与写入后兜底清理。
/// - **CDN 直链仅会话内存**：网易直链有时效，不持久化；[remember] 每次播放时
///   重新登记。**直链生命周期随「会话」不随「磁盘」**：驱逐/清理/内容失效都
///   只删磁盘字节，保留直链——若被清的歌再次续读/seek，代理仍能凭直链回源
///   重缓存、不断播。`_sessionUrls` 按 key 覆盖、纯内存、重启清空，上限
///   [maxSessionUrls]（默认 4096 条，最坏 ~2~4MB）按最近 remember 淘汰最旧，
///   防止长时间听歌内存持续增长；正常一次会话远低于此值，重复播放自动重新登记、
///   当前在播的歌必为最新一次 remember、不会被淘汰。重启后仅已缓存段可用，
///   缺段要等下次播放重新回源。
/// - 全 best-effort：任何失败静默，绝不抛到调用方。
class AudioCacheStore {
  AudioCacheStore._();

  /// 缓存上限默认值（MB，MiB 语义）：3072 MiB = 3 GiB 整。单一真源，
  /// [SettingsProvider] 经 [defaultCacheMaxMB] 引用，避免改默认值时两处漂移。
  static const int defaultCacheMaxMB = 3072;

  /// 缓存上限默认值（字节），由 [defaultCacheMaxMB] 派生。
  static const int defaultMaxBytes = defaultCacheMaxMB * 1024 * 1024;

  /// 测试用：覆盖 [maxBytes] 以便触发真实 LRU 驱逐。null = 用 [maxBytes]。
  @visibleForTesting
  int? overrideMaxBytes;

  int _maxBytes = defaultMaxBytes;

  /// 当前缓存上限（字节）。运行时经 [setMaxBytes] 调整并立即生效。
  int get maxBytes => _maxBytes;

  /// 调整缓存上限：改小立即 [AudioCacheStore] 驱逐到新上限，改大仅放宽。
  /// best-effort：store 未初始化（[enabled] 为 false）时仅记录字段，待 init 生效。
  void setMaxBytes(int bytes) {
    if (bytes <= 0) return;
    _maxBytes = bytes;
    if (enabled) _prune();
  }

  static final AudioCacheStore instance = AudioCacheStore._();

  static const String _indexFile = 'index.json';

  Directory? _root; // .../audio_cache
  bool _initAttempted = false;
  final Map<String, CacheEntry> _entries = {};
  // 会话内有效的 CDN 直链：key -> cdnUrl（不持久化）。
  final Map<String, String> _sessionUrls = {};

  /// 会话直链上限（条数）：超过后在 [remember] 时按「最近登记」顺序淘汰最旧，
  /// 把无硬上界的内存增长收窄成固定小值（4096×~1KB ≈ 4MB，桌面上可忽略）。
  /// 淘汰无可用性影响：重播会自动重新登记，当前在播的歌必为最新一次 remember、
  /// 落到最尾，不会被逐出（见 [remember]）。
  static const int maxSessionUrls = 4096;
  bool _indexDirty = false;
  Timer? _persistTimer;
  // 持久化写入句柄：分片随机写必须复用同一 RandomAccessFile。原因：
  // - FileMode.writeOnly 每次 open 会截断已存在文件（Windows 实测），会清掉已缓存段；
  // - FileMode.writeOnlyAppend / append 是 O_APPEND，忽略 setPosition（POSIX 语义），
  //   分片写到非末尾 offset 会错位。
  // 故每个 key 首次创建后保持句柄打开，后续 setPosition+write 复用。
  final Map<String, RandomAccessFile> _writers = {};
  // 串行化所有写：并发 Range 回源同时写不同 offset 时保证文件内不交错。
  Future<void> _writeChain = Future<void>.value();

  /// 缓存根目录（未初始化/失败为 null）。
  Directory? get rootDirectory => _root;

  /// 是否可用。
  bool get enabled => _root != null;

  /// 是否已初始化尝试过（供测试）。
  bool get initAttempted => _initAttempted;

  /// 初始化缓存目录（`<appSupport>/audio_cache`）。幂等；失败静默禁用。
  static Future<void> init({String? directory}) async {
    final store = instance;
    if (store._initAttempted) return;
    store._initAttempted = true;
    try {
      final root = directory != null
          ? Directory(directory)
          : await appSupportDir('audio_cache');
      await root.create(recursive: true);
      store._root = root;
      await store._loadIndex();
      store._prune();
    } catch (_) {
      store._root = null;
      store._entries.clear();
      store._sessionUrls.clear();
    }
  }

  /// 供测试直接指定目录。
  static void configureForTest(String directory) {
    final store = instance;
    store._closeWriters();
    store._root = Directory(directory);
    store._initAttempted = true;
    store._entries.clear();
    store._sessionUrls.clear();
    if (store._root!.existsSync()) {
      store._loadIndex(); // 不 await，测试里随后手动触发
    }
  }

  /// 复位（测试 tearDown）。
  static void resetForTest() {
    final store = instance;
    store._persistTimer?.cancel();
    store._persistTimer = null;
    store._writeChain = Future<void>.value();
    store._closeWriters();
    store._root = null;
    store._initAttempted = false;
    store._entries.clear();
    store._sessionUrls.clear();
    store._indexDirty = false;
    store.overrideMaxBytes = null;
    store._maxBytes = defaultMaxBytes;
  }

  void _closeWriters() {
    for (final raf in _writers.values) {
      try {
        raf.close();
      } catch (_) {}
    }
    _writers.clear();
  }

  /// 歌曲的缓存键（音源 + 歌曲 id + 音质 + 编码格式）。
  ///
  /// 形如 `<source>_<songId>_<level>_<type>`：source 前缀做命名空间，保证
  /// 跨音源同 id 的歌曲不共用缓存/直链（对照旧版裸 `<songId>_...`）。
  /// source/level/type 均 sanitize 为字母数字下划线。
  static String keyFor(String source, int songId, String level, String type) =>
      '${_sanitize(source)}_${songId}_${_sanitize(level)}_${_sanitize(type)}';

  /// 某歌在任意音质下的前缀（`<source>_<songId>_`），用于离线兜底扫全档。
  static String prefixFor(String source, int songId) =>
      '${_sanitize(source)}_${songId}_';

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// 本次播放登记 CDN 直链（每次播放刷新，覆盖时效）。
  ///
  /// 先移除再重插入使「最近登记」落在最尾：FIFO 淘汰最旧时，当前在播的歌
  /// （必然是最新一次 remember）永远在尾部、不会被逐出。超上限即淘汰最旧，
  /// 大小硬约束为 [maxSessionUrls]。
  void remember(String key, String cdnUrl) {
    _sessionUrls.remove(key);
    _sessionUrls[key] = cdnUrl;
    while (_sessionUrls.length > maxSessionUrls) {
      _sessionUrls.remove(_sessionUrls.keys.first);
    }
  }

  /// 当前会话登记的直链条数。
  int get sessionUrlCount => _sessionUrls.length;

  /// 当前会话有效的 CDN 直链；未登记返回 null。
  String? sessionUrl(String key) => _sessionUrls[key];

  /// 已登记条目（含从索引加载的）。
  CacheEntry? entry(String key) => _entries[key];

  /// 已缓存文件路径（不存在也返回路径）。
  String filePath(String key) =>
      '${_root!.path}${Platform.pathSeparator}$key.bin';

  /// 读取一段已缓存数据。该段未全部命中返回 null。
  ///
  /// [start] 含、[end] 不含。
  Future<List<int>?> read(String key, int start, int end) async {
    final root = _root;
    if (root == null) return null;
    final e = _entries[key];
    if (e == null || !_covers(e.ranges, start, end)) return null;
    e.touch();
    try {
      final f = File(filePath(key));
      if (!await f.exists()) return null;
      final raf = await f.open(mode: FileMode.read);
      try {
        await raf.setPosition(start);
        return await raf.read(end - start);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// 把回源得到的一段字节写入缓存（[offset] 为该段在整曲中的起点）。
  Future<void> write(String key, int offset, List<int> bytes) async {
    final root = _root;
    if (root == null || bytes.isEmpty) return;
    final run = _writeChain.then((_) => _writeNow(key, offset, bytes));
    _writeChain = run.catchError((_) {});
    try {
      await run;
    } catch (_) {
      // 写缓存失败静默（磁盘满/权限），不影响播放。
    }
  }

  Future<void> _writeNow(String key, int offset, List<int> bytes) async {
    final root = _root;
    if (root == null || bytes.isEmpty) return;
    try {
      final f = File(filePath(key));
      var raf = _writers[key];
      if (raf == null) {
        if (!await f.exists()) {
          await f.create(recursive: true);
        }
        raf = await f.open(mode: FileMode.writeOnly);
        _writers[key] = raf;
      }
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);
      final e = _entries.putIfAbsent(key, CacheEntry.new);
      e.addRange(offset, offset + bytes.length);
      final size = await f.length();
      e.sizeBytes = size;
      _indexDirty = true;
      _schedulePersist();
      _prune();
    } catch (_) {
      // 写缓存失败静默（磁盘满/权限），不影响播放。
    }
  }

  /// 记录远端文件总大小（来自 206 的 Content-Range）。
  ///
  /// 经 [_writeChain] 串行，避免与驱逐竞态：若直接同步 putIfAbsent，可能在
  /// `_prune` 同步删条目后、`_evictIo` 删文件前复活一个文件已被删的条目。
  Future<void> setTotalSize(String key, int total) {
    final run = _writeChain.then((_) {
      final e = _entries.putIfAbsent(key, CacheEntry.new);
      e.totalSize = total;
      _indexDirty = true;
    });
    _writeChain = run.catchError((_) {});
    return run;
  }

  /// 记录该 key 的实际码率（bps，来自听音 netease 解析）。用于离线命中时
  /// 在 UI 音质栏显示 kbps——缓存字节不携带码率，只能由在线解析期登记。
  ///
  /// 仅在 [br] > 0 时写入（0 = 未知，不为此造空条目）。经 [_writeChain] 串行，
  /// 与 setTotalSize/驱逐同一层互斥；best-effort 静默。
  /// 与 [setTotalSize] 同 key 复用同一条目，写盘/驱逐互不覆盖聚合信息。
  /// 此处必须用 [putIfAbsent]：首发登记的时机（路由期）先于同 key 代理写入，
  /// 若只在条目已存在时才写，反而让首次缓存永远记不上。异常路径（已路由但
  /// 没写成字节——代理失败/未发出 Range）会留下 `br>0, size=0` 的空条目：
  /// 它不计 totalBytes、isComplete 恒 false 不参与离线命中、LRU 若选中也无
  /// 文件可删，属无害（与 setTotalSize 同款模式）。
  Future<void> setBr(String key, int br) {
    if (br <= 0) return Future<void>.value();
    final run = _writeChain.then((_) {
      final e = _entries.putIfAbsent(key, CacheEntry.new);
      e.br = br;
      _indexDirty = true;
    });
    _writeChain = run.catchError((_) {});
    return run;
  }

  /// 内容校验失败时废弃旧缓存：清空条目/区间、关句柄、删文件，等下次回源重写。
  ///
  /// 同 key 的 CDN 字节若已变（重转码/改码），旧缓存不可再视为该 key 的内容。经 [_writeChain] 串行，
  /// 避免与排队写竞态。**保留 sessionUrl**：直链随会话存活（见类注释），
  /// 清盘后 miss 仍能回源重缓存、不断播。
  Future<void> invalidate(String key) {
    final run = _writeChain.then((_) => _invalidateNow(key));
    _writeChain = run.catchError((_) {});
    return run.catchError((_) {});
  }

  Future<void> _invalidateNow(String key) async {
    _entries.remove(key);
    try {
      await _writers[key]?.close();
      _writers.remove(key);
      final f = File(filePath(key));
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _indexDirty = true;
  }

  /// 某段是否全部命中。
  bool isCached(String key, int start, int end) {
    final e = _entries[key];
    return e != null && _covers(e.ranges, start, end);
  }

  /// 整曲是否已完整缓存（totalSize>0 且
  /// 合并后的 range 连续覆盖 `[0,totalSize)`，无空洞）。
  ///
  /// 供播放前短路：完整命中则完全离线可播，无需 CDN 直链。
  bool isComplete(String key) {
    final e = _entries[key];
    if (e == null || e.totalSize <= 0) return false;
    return _coversWhole(e, e.totalSize);
  }

  static bool _coversWhole(CacheEntry e, int total) {
    if (total <= 0) return false;
    var pos = 0;
    for (final r in e.ranges) {
      if (r.start > pos) return false;
      if (r.end > pos) pos = r.end;
      if (pos >= total) return true;
    }
    return pos >= total;
  }

  /// 所有 key 当前缓存文件总数（诊断/测试）。
  int get entryCount => _entries.length;

  /// 已登记的所有缓存 key。
  Iterable<String> get keys => _entries.keys;

  /// 当前缓存总字节（诊断/测试）。
  int get totalBytes => _entries.values.fold(0, (a, e) => a + e.sizeBytes);

  /// 已缓存歌曲数（按「音源 + 歌曲 id」去重：同一首歌缓存多档/多编码只算 1 首）。
  ///
  /// key 形如 `<source>_<songId>_<level>_<type>`，取前两段即 (source, songId)。
  /// 兼容旧版裸 `<songId>_<level>_<type>`：首段为纯数字时按旧格式识别（source
  /// 记为 ''，跨源去重不生效，仅计数兜底）。
  int get songCount {
    final ids = <(String, int)>{};
    for (final key in _entries.keys) {
      final seg = key.split('_');
      if (seg.isEmpty) continue;
      // 旧格式首段即 songId（纯数字）。
      final legacyId = int.tryParse(seg[0]);
      if (legacyId != null) {
        ids.add(('', legacyId));
        continue;
      }
      // 新格式：`<source>_<songId>_...`。
      if (seg.length < 2) continue;
      final id = int.tryParse(seg[1]);
      if (id != null) ids.add((seg[0], id));
    }
    return ids.length;
  }

  /// 清空全部磁盘缓存（关句柄/删文件/清条目/落索引）。
  ///
  /// 仅释放磁盘：**保留 sessionUrl**（见类注释），当前/后续播放 miss 仍能凭直链
  /// 回源重缓存，不会因清理而 404 卡死。keys 在调用时刻快照，此后排队的 write
  /// 所产生的条目不在清空范围内（语义 = 清掉「调用时已存在」的磁盘数据）。
  ///
  /// 经 [_writeChain] 串行，避免与排队写竞态；best-effort，失败静默。
  Future<void> clearAll() {
    final keys = List<String>.from(_entries.keys);
    final run = _writeChain.then((_) async {
      for (final key in keys) {
        await _invalidateNow(key);
      }
      await _persistIfDirty();
    });
    _writeChain = run.catchError((_) {});
    return run.catchError((_) {});
  }

  static bool _covers(List<Range> ranges, int start, int end) {
    if (end <= start) return true;
    for (final r in ranges) {
      if (r.start <= start && end <= r.end) return true;
    }
    return false;
  }

  /// LRU：总量超过上限时按 lastAccess 驱逐整首，直到放下限或只剩一项。
  ///
  /// 驱逐经 [_writeChain] 串行化，避免与排队中的 [write] 竞态（否则驱后被
  /// 排队的写会重开文件、`putIfAbsent` 复活已驱逐条目）。
  void _prune() {
    final root = _root;
    if (root == null) return;
    final limit = overrideMaxBytes ?? maxBytes;
    if (totalBytes <= limit || _entries.length <= 1) return;
    var ordered = _entries.entries.toList()
      ..sort((a, b) => a.value.lastAccess.compareTo(b.value.lastAccess));
    final victims = <String>[];
    while (totalBytes > limit && ordered.length > 1) {
      final victim = ordered.removeAt(0).key;
      // 同步移除，使 totalBytes 随每次驱逐重算、只驱逐到放下限为止。
      _entries.remove(victim);
      victims.add(victim);
    }
    for (final victim in victims) {
      // 条目已同步移除（驱逐语义即时生效），仅把文件层 IO（关句柄/删文件）串行
      // 进 _writeChain，避免与排队中的 write 竞态：排队写会在删文件前跑完，后续
      // 对新文件的写走在新副本之后，不再「复活」已被驱逐、文件被删的旧副本。
      _writeChain = _writeChain
          .then((_) => _evictIo(victim))
          .catchError((_) {});
    }
  }

  /// 驱逐的落盘执行（关句柄 + 删条目 + 删文件 + 落索引），由 [_prune] 在链上
  /// 串行调用。
  ///
  /// **原子语义**：这里同时删 `_entries` 条目与物理文件，避免「条目在、文件无」
  /// 的不一致——若排队中的 [write] 先于本 IO 执行（`putIfAbsent` 复活条目并写
  /// 文件），本 IO 会把它再次删掉，最终条目与文件一致地消失。`_prune` 里的同步
  /// 移除保证 while 循环的 LRU 判定即时生效，这里是兜底收口。
  ///
  /// **保留 sessionUrl**：直链随会话存活（见类注释），被驱逐的歌若再次续读/seek
  /// 仍能回源重缓存，避免「磁盘已清 + 直链已删 → 404 卡死」。
  Future<void> _evictIo(String key) async {
    _entries.remove(key);
    try {
      await _writers[key]?.close();
      _writers.remove(key);
      final f = File(filePath(key));
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _indexDirty = true;
    await _persistIfDirty();
  }

  // ── 索引持久化 ──

  Future<void> _loadIndex() async {
    final root = _root;
    if (root == null) return;
    try {
      final f = File('${root.path}${Platform.pathSeparator}$_indexFile');
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map) return;
      final entries = data['entries'];
      if (entries is! Map) return;
      _entries.clear();
      entries.forEach((key, v) {
        if (v is! Map) return;
        final e = CacheEntry()
          ..totalSize = (v['totalSize'] as num?)?.toInt() ?? 0
          ..sizeBytes = (v['size'] as num?)?.toInt() ?? 0
          ..lastAccess = (v['lastAccess'] as num?)?.toInt() ?? 0
          ..br = (v['br'] as num?)?.toInt() ?? 0;
        final ranges = v['ranges'];
        if (ranges is List) {
          for (final r in ranges) {
            if (r is List && r.length == 2) {
              e.addRange((r[0] as num).toInt(), (r[1] as num).toInt());
            }
          }
        }
        _entries[key.toString()] = e;
      });
    } catch (_) {
      _entries.clear();
    }
  }

  Future<void> _persistIfDirty() async {
    if (!_indexDirty) return;
    _indexDirty = false;
    final root = _root;
    if (root == null) return;
    try {
      final payload = <String, dynamic>{
        'version': 1,
        'entries': {
          for (final MapEntry(key: k, value: e) in _entries.entries)
            k: {
              'totalSize': e.totalSize,
              'size': e.sizeBytes,
              'lastAccess': e.lastAccess,
              'br': e.br,
              'ranges': [
                for (final r in e.ranges) [r.start, r.end],
              ],
            },
        },
      };
      final f = File('${root.path}${Platform.pathSeparator}$_indexFile');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      _indexDirty = true; // 失败回退，下次再试
    }
  }

  /// 主动刷盘（测试/退出兜底）。
  Future<void> flush() {
    _persistTimer?.cancel();
    _persistTimer = null;
    return _persistIfDirty();
  }

  /// 每次写入后节流落盘：避免每片都同步写一遍 index.json，又保证
  /// 播放中途崩溃/被杀时索引不丢太多。
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 800), () {
      _persistTimer = null;
      unawaited(_persistIfDirty());
    });
  }
}

/// 单曲缓存元数据。
class CacheEntry {
  int totalSize = 0;
  int sizeBytes = 0;
  int lastAccess = 0;
  int br = 0;
  final List<Range> ranges = [];

  CacheEntry();

  /// 记录已缓存区间并合并重叠/相邻段，同时刷新 lastAccess。
  void addRange(int start, int end) {
    if (end <= start) return;
    lastAccess = DateTime.now().millisecondsSinceEpoch;
    final all = [...ranges, Range(start, end)]
      ..sort((a, b) => a.start.compareTo(b.start));
    final merged = <Range>[];
    var cur = all.first;
    for (var i = 1; i < all.length; i++) {
      final r = all[i];
      if (r.start <= cur.end) {
        if (r.end > cur.end) cur = Range(cur.start, r.end);
      } else {
        merged.add(cur);
        cur = r;
      }
    }
    merged.add(cur);
    ranges
      ..clear()
      ..addAll(merged);
  }

  /// 读命中时刷新最近访问。
  void touch() => lastAccess = DateTime.now().millisecondsSinceEpoch;
}

/// 半开区间 [start, end)。
class Range {
  final int start;
  final int end;
  const Range(this.start, this.end);
}
