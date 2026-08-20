import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/song.dart';

/// 播放器状态持久化快照：队列 + 当前索引 + 当前曲播放进度 + 播放状态。
///
/// 设备级快照（不区分账号），重启应用后恢复上次的播放列表与续播位置。
/// 这是 [PlayerPlaybackStorage.load] 返回的内存 DTO；落盘时队列走文件、
/// 状态走 SharedPreferences（见 [PlayerPlaybackStorage]）。
class PlaybackSnapshot {
  final List<Song> queue;
  final int? currentIndex;

  /// 当前曲目最近一次播放进度（毫秒）。
  final int positionMs;

  /// 是否处于播放中（历史退出态）。启动恢复是否自动播放由设置
  /// `SettingsProvider.autoPlayOnOpen` 决定，不再据此驱动；字段仍持久化
  /// 以保留历史信息，便于未来恢复逻辑变化与调试。
  final bool playing;

  /// 是否随机播放（乱序推进）。
  final bool shuffleMode;

  /// 循环模式索引（[LoopMode] 生命周期外定义，避免核心层反向依赖 provider）。
  /// `0` = 列表循环，`1` = 单曲循环。
  final int loopModeIndex;

  /// 随机播放时的洗牌序（队列下标置换表）。随机模式开启时持久化，以保住跨
  /// 会话的「下一首」布局；null 或非法（长度不符/越界/重复）时由恢复方重建。
  final List<int>? shuffleOrder;

  const PlaybackSnapshot({
    required this.queue,
    required this.currentIndex,
    required this.positionMs,
    required this.playing,
    this.shuffleMode = false,
    this.loopModeIndex = 0,
    this.shuffleOrder,
  });

  bool get isEmpty => queue.isEmpty;
}

/// 队列文件解析结果状态。
enum _QueueFileStatus { ok, corrupt, unknownVersion }

/// 后台 isolate 解析结果容器（字段均为可 send 的简单类型）。
class _DecodedQueue {
  final _QueueFileStatus status;
  final List<Song> queue;
  final int? currentIndex;
  final List<int>? shuffleOrder;
  const _DecodedQueue.ok(this.queue, this.currentIndex, {this.shuffleOrder})
    : status = _QueueFileStatus.ok;
  const _DecodedQueue.corrupt()
    : status = _QueueFileStatus.corrupt,
      queue = const [],
      currentIndex = null,
      shuffleOrder = null;
  const _DecodedQueue.unknown()
    : status = _QueueFileStatus.unknownVersion,
      queue = const [],
      currentIndex = null,
      shuffleOrder = null;
}

/// 纯函数：在后台 isolate 里读队列文件并解析（顶层函数、无闭包、可 spawn）。
///
/// - ok：解析成功（queue 可能为空，是否删由调用方决定）；
/// - corrupt：文件缺失 / 空 / JSON 损坏 / 结构非法（调用方需删文件）；
/// - unknownVersion：未来版本，不删文件，本次跳过。
/// isolate 层自身的 spawn/传输失败会向上抛，由调用方区分处理（不删文件）。
_DecodedQueue _decodeQueueFile(String path) {
  try {
    final raw = File(path).readAsStringSync();
    if (raw.isEmpty) return const _DecodedQueue.corrupt();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return const _DecodedQueue.corrupt();
    // 版本校验：`v` 缺失视为 1（早期无数字段文件）；其它值视为未知版本，
    // 保留文件供未来版本处理，避免旧 App 误删新数据。
    final version = (decoded['v'] as num?)?.toInt() ?? 1;
    if (version != 1) return const _DecodedQueue.unknown();
    final queue = (decoded['queue'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Song.fromJson)
        .toList(growable: false);
    final rawOrder = decoded['shuffleOrder'];
    final shuffleOrder = rawOrder is List
        ? rawOrder
              .whereType<num>()
              .map((e) => e.toInt())
              .toList(growable: false)
        : null;
    return _DecodedQueue.ok(
      queue,
      (decoded['currentIndex'] as num?)?.toInt(),
      shuffleOrder: shuffleOrder,
    );
  } catch (_) {
    return const _DecodedQueue.corrupt();
  }
}

/// 播放器持久化层：**队列走文件，状态走 SharedPreferences**。
///
/// 队列此前存在 SP 单键里（整份 JSON 字符串），几万首时会有平台大值限制、
/// 全量重写与启动同步解析问题。现迁到应用支持目录下的 JSON 文件：
/// - 大队列不再受 SP 单键大值约束；
/// - 队列变更走 temp+rename 原子写（单文件 I/O）；
/// - 状态组保持 SP（小、高频，位置节流 ~5s 写，不触碰队列文件）。
///
/// 历史 SP 单键数据的迁移见 [migrateLegacy]（应用未分发，仅此一条跨到当前格式）。
class PlayerPlaybackStorage {
  static const String _kStateKey = 'playback_state_v1';
  static const int _kQueueSchemaVersion = 1;

  /// 当前队列文件名（不带版本号；格式版本由文件内 `v` 字段声明）。
  static const String _kQueueFileName = 'playback_queue.json';

  final SharedPreferences _prefs;
  final File _queueFile;

  PlayerPlaybackStorage._(this._prefs, this._queueFile);

  /// 构建持久化层。测试可注入 [directory]（临时目录），否则用应用支持目录。
  static Future<PlayerPlaybackStorage> init({Directory? directory}) async {
    final prefs = await SharedPreferences.getInstance();
    final dir = directory ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return PlayerPlaybackStorage._(
      prefs,
      File('${dir.path}${Platform.pathSeparator}$_kQueueFileName'),
    );
  }

  /// 队列文件是否已存在（迁移短路门控）。
  Future<bool> hasFileQueue() async => _queueFile.exists();

  /// 写队列组（大、低频）：空队列直接删文件；否则 temp+rename 原子写。
  Future<void> saveQueue(
    List<Song> queue,
    int? currentIndex, {
    List<int>? shuffleOrder,
  }) async {
    if (queue.isEmpty) {
      if (await _queueFile.exists()) await _queueFile.delete();
      return;
    }
    final tmp = File('${_queueFile.path}.tmp');
    try {
      final payload = jsonEncode({
        'v': _kQueueSchemaVersion,
        'queue': queue.map((s) => s.toJson()).toList(),
        'currentIndex': currentIndex,
        'shuffleOrder': ?shuffleOrder,
      });
      await tmp.writeAsString(payload, flush: true);
      if (await _queueFile.exists()) await _queueFile.delete();
      await tmp.rename(_queueFile.path);
    } finally {
      // 任何失败路径都清掉临时文件，不留残留（成功路径 tmp 已被 rename 走）。
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }

  /// 从文件读队列 + SP 读状态，合并返回快照。
  /// 队列缺失 / 空 / JSON 损坏时返回 null（视为无状态）。
  Future<PlaybackSnapshot?> load() async {
    if (!await _queueFile.exists()) return null;
    _DecodedQueue decoded;
    try {
      // 文件读取 + JSON 解码 + Song 重建一律放后台 isolate：大队列（几万首）
      // 的解析不占主 isolate 事件循环，避免启动/恢复时卡顿；只把结果传回来。
      // 先把路径取到局部变量再进闭包，避免闭包捕获 `this`（含不可 send 字段）。
      final path = _queueFile.path;
      decoded = await Isolate.run(() => _decodeQueueFile(path));
    } catch (_) {
      // isolate 层失败（spawn/传输）：保留文件，本次视为无状态不恢复，
      // 避免把一封正常的队列文件误当坏数据删掉。
      return null;
    }
    switch (decoded.status) {
      case _QueueFileStatus.ok:
        if (decoded.queue.isNotEmpty) break;
        // 空队列：删除文件，视为无状态。
        try {
          await _queueFile.delete();
        } catch (_) {}
        return null;
      case _QueueFileStatus.corrupt:
        // 损坏文件：删除，避免每次启动都重复解析失败。
        try {
          await _queueFile.delete();
        } catch (_) {}
        return null;
      case _QueueFileStatus.unknownVersion:
        // 未来版本：不删文件，本版本不恢复。
        return null;
    }
    final state = loadState();
    return PlaybackSnapshot(
      queue: decoded.queue,
      currentIndex: decoded.currentIndex,
      positionMs: state.$1,
      playing: state.$2,
      shuffleMode: state.$3,
      loopModeIndex: state.$4,
      shuffleOrder: decoded.shuffleOrder,
    );
  }

  /// 状态组：读不到 / 损坏时回退「未播放、0 进度、顺序列表循环」。
  (int, bool, bool, int) loadState() {
    final raw = _prefs.getString(_kStateKey);
    if (raw == null || raw.isEmpty) return (0, false, false, 0);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return (0, false, false, 0);
      return (
        (decoded['positionMs'] as num?)?.toInt() ?? 0,
        decoded['playing'] as bool? ?? false,
        decoded['shuffleMode'] as bool? ?? false,
        (decoded['loopModeIndex'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (0, false, false, 0);
    }
  }

  /// 只写状态组（高频、小）。
  Future<void> saveState({
    required int positionMs,
    required bool playing,
    bool shuffleMode = false,
    int loopModeIndex = 0,
  }) async {
    await _prefs.setString(
      _kStateKey,
      jsonEncode({
        'positionMs': positionMs,
        'playing': playing,
        'shuffleMode': shuffleMode,
        'loopModeIndex': loopModeIndex,
      }),
    );
  }

  /// 一次性写两组（等价于旧版整份快照），供 dispose 兜底与测试使用。
  Future<void> save(PlaybackSnapshot snapshot) async {
    await saveQueue(
      snapshot.queue,
      snapshot.currentIndex,
      shuffleOrder: snapshot.shuffleOrder,
    );
    await saveState(
      positionMs: snapshot.positionMs,
      playing: snapshot.playing,
      shuffleMode: snapshot.shuffleMode,
      loopModeIndex: snapshot.loopModeIndex,
    );
  }

  Future<void> clear() async {
    if (await _queueFile.exists()) await _queueFile.delete();
    await _prefs.remove(_kStateKey);
  }
}
