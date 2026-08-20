import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/audio_cache/audio_cache.dart';
import '../core/audio_cache/proxy_server.dart';
import '../core/audio_service/media_session_manager.dart';
import '../core/logging/app_log.dart';
import '../core/netease/netease_client.dart';
import '../core/platform_utils.dart';
import '../core/wifi_lock.dart';
import '../core/playback_stats/database_helper.dart';
import '../core/player/playback_storage.dart';
import '../core/player/song_url.dart';
import '../models/song.dart';
import 'netease_provider.dart';
import 'settings_provider.dart';
import 'liked_songs_provider.dart';

/// 播放循环模式：只区分「列表循环 / 单曲循环」，不提供「放完即停」。
///
/// 与 [PlayerProvider.shuffleMode] 正交的循环模式。
///
/// 枚举顺序保持稳定（list=0, single=1, off=2）：持久化的 `loopModeIndex`
/// 依赖此顺序，历史数据 0=list / 1=single 语义不变。
enum LoopMode {
  /// 列表循环：播完自动下一首，到边界回绕，永不停止。
  list,

  /// 单曲循环：当前歌播完原地重播。
  single,

  /// 不循环：队列播完即停在末首（Media3 REPEAT_MODE_OFF 语义；
  /// 手动下一首在队尾不可用、上一首在队首不可用）。
  off,
}

/// 全局播放状态管理。
///
/// 最小队列模型：`queue: List<Song>` + `currentIndex`。单曲播放 =
/// `queue=[song]`，未来歌单/多选 = `playAt(list, i)`，无需改结构。
///
/// 播放地址解析（单档语义 + 本地缓存挂点）：
/// 1. `SongUrlResolver.checkLocalCache` 查本地缓存（MVP 恒 miss）；
/// 2. miss 后调 `api.songUrl`（standard 单档，url 为 null = 无版权，
///    freeTrialInfo 非空 = 试听片段）。
class PlayerProvider extends ChangeNotifier {
  /// Android/iOS 固定播放音量（Windows 走设置，见 [SettingsProvider.windowsVolumeCap]）。
  static const _kMobileVolume = 0.6;

  PlayerProvider({
    required this.netease,
    required this.settings,
    required this.liked,
    this.storage,
    PlaybackSnapshot? snapshot,
    this.networkRetryAttempts = 3,
    this.networkRetryBaseDelay = const Duration(seconds: 2),
    // 测试可注入 fake 播放器驱动/断言播放态（见 network_retry_test）。
    AudioPlayer Function()? playerFactory,
  }) : _player = (playerFactory ?? AudioPlayer.new)(),
       _initialSnapshot = snapshot;

  final NeteaseProvider netease;
  final SettingsProvider settings;

  /// 网络瞬时故障（断网/DNS/超时/TLS）时的原地退避重试次数。
  ///
  /// 网络故障 ≠ 歌曲不可播：不触发跳过链、不计入连续失败，退避重试等网络恢复。
  /// 测试环境网络被屏蔽会抛 SocketException，故测试构造传 0 关闭重试，
  /// 维持"网络失败即走跳过链"的既有行为。
  final int networkRetryAttempts;

  /// 重试退避基数：第 n 次重试等待 `baseDelay * n`。
  final Duration networkRetryBaseDelay;

  /// 「我喜欢的音乐」引用：收藏/取消走后端同步通知栏图标。
  final LikedSongsProvider liked;

  /// 播放器状态持久化层；为 null 时不持久化（测试/仅内存场景）。
  final PlayerPlaybackStorage? storage;

  /// 启动时注入的已保存快照，由 [init] 恢复。
  final PlaybackSnapshot? _initialSnapshot;

  /// 首选音质档：读设置（默认 standard；后续可在播放设置页切换）。
  String get qualityLevel => settings.qualityLevel;

  /// 音质档位由低到高（缓存兜底时取最高档），对齐
  /// [SettingsProvider.qualityOptions]。
  List<String> get _qualityRank =>
      SettingsProvider.qualityOptions.map((o) => o.$1).toList();

  /// 降级兜底档：standard 是最宽松的档位，能拿到完整版的概率最大。
  ///
  /// 降级策略（控制每首歌最多 2 次请求的风控噪音）：
  /// 首选档先试 → 只在前档返回试听/失败时才补发 standard → 仍无完整版则播试听
  /// 并提示（freeTrialInfo 非空即试听），两档都无 url 才提示"需会员/付费"。
  static const fallbackLevel = 'standard';

  /// 进程内解析缓存：(音源, songId) → 上次出完整版的档位。
  ///
  /// 只缓存"档位结论"不缓存 URL（签名地址会过期）；同一首歌重复播只发 1 次
  /// 请求。登出/切换账号时可用 [clearLevelCache] 失效。键带音源命名空间，
  /// 避免跨源同 id 歌曲串档位结论。
  final Map<(String, int), String> _fullLevelCache = {};

  /// 底层播放器。默认真实 just_audio 实例；测试经 [PlayerProvider.playerFactory]
  /// 注入 fake，以便驱动/断言播放态与暂停行为。
  final AudioPlayer _player;

  List<Song> _queue = const [];
  int? _currentIndex;

  /// 是否随机播放（乱序推进）。
  bool _shuffleMode = false;

  /// 循环模式：列表循环 / 单曲循环。
  LoopMode _loopMode = LoopMode.list;

  /// 随机模式下的播放顺序表：`_queue` 下标的置换（Fisher–Yates），
  /// 播放恒按此表顺序推进（同一序列反复轮循）。关闭随机时为空表。
  ///
  /// 不变量：`_currentIndex == _shuffleOrder[_shuffleCursor]`（随机开启时）。
  List<int> _shuffleOrder = const [];

  /// 在 [_shuffleOrder] 中的当前位置。
  int _shuffleCursor = 0;

  /// 洗牌随机源。
  final math.Random _shuffleRandom = math.Random();

  /// [displayQueue] 的 memo 缓存：仅当 `_queue`/`_shuffleOrder`/`_shuffleMode`
  /// 三样都未变时直接复用，避免歌单抽屉每次重建都整表重新 map（O(n)）。
  ///
  /// 用同一性（`identical`）做失效标记：这三样每次变更都会替换成新对象，
  /// 因此无需额外的脏标记位。
  List<Song>? _displayViewCache;
  Object? _displayViewQueue;
  Object? _displayViewOrder;
  bool _displayViewMode = false;

  bool _buffering = false;
  Object? _error;
  bool _isTrial = false;

  /// 流式播放中断自动恢复：连续失败计数，播放成功启动时清零（见 _setUrl）。
  int _streamRecoverStreak = 0;

  /// 内容重载信号：每次歌曲真正启动播放时自增。
  ///
  /// UI（封面/歌词）在加载失败（如断网）后监听此值：网络恢复、自愈成功
  /// 续播当前曲时值变化，触发重新加载此前失败的封面/歌词。
  int _contentTick = 0;

  /// 网络瞬时故障（断网/DNS/超时/TLS）退避重试后的长周期兜底重试定时器。
  ///
  /// 短退避重试在 `_loadCurrentInternal` 内同步完成；全部耗尽仍失败时，
  /// 用此定时器每隔 [networkRetryBaseDelay] 再自动发起一次 `_loadCurrent`，
  /// 让后台网络恢复后能自愈续播，而不是停在错误态等用户手动操作。
  /// 用户切歌/主动操作时由 `_loadCurrent` 入口统一取消。
  Timer? _networkRetryTimer;

  /// 网络自愈重试的已连续次数：决定下一次重试间隔（递增后封顶），
  /// 成功或用户切歌后归零。
  int _networkSelfHealStreak = 0;

  /// 当前连续播放会话的起始时间戳（毫秒）；暂停/停止时清 null。
  int? _lastPlayStartTime;

  /// 当前歌曲已累积的听歌时长（毫秒），不含当前会话。
  int _accumulatedListenMs = 0;

  /// UI 展示用的播放态（防抖后，仅随通知同步变化）。
  ///
  /// 与裸 `_player.playing` 解耦：Windows 上 play() 后 native 会瞬时广播
  /// playing=false（flicker），若图标直接读裸值，会被 position/buffering
  /// 触发的一次重建读到 false 而闪一下。此字段只在这些 false 经 300ms 复核
  /// 确认后（或真实暂停/终止）才置 false，保证任何重建路径下图标都稳定。
  /// 内部逻辑（toggle/持久化/恢复）一律继续用 `_player.playing` 真实值。
  bool _uiPlaying = false;

  /// 连续无可用播放地址的次数（用于自动跳过时防止无限循环）。
  int _consecutiveFailures = 0;

  /// 自动跳过的歌曲名列表，按跳过顺序添加。
  /// - 从用户点击的歌开始，连续没版权/失败的都会进这个列表
  /// - 成功播放、主动切歌、清空队列时重置
  List<String> _skippedSongs = const [];

  /// 自动跳过停止原因，仅在"连续 n 首都失败后停止"时非空：
  /// - 'noMore'：无下一首（队尾）
  /// - 'overLimit'：超过最大跳过次数（连续 4 首失败）
  String? _skipStopReason;

  /// 本次跳过链的失败类型，区分两类失败以便 UI 给出准确文案：
  /// - 'noPlayable'：无版权/需会员（接口正常但无可用 url，或全部档 parse 为 null）
  /// - 'source'：源加载/网络失败（拿到了 url 但 setUrl/播放报错，如 CDN/代理/网络）
  String? _skipKind;

  /// 当前曲目实际播放信息（来自 SongUrlResult，_setUrl 时写入）。
  /// 与 [qualityLevel]（用户首选档）不同，这里反映的是 CDN 实际返回的档位。
  String? _currentLevel;
  int _currentBr = 0;
  String? _currentType;

  bool _initialized = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ── 持久化状态 ──
  /// 防抖 Timer：队列/索引变化后延迟 300ms 落盘，合并连续操作。
  Timer? _saveDebounce;

  /// 队列组是否变化过：只在队列/索引变更方法里置 true。
  /// 位置/播放状态变化不置，避免每 5s 的进度写入重写整份大队列 JSON。
  bool _queueDirty = false;

  /// 正在恢复上次会话：期间禁止任何落盘 & 禁止 positionStream 覆盖保存的进度。
  bool _restoring = false;

  /// 用户暂停意图：用户主动点击暂停/播放按钮、或明确指定了暂停状态（例
  /// 如恢复时 playing=false）时标记。`_startPlayback` 的 retry 循环每次迭
  /// 代前检查此标志，避免「用户手动 pause → retry 把它当作 native bug 又
  /// play 回来」这种状态竞争。下一次用户主动 play/切歌/重选时清零。
  bool _userPaused = false;

  /// 当前 _loadCurrent 请求的令牌：每次 _loadCurrent 开头自增并存为
  /// `_currentLoadToken`，关键 await 点之后检查 `token == _currentLoadToken`，
  /// 不等则说明用户已切歌，本次加载作废，立即中断。
  ///
  /// 解决 just_audio_windows 在快速切歌时并发 setUrl 导致 native
  /// MediaPlayer 状态混乱崩溃（"Loading interrupted" + 非 platform thread
  /// 发送 platform channel 消息）。
  int _currentLoadToken = 0;

  /// 加载串行化守卫：true 时 `_loadCurrent` 正在执行中，新的请求不再
  /// 并发启动。与 token 机制配合：token 用于同一 _loadCurrent 内部的
  /// await 后作废检查；`_loadInProgress` 用于防止多个 `_loadCurrent`
  /// 并发执行。
  bool _loadInProgress = false;

  /// 被串行化 SKIP 掉的那首歌的 (音源, songId)：用于补偿时验证当前队列的目标
  /// 歌曲确实就是被 SKIP 的那首。
  ///
  /// **为什么用 (音源, songId) 而不是 currentIndex**：
  /// `playAt(newQueue, i)` 会把 `_currentIndex` 更新为 i，然后调
  /// `_loadCurrent`。如果前一首正在加载中，本次被 SKIP，记下来
  /// `pendingIndex=i`。前一首 finally 时如果 `pendingIndex==_currentIndex`
  /// 就补偿——但如果 newQueue[i] 就是前一首刚加载完的歌曲（换队列时
  /// index 相同对应不同歌曲），或者如果在 playAt 时用户又切回了同一首
  /// 歌，则「index相等」会误判成"需要补偿"，补偿加载的是同一首，
  /// 与下一首 playAt 再次竞争 → 链式补偿疯狂跳歌。
  ///
  /// (音源, songId) 比较更精确：只有「当前 currentSong 的 (source, id) ==
  /// pending」才意味着被 SKIP 的请求确实还没被满足，此时才补偿。带音源是
  /// 避免跨源同 id 的两首歌被误判为同一首（与队列去重口径一致）。
  (String, int)? _pendingSongId;

  /// 当前曲目最近一次播放进度（毫秒），由 positionStream 更新。
  int _currentProgressMs = 0;

  /// 上次落盘进度的时间戳，节流避免高频写 SP。
  int _lastProgressSaveAt = 0;

  /// 进度落盘最小间隔。
  static const Duration _progressSaveInterval = Duration(seconds: 5);

  /// 媒体会话位置更新间隔（1 秒）。
  static const int _mediaSessionUpdateIntervalMs = 1000;

  /// 上次媒体会话位置更新时间戳。
  int _lastMediaSessionUpdateAt = 0;

  /// 当前应施加到播放器的音量（默认按平台设定，见 init）。
  /// just_audio_windows 换源后可能把 volume 重置回 1.0，故 _setUrl 中会
  /// 依据此值重新施加，避免音量被悄悄改大（问题 1 的排查项）。
  double _appliedVolume = 1.0;

  /// Windows native 中间态防抖：无用户暂停意图时收到 playing=false，先
  /// 延迟复核再通知 UI，避免 just_audio_windows 在 play() 请求后先广播
  /// playing=false 再恢复 true（三连事件）导致播放按钮闪烁。
  Timer? _pendingFalseStateTimer;

  List<Song> get queue => _queue;
  int? get currentIndex => _currentIndex;

  /// 随机播放是否开启。
  bool get shuffleMode => _shuffleMode;

  /// 当前循环模式（列表 / 单曲）。
  LoopMode get loopMode => _loopMode;

  /// 播放器当前展示的队列视图：随机开启时按洗牌序，否则原序。
  ///
  /// 仅供 UI 展示切换「原始/随机列表」用；播放推进始终按 [shuffleMode]
  /// 决定，不受此处视图影响。
  List<Song> get displayQueue {
    if (_displayViewMode == _shuffleMode &&
        identical(_displayViewQueue, _queue) &&
        identical(_displayViewOrder, _shuffleOrder)) {
      return _displayViewCache ?? _queue;
    }
    final view = _shuffleMode
        ? List<Song>.unmodifiable(_shuffleOrder.map((i) => _queue[i]))
        : _queue;
    _displayViewCache = view;
    _displayViewQueue = _queue;
    _displayViewOrder = _shuffleOrder;
    _displayViewMode = _shuffleMode;
    return view;
  }

  /// 当前歌在 [displayQueue] 中的位置。
  int get displayIndex => _shuffleMode ? _shuffleCursor : (_currentIndex ?? 0);

  /// [displayQueue] 中第 [pos] 位对应的原始队列下标（jumpTo/removeAt 使用）。
  int originalIndexAtDisplay(int pos) {
    if (pos < 0 || pos >= _queue.length) return pos;
    return _shuffleMode ? _shuffleOrder[pos] : pos;
  }

  /// 切换随机模式：开启时以当前歌为锚重建洗牌顺序；关闭时清空。
  void toggleShuffle() {
    if (_queue.isEmpty) return;
    _shuffleMode = !_shuffleMode;
    if (_shuffleMode) {
      _rebuildShuffleOrder(anchorIndex: _currentIndex ?? 0);
    } else {
      _shuffleOrder = const [];
      _shuffleCursor = 0;
    }
    _queueDirty = true;
    _scheduleSave();
    notifyListeners();
  }

  /// 在「列表循环 ⇄ 单曲循环 ⇄ 不循环」间轮转（list → single → off → list）。
  ///
  /// 与 Media3 的 off→all→one 同构，仅起始停在 list 以保持旧默认行为。
  void cycleLoopMode() {
    _loopMode = switch (_loopMode) {
      LoopMode.list => LoopMode.single,
      LoopMode.single => LoopMode.off,
      LoopMode.off => LoopMode.list,
    };
    _queueDirty = true;
    _scheduleSave();
    notifyListeners();
  }

  /// 当前播放歌曲；未播放时为 null（MiniPlayer 据此隐藏）。
  Song? get currentSong {
    final i = _currentIndex;
    if (i == null) return null;
    return _queue[i];
  }

  bool get buffering => _buffering;
  Object? get error => _error;

  /// 是否有待 UI 提示的跳过记录。
  bool get hasSkipNotice => _skippedSongs.isNotEmpty;

  /// 被连续跳过的歌曲数量。
  int get skipCount => _skippedSongs.length;

  /// 连续跳过的起始歌曲名（即触发跳过链的第一首），
  /// 列表为空时返回 null。用于提示文案：「{origin}」等 {n} 首...
  String? get skipOrigin => _skippedSongs.isEmpty ? null : _skippedSongs.first;

  /// 连续跳过停止原因（仅在"跳过 n 首后都失败、停止"时非空）：
  /// - 'noMore'：队尾无下一首
  /// - 'overLimit'：超过最大自动跳过次数（4 首）
  String? get skipStopReason => _skipStopReason;

  /// 本次跳过链的失败类型：
  /// - 'noPlayable'：无版权/需会员（无可用 url）
  /// - 'source'：源加载/网络失败（拿到 url 但播放失败）
  String? get skipKind => _skipKind;

  /// 消费跳过提示：被跳过列表、停止原因和失败类型清零，避免重复提示。
  void consumeSkipNotice() {
    _skippedSongs = const [];
    _skipStopReason = null;
    _skipKind = null;
  }

  /// 当前曲目是否为试听片段（freeTrialInfo 非空）。
  bool get isTrial => _isTrial;

  /// 待提示的试听歌曲名：仅在本次 _setUrl 成功且 result.isTrial=true 时非空。
  /// UI 消费提示后应调用 [consumeTrialNotice] 清零。
  ///
  /// 与 [isTrial] 的区别：[isTrial] 是「当前播放状态」（试听期间一直为 true），
  /// 而此处是「一次性提示需求」（每首试听只在首次加载成功时提示一次）。
  String? get pendingTrialSongName => _pendingTrialSongName;
  String? _pendingTrialSongName;

  /// 消费试听提示（避免重复弹出）。
  void consumeTrialNotice() => _pendingTrialSongName = null;

  /// 当前曲目实际播放音质档位（CDN 返回，可能与首选档不同）。
  String? get currentLevel => _currentLevel;

  /// 当前曲目实际码率（bps，0 = 未知）。
  int get currentBr => _currentBr;

  /// 当前曲目实际编码格式（如 'mp3' / 'flac'）。
  String? get currentType => _currentType;

  bool get playing => _uiPlaying;

  /// 内容重载信号计数（见 [_contentTick]）：播放真正启动一次 +1。
  /// UI 用它做封面/歌词的失败重试触发。
  int get contentTick => _contentTick;

  // 边界语义：
  // 列表/单曲循环下恒可切（回绕）；「不循环」下队尾无下一首、队首无上一首。
  bool get hasNext {
    if (_queue.isEmpty) return false;
    if (_loopMode != LoopMode.off) return true;
    if (_shuffleMode) return _shuffleCursor < _shuffleOrder.length - 1;
    return (_currentIndex ?? 0) < _queue.length - 1;
  }

  bool get hasPrevious {
    if (_queue.isEmpty) return false;
    if (_loopMode != LoopMode.off) return true;
    if (_shuffleMode) return _shuffleCursor > 0;
    return (_currentIndex ?? -1) > 0;
  }

  /// 下一首歌曲（不改变播放状态；与 [hasNext]/[next] 同语义，供迷你播放器
  /// 滑动时预览目标歌曲封面/信息）。
  Song? get nextSong {
    final n = _queue.length;
    if (n == 0) return null;
    if (n == 1) return _loopMode == LoopMode.off ? null : _queue[0];
    if (_shuffleMode) {
      if (_loopMode == LoopMode.off &&
          _shuffleCursor >= _shuffleOrder.length - 1) {
        return null;
      }
      final c = (_shuffleCursor + 1) % _shuffleOrder.length;
      return _queue[_shuffleOrder[c]];
    }
    final i = _currentIndex ?? -1;
    final next = i + 1;
    if (_loopMode == LoopMode.off && next >= n) return null;
    return _queue[next % n];
  }

  /// 上一首歌曲（不改变播放状态；与 [hasPrevious]/[previous] 同语义）。
  Song? get previousSong {
    final n = _queue.length;
    if (n == 0) return null;
    if (n == 1) return _loopMode == LoopMode.off ? null : _queue[0];
    if (_shuffleMode) {
      if (_loopMode == LoopMode.off && _shuffleCursor <= 0) return null;
      final c =
          (_shuffleCursor - 1 + _shuffleOrder.length) % _shuffleOrder.length;
      return _queue[_shuffleOrder[c]];
    }
    final i = _currentIndex ?? 0;
    if (_loopMode == LoopMode.off && i <= 0) return null;
    return _queue[(i - 1 + n) % n];
  }

  /// 位置/时长走流（MiniPlayer 用 StreamBuilder 订阅），避免高频 notify 全树重建。
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  void init() {
    if (_initialized) return;
    _initialized = true;
    // 设置合理的默认音量。just_audio 默认 volume=1.0（100%）。
    //
    // Windows：音量来自 SettingsProvider.windowsVolume（0~windowsVolumeCap，
    // 界面 0~100% 线性映射，默认 windowsVolumePercent%），设置页滑块可调并
    // 持久化，外放与耳机都有余量。
    // Android/iOS：_kMobileVolume（系统级音量由 audio_session 接管，无类似问题）。
    _appliedVolume = PlatformUtils.isWindows
        ? settings.windowsVolume
        : _kMobileVolume;
    unawaited(_player.setVolume(_appliedVolume));
    // 仅移动端配置音频焦点（audio_session 仅支持 Android/iOS，其余平台会抛
    // MissingPluginException，故限制平台调用）。
    if (PlatformUtils.isMobile) {
      unawaited(_configureSession());
      unawaited(_initMediaSession());
    }
    // 收藏变化 → 同步通知栏收藏按钮图标。统一收口到这里的订阅，
    // 播放页 / 通知栏 / 喜欢列表页任何入口 toggle 后都会触发。
    liked.addListener(_onLikedChanged);
    // 播放/暂停状态变化 → 刷新 MiniPlayer 按钮（低频，无位置流风暴），
    // 同时落盘快照（playing 状态是快照的一部分）。
    _subs.add(_player.playerStateStream.listen(_onPlayerState));
    // 播放中断（网络切换掐断回源流 / 连接被重置）：自动断点续播，不中断体验。
    _subs.add(_player.errorStream.listen(_onPlayerError));
    // 进度：更新当前进度，按间隔节流落盘。
    _subs.add(_player.positionStream.listen(_onPosition));
    // 一首播完自动切下一首；无下一首则停止。
    _subs.add(
      _player.processingStateStream.listen((state) {
        if (state == ProcessingState.completed) {
          unawaited(_onCompleted());
        }
      }),
    );

    // 恢复上次会话（队列 + 当前曲 + 续播位置 + 播放状态）。
    final snap = _initialSnapshot;
    if (snap != null && snap.queue.isNotEmpty) {
      // 进度缓存与初始 UI 播放态在 [_restoreFromSnapshot] 内统一设置，
      // 保证同步注入路径与异步 [storage] 恢复路径行为一致。
      unawaited(_restoreFromSnapshot(snap));
    } else if (storage != null) {
      // 无注入快照 → 从持久化层异步恢复。启动不再在 runApp 前同步
      // `await load()`：队列读盘 + 解析全部落后台 isolate（Isolate.run），
      // 首帧与后续帧不受阻；快照就绪后由 [_restoreFromStorage] 应用。
      unawaited(_restoreFromStorage());
    }
  }

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {
      // 平台不支持音频会话时静默忽略
    }
  }

  /// 初始化媒体会话（系统通知栏播放控制）。
  Future<void> _initMediaSession() async {
    try {
      await MediaSessionManager.instance.init(
        onPlay: () => play(),
        onPause: () => pause(),
        onNext: () => next(),
        onPrevious: () => previous(),
        onSeek: (pos) => seek(pos),
        // 通知栏收藏按钮：切换当前歌曲收藏态（图标同步统一走 _onLikedChanged）。
        onToggleFavorite: () async {
          final song = currentSong;
          if (song == null) return;
          await liked.toggle(song);
        },
        onStop: () {
          // 系统停止：清空队列并停止播放
          _userPaused = true;
          _player.stop().catchError((_) {});
        },
      );
    } catch (e) {
      AppLog.warn('媒体会话初始化失败: $e', tag: 'player');
    }
  }

  /// 收藏状态变化回调：同步通知栏收藏按钮图标。
  ///
  /// 只关心当前播放曲目的收藏态；无播放曲目时跳过（通知栏本身也不该
  /// 显示收藏态）。各入口（播放页 / 通知栏 / 喜欢列表页）toggle 后都会
  /// notifyListeners，此回调统一收口同步，避免漏改。
  void _onLikedChanged() {
    final song = currentSong;
    if (song == null) return;
    MediaSessionManager.instance.updateFavorite(liked: liked.isLiked(song));
  }

  // ── 持久化 ──

  /// playerStateStream 回调。
  ///
  /// just_audio_windows 在 play() 请求后可能先广播 playing=false（native
  /// 中间态，随后恢复 true），表现为播放按钮在播放/暂停间闪烁
  /// （playing=true→false→true 三连事件）。这里对「无用户暂停意图的
  /// playing=false」延迟 300ms 复核：持续为 false 才通知 UI；期间恢复
  /// true 则忽略。用户显式 pause（_userPaused=true）的 playing=false 是
  /// 真实状态，立即通知，不受影响。
  void _onPlayerState(PlayerState event) {
    if (event.playing) {
      // 明确进入播放：立即反映，并取消任何挂起的「暂停」复核。
      _pendingFalseStateTimer?.cancel();
      _pendingFalseStateTimer = null;
      _setUiPlaying(true);
      // _setUrl 在 _startPlayback 成功时会设置 _lastPlayStartTime；但如果
      // 初始恢复时用户暂停（autoPlayOnOpen=false），_lastPlayStartTime 为空。
      // 用户之后手动播放时，需在此补设，否则歌曲不会被统计。
      if (_lastPlayStartTime == null && currentSong != null && !_isTrial) {
        _lastPlayStartTime = DateTime.now().millisecondsSinceEpoch;
      }
      return;
    }
    // 仅当处于非 idle 态时才可能出现 play() 抖动（真正的 flicker 发生在
    // loading/buffering/ready 期间）。idle 是冷启动/无媒体会话的静止态，
    // 此处的 playing=false 是真实终止，无需延迟复核，直接通知，也避免在
    // 未加载媒体的场景残留 300ms 定时器。
    if (!_userPaused && event.processingState != ProcessingState.idle) {
      _pendingFalseStateTimer?.cancel();
      _pendingFalseStateTimer = Timer(const Duration(milliseconds: 300), () {
        _pendingFalseStateTimer = null;
        if (!_player.playing && !_userPaused) {
          _setUiPlaying(false);
          _accumulateListenMs();
        }
      });
      return;
    }
    _pendingFalseStateTimer?.cancel();
    _pendingFalseStateTimer = null;
    _setUiPlaying(false);
    _accumulateListenMs();
  }

  /// 播放中断自动恢复（errorStream 回调）。
  ///
  /// 触发场景：播放中底层音频流被网络切换/回源连接被掐断等瞬时故障中断
  /// （just_audio 报 `PlayerException`，Android 上 code 映射 Media3
  /// `PlaybackException.errorCode`，网络类为 2000xxx）。
  ///
  /// 只处理「播放中」的中断：
  /// - 加载期（_loadCurrent 内部）的错误已被 setUrl 的 try/catch + 跳过链处理，
  ///   不应在此重复介入（否则会与跳过/降级逻辑竞争）。
  /// - 仅当是可恢复的网络/IO 错误才续播；格式/解码类错误不可恢复，仍走
  ///   原有的错误展示/跳过路径。
  void _onPlayerError(Object e) {
    // 加载中/用户暂停/恢复会话期间不介入：这些路径有自己的错误处理。
    if (_loadInProgress || _userPaused || _restoring) return;
    if (e is! PlayerException) return;
    final song = currentSong;
    if (song == null) return;
    if (!_isRecoverableStreamError(e)) return;
    // 已在正常播放（playing=true）的迟到错误事件：说明错误已被跳过链等
    // 路径处理掉，当前正在播下一首/重试成功的歌，不应打断。真正的播放中断
    // 会让 ExoPlayer 进入 idle，playing 必为 false。
    if (_player.playing) return;
    // 跳过链已停止（连续失败/无下一首，_skipStopReason 非空）：迟到错误
    // 不应再触发恢复，避免把已停止的播放重新拉起。
    if (_skipStopReason != null) return;
    // 网络缓冲期（loading/buffering）的失败已由 _loadCurrent 网络重试兜底，
    // 不重复恢复。
    if (_player.processingState == ProcessingState.buffering ||
        _player.processingState == ProcessingState.loading) {
      return;
    }
    // 记录断点：错误发生时 player.position 可能已回落到 0（idle），用
    // _currentProgressMs（positionStream 持续维护的真实进度）作为续播位置。
    final resumeMs = _currentProgressMs;
    // 连续恢复失败退避：避免弱网下 errorStream 风暴反复触发恢复，最多
    // [_streamRecoverMaxAttempts] 次。计数只在播放成功启动时重置（见
    // _setUrl），窗口内不重置——「每次中断都尝试恢复」即连续失败，不应因
    // 时间间隔而获得新的尝试额度。
    _streamRecoverStreak++;
    if (_streamRecoverStreak > _streamRecoverMaxAttempts) {
      AppLog.warn('播放中断自动恢复次数过多，暂停自动续播：${song.name}', tag: 'player', error: e);
      return;
    }
    AppLog.warn(
      '播放中断，从 ${resumeMs}ms 自动续播：${song.name}',
      tag: 'player',
      error: e,
    );
    _buffering = true;
    notifyListeners();
    unawaited(_recoverFromInterruption(resumeMs));
  }

  /// 可恢复的流式播放错误：网络/IO 类（Android Media3 errorCode 2000xxx）。
  ///
  /// 网络连接失败/超时、HTTP 状态错误属于瞬时故障，URL 失效可刷新重试；
  /// 解析/解码/格式类错误不可恢复，重试也会复现，走原错误路径。
  static bool _isRecoverableStreamError(PlayerException e) {
    return isRecoverableStreamErrorCode(e.code);
  }

  /// 断点续播：保存进度 → 重新走加载链（重取 URL）→ seek 回中断位置。
  ///
  /// 复用 [_restoring] 语义：_loadCurrentInternal 在 _restoring=true 时不清零
  /// _currentProgressMs，_setUrl 也会在 setUrl 后 seek 到该进度，实现无缝续播。
  Future<void> _recoverFromInterruption(int resumeMs) async {
    if (resumeMs > 0) {
      _currentProgressMs = resumeMs;
    }
    _restoring = true;
    try {
      await _loadCurrent();
    } finally {
      _restoring = false;
    }
  }

  /// 连续失败时最多自动恢复次数（之后停止自动续播，等待成功播放或用户操作）。
  static const int _streamRecoverMaxAttempts = 3;

  /// 将当前播放会话的时长累加到 `_accumulatedListenMs`，然后清空会话起点。
  /// 暂停、停止、切歌时调用。
  void _accumulateListenMs() {
    final start = _lastPlayStartTime;
    if (start == null) return;
    _accumulatedListenMs += DateTime.now().millisecondsSinceEpoch - start;
    _lastPlayStartTime = null;
  }

  /// 更新 UI 播放态并仅在实际变化时通知（播放中 buffering 等 processingState
  /// 变化仍由各自路径自行 notify，此方法不吞没非 playing 的 UI 刷新）。
  void _setUiPlaying(bool v) {
    if (_uiPlaying == v) return;
    _uiPlaying = v;
    if (v) {
      // 播放成功恢复：重置网络自愈重试计数，避免弱网场景误用旧间隔。
      _networkSelfHealStreak = 0;
      // 开始播放 → 持 WiFi 锁：息屏时保持网卡活性，降低后台取歌地址
      // 的 DNS 解析失败（errno=7）概率。异步失败不影响播放。
      unawaited(WifiLock.acquire());
    } else {
      // 停止播放 → 释放 WiFi 锁，归还系统网络电源。
      unawaited(WifiLock.release());
    }
    notifyListeners();
    _scheduleSave();
    // 同步媒体会话播放状态
    MediaSessionManager.instance.updatePlaybackState(
      playing: v,
      position: Duration(milliseconds: _currentProgressMs),
    );
  }

  void _onPosition(Duration p) {
    // 恢复期间：保持 init 中设置的 snap.positionMs，避免 setUrl 后 position=0
    // 覆盖保存的进度值。seek 会在 _restoreFromSnapshot 中显式调用，届时
    // positionStream 会发出正确的进度值。
    if (_restoring) return;
    // 加载新歌期间：setUrl 之前旧曲仍在播放，positionStream 会继续推进。
    // 跳过更新避免旧进度污染 _currentProgressMs，防止持久化快照保存
    // 「新歌 + 旧进度」的错误组合（切歌后退出会从旧进度位置续播）。
    if (_buffering) return;
    _currentProgressMs = p.inMilliseconds;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastProgressSaveAt >= _progressSaveInterval.inMilliseconds) {
      _lastProgressSaveAt = now;
      _scheduleSave();
    }
    // 定期同步进度到媒体会话（节流，避免高频更新）
    if (now - _lastMediaSessionUpdateAt >= _mediaSessionUpdateIntervalMs) {
      _lastMediaSessionUpdateAt = now;
      MediaSessionManager.instance.updatePlaybackState(
        playing: _uiPlaying,
        position: p,
      );
    }
  }

  /// 队列/索引/播放状态变化后防抖落盘，合并连续操作。
  void _scheduleSave() {
    if (_restoring) return;
    final storage = this.storage;
    if (storage == null) return;
    _saveDebounce ??= Timer(const Duration(milliseconds: 300), () {
      _saveDebounce = null;
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    final storage = this.storage;
    if (storage == null) return;
    // 恢复期间不落盘：磁盘上仍是上一份完好快照，跳过写入比用中间态覆盖更安全。
    // 此守卫同步覆盖 debounce / guard flush / dispose 三条入口，避免恢复窗口内
    // （_loadCurrent 含最长 15s 网络等待）被退后台/关窗的兜底写盘破坏恢复数据。
    if (_restoring) return;
    final song = currentSong;
    if (_queueDirty) {
      try {
        await storage.saveQueue(
          _queue,
          _currentIndex,
          shuffleOrder: _shuffleMode ? _shuffleOrder : null,
        );
        _queueDirty = false;
      } catch (e) {
        AppLog.error('队列落盘失败', tag: 'player', error: e);
      }
    }
    try {
      await storage.saveState(
        positionMs: song == null ? 0 : _currentProgressMs,
        playing: _player.playing,
        shuffleMode: _shuffleMode,
        loopModeIndex: _loopMode.index,
      );
    } catch (e) {
      AppLog.error('播放状态落盘失败', tag: 'player', error: e);
    }
  }

  /// 恢复上次会话：重建队列/索引，加载当前曲，按保存的进度续播。
  ///
  /// **关键执行顺序**：
  /// 1. 本方法开头把 `_currentProgressMs = snap.positionMs`（进度缓存）就位，
  ///    同步注入路径与异步 [storage] 恢复路径共用本方法，因此这里统一设置
  /// 2. 设置用户暂停意图 → 控制 `_startPlayback` 是否启动播放
  /// 3. `_loadCurrent` → `_setUrl` 中执行：setUrl → **seek 到缓存进度** → `_startPlayback`
  /// 4. 如果恢复时是暂停状态，兜底再 pause 一次
  ///
  /// seek 放在 `_setUrl` 里（setUrl 之后、startPlayback 之前）的理由：
  /// Android 端 ExoPlayer 在 setUrl + play() 后，positionStream 立即从 0
  /// 推进，异步 seek 如果赶上 play() 后的解码竞争会被忽略或延迟，表现为
  /// 「从头播放」。改为 setUrl 完成后立即 seek，与暂停恢复的执行顺序一致。
  Future<void> _restoreFromSnapshot(PlaybackSnapshot snap) async {
    _restoring = true;
    // 进度缓存必须在 _loadCurrent 前就位：_setUrl 会用它对当前曲 seek 到保存的
    // 续播位置，漏设会导致恢复的歌曲从 0 播放。
    _currentProgressMs = snap.positionMs;
    // 恢复会话后是否自动播放由设置「打开时自动播放」决定（纯开关语义，不依存
    // 退出时的播放状态）。初始 UI 播放态即按该值置位，避免首帧图标先显示播放
    // 再翻成暂停。
    _uiPlaying = settings.autoPlayOnOpen;
    AppLog.info(
      '恢复播放快照：队列 ${snap.queue.length} 首，index=${snap.currentIndex}，'
      '进度 ${snap.positionMs}ms',
      tag: 'player',
    );
    // 进入 _loadCurrent 前就设置好用户暂停意图（由「打开时自动播放」开关
    // 决定，纯开关语义，不看退出时的播放状态）：
    // - 关 → _userPaused=true → _startPlayback 第一轮直接 return，不启动
    //   播放，避免「先播再暂停」的竞争 & 状态闪变。
    // - 开 → _userPaused=false → _startPlayback 按常重试。
    _userPaused = !settings.autoPlayOnOpen;
    // 恢复循环/随机模式；随机模式下以恢复的当前歌为锚重建洗牌序列。
    _shuffleMode = snap.shuffleMode;
    _loopMode = LoopMode
        .values[snap.loopModeIndex.clamp(0, LoopMode.values.length - 1)];
    _shuffleOrder = const [];
    _shuffleCursor = 0;
    try {
      _queue = List.unmodifiable(snap.queue);
      _currentIndex = snap.currentIndex != null
          ? snap.currentIndex!.clamp(0, snap.queue.length - 1)
          : 0;
      if (_shuffleMode) {
        final ci = _currentIndex;
        final saved = snap.shuffleOrder;
        if (ci != null && saved != null && _isValidShuffleOrder(saved)) {
          _shuffleOrder = List<int>.unmodifiable(saved);
          _shuffleCursor = saved.indexOf(ci);
        } else {
          _rebuildShuffleOrder(anchorIndex: ci ?? 0);
        }
      }
      _isTrial = false;
      _error = null;
      notifyListeners();
      await _loadCurrent();
      // 如果当前曲因自动跳过（无版权等）发生变化：seek 已在 _setUrl 里按原
      // 曲进度 seek 到新曲，虽有错位但仍属最佳努力行为。此处不做额外 seek。

      // 兜底：开关关闭时确保暂停。`_userPaused=true` 已让
      // `_startPlayback` 第一轮直接 return 不 play；仅在异常场景（自动跳过
      // 链的 next() 已启动播放等）兜底暂停。调用底层 `_player.pause()`
      // 而不是 `this.pause()`，避免重复设置 _userPaused。
      if (!settings.autoPlayOnOpen) {
        try {
          await _player.pause();
        } catch (_) {}
      }
    } finally {
      _restoring = false;
      // 恢复完成：重置节流时间戳，避免恢复瞬间的瞬时进度立刻落盘覆盖正确值。
      _lastProgressSaveAt = DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// 无注入快照时的异步恢复：文件读取 + 解析在后台 isolate 完成，
  /// 就绪后复用 [_restoreFromSnapshot] 的续播逻辑。
  Future<void> _restoreFromStorage() async {
    final storage = this.storage;
    if (storage == null) return;
    PlaybackSnapshot? snap;
    try {
      snap = await storage.load();
    } catch (e) {
      AppLog.error('读取播放快照失败', tag: 'player', error: e);
      return;
    }
    if (snap == null || snap.queue.isEmpty) return;
    // 加载窗口内用户已开始播放/建队列 → 不覆盖现场（用户操作已实时落盘，
    // 磁盘上的队列本就是最新状态，无需回写）。
    if (currentSong != null || _queue.isNotEmpty) return;
    unawaited(_restoreFromSnapshot(snap));
  }

  /// 强制从磁盘恢复播放队列（备份恢复后调用）。
  ///
  /// 与 [_restoreFromStorage] 不同，此方法不检查当前是否有播放中的歌曲，
  /// 直接用磁盘数据覆盖内存状态。
  Future<void> reloadQueue() async {
    final storage = this.storage;
    if (storage == null) return;
    try {
      final snap = await storage.load();
      if (snap == null || snap.queue.isEmpty) {
        // 导入为空队列（覆盖场景）：清空内存态，避免界面残留旧队列。
        // clearQueue 本身幂等（队列已空时直接返回）。
        await clearQueue();
        return;
      }
      await _restoreFromSnapshot(snap);
    } catch (e) {
      AppLog.error('恢复播放队列失败', tag: 'player', error: e);
    }
  }

  Future<void> _onCompleted() async {
    // 防御 just_audio_windows 的误报 completed 事件。
    // 该插件在 setUrl 后访问 BufferingProgress 失败时使用默认值 1（100%），
    // 导致 ProcessingState.completed 被误触发。误报的典型场景：
    //   正在 _loadCurrent → Called load → 立刻触发 completed（此时新歌还在加载）
    //
    // 真正播放完成必须 **同时满足** 以下全部条件（任一不满足即为误报）：
    //   1. 不在加载中（!_buffering）
    //   2. duration > 0（新歌尚未拿到时长时一定是误报）
    //   3. position 接近末尾（距离末尾 < 1s）
    final duration = _player.duration;
    final position = _player.position;
    final durMs = duration?.inMilliseconds ?? 0;
    final posMs = position.inMilliseconds;
    if (_buffering) {
      return;
    }
    if (durMs <= 0) {
      return;
    }
    if (posMs < durMs - 1000) {
      return;
    }
    // 自然播完：记录播放统计
    _recordPlaybackStats();
    // 自然播完：单曲循环 → 原地 seek+play；否则按模式推进。
    // 「不循环」且已到队尾 → next() 返回 null 不推进，停留在末首（
    // REPEAT_MODE_OFF 语义：列表播完即停）。
    if (_loopMode == LoopMode.single) {
      try {
        await _player.seek(Duration.zero);
        await _player.play();
      } catch (_) {}
      return;
    }
    await next();
  }

  // ── 播放入口 ──

  /// 单曲播放：队列重置为仅此一首。
  Future<void> playSong(Song song) => playAt([song], 0);

  /// 播放 [songs] 并进入随机模式。
  ///
  /// [startIndex] 指定播放起点；为 null 时随机挑一首作起点。提前置随机位，
  /// 由 [playAt] 内的 `_syncShuffleOrder` 在铺队列时以该起点为锚重建洗牌表
  /// （不依赖铺队列后的异步回调，避免加载失败跳过链改锚导致随机起点丢失）。
  Future<void> playShuffled(List<Song> songs, {int? startIndex}) async {
    if (songs.isEmpty) return;
    final index = (startIndex ?? _shuffleRandom.nextInt(songs.length)).clamp(
      0,
      songs.length - 1,
    );
    _shuffleMode = true;
    _queueDirty = true;
    _scheduleSave();
    await playAt(songs, index);
  }

  /// 以 [index] 为起点播放 [songs]（整个列表即队列）。
  Future<void> playAt(List<Song> songs, int index) async {
    if (songs.isEmpty) return;
    _queue = List.unmodifiable(songs);
    _currentIndex = index.clamp(0, songs.length - 1);
    _error = null;
    _isTrial = false;
    // 用户主动开启新播放：重置失败计数 + 暂停意图 + 跳过提示列表
    _consecutiveFailures = 0;
    _userPaused = false;
    _lastPlayStartTime = null;
    _accumulatedListenMs = 0;
    _skippedSongs = const [];
    _skipStopReason = null;
    _skipKind = null;
    // 随机模式开启时，从「点选的歌」重建洗牌序列（该歌为新序列起点）。
    _syncShuffleOrder();
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
    await _loadCurrent();
  }

  /// 用户主动下一首：清除跳过提示。
  Future<void> next() async {
    if (_queue.isEmpty) return;
    final target = _resolveNextIndex();
    if (target == null) return;
    // 记录当前歌曲播放统计（切歌前）
    _recordPlaybackStats();
    _skippedSongs = const [];
    _skipStopReason = null;
    _skipKind = null;
    _currentIndex = target;
    _userPaused = false;
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
    await _loadCurrent();
  }

  /// 内部切到下一首：不清除跳过提示（供自动跳过链使用）。
  Future<void> _nextInternal() async {
    if (_queue.isEmpty) return;
    final target = _resolveNextIndex();
    if (target == null) return;
    _currentIndex = target;
    _userPaused = false;
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
    await _loadCurrent();
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    final target = _resolvePrevIndex();
    if (target == null) return;
    // 记录当前歌曲播放统计（切歌前）
    _recordPlaybackStats();
    _currentIndex = target;
    _userPaused = false;
    _skippedSongs = const [];
    _skipStopReason = null;
    _skipKind = null;
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
    await _loadCurrent();
  }

  /// 计算按当前模式推进后的下一首原始下标（随机表或顺序推进；
  /// 返回 null = 不循环且已在边界，不推进、不加载、维持停止）。
  int? _resolveNextIndex() {
    final n = _queue.length;
    if (n == 0) return null;
    if (n == 1) return _loopMode == LoopMode.off ? null : 0;
    if (_shuffleMode) {
      if (_loopMode == LoopMode.off &&
          _shuffleCursor >= _shuffleOrder.length - 1) {
        return null;
      }
      _shuffleCursor = (_shuffleCursor + 1) % _shuffleOrder.length;
      return _shuffleOrder[_shuffleCursor];
    }
    final i = _currentIndex ?? -1;
    final next = i + 1;
    if (_loopMode == LoopMode.off && next >= n) return null;
    return next % n;
  }

  /// 计算上一首原始下标（随机表退回或顺序回退；null = 不循环且已在队首）。
  int? _resolvePrevIndex() {
    final n = _queue.length;
    if (n == 0) return null;
    if (n == 1) return _loopMode == LoopMode.off ? null : 0;
    if (_shuffleMode) {
      if (_loopMode == LoopMode.off && _shuffleCursor <= 0) return null;
      _shuffleCursor =
          (_shuffleCursor - 1 + _shuffleOrder.length) % _shuffleOrder.length;
      return _shuffleOrder[_shuffleCursor];
    }
    final i = _currentIndex ?? 0;
    if (_loopMode == LoopMode.off && i <= 0) return null;
    return (i - 1 + n) % n;
  }

  /// 以 [anchorIndex] 为序列起点重建洗牌顺序（当前歌恒定在游标 0，
  /// 其余 Fisher–Yates）。随机模式循环推进时按同一序列反复轮循。
  void _rebuildShuffleOrder({required int anchorIndex}) {
    final n = _queue.length;
    if (n == 0) {
      _shuffleOrder = const [];
      _shuffleCursor = 0;
      return;
    }
    if (n == 1) {
      _shuffleOrder = const [0];
      _shuffleCursor = 0;
      return;
    }
    final anchor = anchorIndex.clamp(0, n - 1);
    final rest = <int>[
      for (var i = 0; i < n; i++)
        if (i != anchor) i,
    ];
    rest.shuffle(_shuffleRandom);
    _shuffleOrder = List<int>.unmodifiable([anchor, ...rest]);
    _shuffleCursor = 0;
  }

  /// 洗牌序单点移除：[removedIndex] 为旧队列坐标；其余大于它的下标 -1。
  static List<int> _orderRemove(List<int> order, int removedIndex) {
    final out = <int>[];
    for (final i in order) {
      if (i == removedIndex) continue;
      out.add(i > removedIndex ? i - 1 : i);
    }
    return out;
  }

  /// 洗牌序单点插入：[insertedIndex] 为新队列坐标；其余大于等于它的下标 +1。
  /// [at] 为插入位置（缺省 = 末尾追加）。
  static List<int> _orderInsert(List<int> order, int insertedIndex, {int? at}) {
    final shifted = [for (final i in order) i >= insertedIndex ? i + 1 : i];
    final pos = at == null ? shifted.length : at.clamp(0, shifted.length);
    shifted.insert(pos, insertedIndex);
    return shifted;
  }

  /// 校验持久化洗牌序是否可用：必须是对 `0..len-1` 的完整排列。
  bool _isValidShuffleOrder(List<int> order) {
    if (order.length != _queue.length) return false;
    final seen = List<bool>.filled(_queue.length, false);
    for (final v in order) {
      if (v < 0 || v >= _queue.length || seen[v]) return false;
      seen[v] = true;
    }
    return seen.every((e) => e);
  }

  /// 用户主动增删/插队列后按「保留其余相对顺序」维护洗牌序，不做全量重排。
  ///
  /// 与 [_syncShuffleOrder]（整体重建）的区别：随机模式下「添加到下一首 / 追加
  /// 末尾 / 移除」应保留其它歌曲的既有播放顺序，否则刚设好的「下一首」会被
  /// 重建洗掉。随机关闭或洗牌序缺失时回退到 [_syncShuffleOrder] 语义。
  ///
  /// [removedIndex]：被移除项在旧队列的下标（-1 表示无）；
  /// [insertedIndex]：新插入项在新队列的下标（-1 表示无）；
  /// [insertAfterCurrent]：true 时插入到当前歌之后（下一首），否则追加到末尾。
  void _maintainShuffleOrder({
    int removedIndex = -1,
    int insertedIndex = -1,
    bool insertAfterCurrent = false,
  }) {
    if (!_shuffleMode) {
      _shuffleOrder = const [];
      _shuffleCursor = 0;
      return;
    }
    final current = _currentIndex;
    if (current == null) {
      _shuffleOrder = const [];
      _shuffleCursor = 0;
      return;
    }
    if (_shuffleOrder.isEmpty) {
      _rebuildShuffleOrder(anchorIndex: current);
      return;
    }
    var order = _shuffleOrder;
    if (removedIndex >= 0) {
      order = _orderRemove(order, removedIndex);
    }
    if (insertedIndex >= 0) {
      // 插入点：下一首模式锚定当前歌在（移除后）顺序中的位置，再插入其后。
      final anchor = insertAfterCurrent ? order.indexOf(current) : -1;
      order = _orderInsert(
        order,
        insertedIndex,
        at: anchor >= 0 ? anchor + 1 : null,
      );
    }
    final pos = order.indexOf(current);
    if (pos < 0) {
      // 防御：不变量保证当前歌必在洗牌序内；万一被破坏，回退整体重建。
      _rebuildShuffleOrder(anchorIndex: current);
      return;
    }
    _shuffleCursor = pos;
    _shuffleOrder = List<int>.unmodifiable(order);
  }

  /// 队列增删/换源后同步洗牌顺序，保证「随机播放恒按当前洗牌表推进」。
  void _syncShuffleOrder() {
    if (!_shuffleMode) {
      _shuffleOrder = const [];
      _shuffleCursor = 0;
      return;
    }
    final i = _currentIndex;
    if (i == null) {
      _shuffleOrder = const [];
      _shuffleCursor = 0;
      return;
    }
    _rebuildShuffleOrder(anchorIndex: i);
  }

  // ── 队列操作 ──

  /// 跳转到队列中第 [index] 首播放（不替换队列）。
  Future<void> jumpTo(int index) async {
    if (_queue.isEmpty) return;
    if (index < 0 || index >= _queue.length) return;
    if (index == _currentIndex) return;
    _currentIndex = index;
    // 随机模式下同步游标：跳转不影响洗牌序列本身，仅移动当前位置。
    if (_shuffleMode && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(index);
      if (pos >= 0) _shuffleCursor = pos;
    }
    _userPaused = false;
    _skippedSongs = const [];
    _skipStopReason = null;
    _skipKind = null;
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
    await _loadCurrent();
  }

  /// 从队列移除第 [index] 首。
  ///
  /// currentIndex 偏移规则：
  /// - 移除项在当前之前 → currentIndex - 1
  /// - 移除项等于当前 → 若有下一首则保持索引播下一首，否则索引 -1 播上一首；
  ///   队列仅剩此项时清空播放
  /// - 移除项在当前之后 → currentIndex 不变
  Future<void> removeAt(int index) async {
    if (_queue.isEmpty) return;
    if (index < 0 || index >= _queue.length) return;
    final wasCurrent = index == _currentIndex;
    final newList = List<Song>.from(_queue)..removeAt(index);
    if (newList.isEmpty) {
      // 作废一切在途加载/重试（同 clearQueue）：bump token 让在途
      // _loadCurrent/_setUrl/_startPlayback 的 await 后检查立即失效，避免
      // 清空后又被完成中的加载重新 play()（问题 3）。
      _currentLoadToken++;
      _userPaused = true;
      _queue = const [];
      _currentIndex = null;
      _isTrial = false;
      _currentLevel = null;
      _currentBr = 0;
      _currentType = null;
      _error = null;
      _buffering = false;
      _skippedSongs = const [];
      _skipStopReason = null;
      _shuffleOrder = const [];
      _shuffleCursor = 0;
      try {
        await _player.stop();
      } catch (_) {}
      // stop() 在播放中（ExoPlayer 渲染管线未释放）可能不彻底，补一次 pause()
      // 确保 playing=false 语义落地，避免 _persistNow 写入 playing:true。
      try {
        if (_player.playing) await _player.pause();
      } catch (_) {}
      notifyListeners();
      _queueDirty = true;
      _scheduleSave();
      // 同步媒体会话停止状态
      MediaSessionManager.instance.updateStopped();
      // 立即落盘（不依赖 300ms 防抖），确保空队列状态在快速退出时也已写入。
      await _persistNow();
      return;
    }
    _queue = List.unmodifiable(newList);
    if (wasCurrent) {
      // 移除的是当前播放项：保持索引（原 index 现在指向下一首），
      // 越界则回退到最后一首。用户主动移除当前项 → 播放下一首的意图。
      _currentIndex = index >= newList.length ? newList.length - 1 : index;
      _userPaused = false;
      _skippedSongs = const [];
      _skipStopReason = null;
      _maintainShuffleOrder(removedIndex: index);
      notifyListeners();
      _queueDirty = true;
      _scheduleSave();
      await _loadCurrent();
    } else if (_currentIndex != null && index < _currentIndex!) {
      _currentIndex = _currentIndex! - 1;
      _maintainShuffleOrder(removedIndex: index);
      notifyListeners();
      _queueDirty = true;
      _scheduleSave();
    } else {
      _maintainShuffleOrder(removedIndex: index);
      notifyListeners();
      _queueDirty = true;
      _scheduleSave();
    }
  }

  /// 清空队列并停止播放。
  ///
  /// 注意：不清 [_fullLevelCache]（音质档位缓存按 (音源, songId) 索引，与队列无关，
  /// 清队列后用户仍可能重新播放这些歌，保留可避免重复请求）。
  Future<void> clearQueue() async {
    if (_queue.isEmpty) return;
    // 作废一切在途加载/重试：bump token 让 _loadCurrent/_setUrl/_startPlayback
    // 中已执行到的 await 后的检查立即失效，避免清空后又被完成中的加载
    // 重新 play()（问题 3：播放中清空后音频继续播）。
    _currentLoadToken++;
    // 设置用户暂停意图：在途 _startPlayback 重试循环每轮检查 _userPaused，
    // 置位后立即退出，不再把 stop() 的成果播回来。
    _userPaused = true;
    _queue = const [];
    _currentIndex = null;
    _isTrial = false;
    _currentLevel = null;
    _currentBr = 0;
    _currentType = null;
    _error = null;
    _buffering = false;
    _skippedSongs = const [];
    _skipStopReason = null;
    _skipKind = null;
    _shuffleOrder = const [];
    _shuffleCursor = 0;
    try {
      await _player.stop();
    } catch (_) {}
    // stop() 在播放中（ExoPlayer 渲染管线未释放）可能不彻底，补一次 pause()
    // 确保 playing=false 语义落地，避免 _persistNow 写入 playing:true。
    try {
      if (_player.playing) await _player.pause();
    } catch (_) {}
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
    // 立即落盘（不依赖 300ms 防抖）：清空是「快照语义」变化，快速退出时
    // 必须保证空队列+暂停状态已写入，否则重启会恢复出旧队列（问题 3）。
    await _persistNow();
  }

  /// 追加单曲到队列末尾（不影响当前播放）。
  /// 已存在同 (音源, id) 歌曲则先移除再追加到末尾（与 [playNext] 去重策略一致）。
  void addToQueue(Song song) {
    final list = List<Song>.from(_queue);
    final existingIndex = list.indexWhere(
      (s) => s.source == song.source && s.id == song.id,
    );
    if (existingIndex >= 0) {
      list.removeAt(existingIndex);
      // 移除当前之前的项需补偿 currentIndex
      if (_currentIndex != null && existingIndex < _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      }
    }
    list.add(song);
    // 移除的是当前播放项：它被移到末尾，currentIndex 跟随到新位置。
    if (existingIndex == _currentIndex) {
      _currentIndex = list.length - 1;
    }
    _queue = List.unmodifiable(list);
    // 随机模式下新歌追加到洗牌序末尾（最后播放），其余顺序不变。
    _maintainShuffleOrder(
      removedIndex: existingIndex,
      insertedIndex: list.length - 1,
    );
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
  }

  /// 批量追加到队列末尾（不影响当前播放）。
  /// 已存在同 (音源, id) 歌曲先移除再追加到末尾。
  void addAllToQueue(List<Song> songs) {
    if (songs.isEmpty) return;
    final list = List<Song>.from(_queue);
    // 随机模式下增量维护洗牌序（保留其余相对顺序），关闭/缺失时回退重建。
    List<int>? order = _shuffleMode && _shuffleOrder.isNotEmpty
        ? List<int>.from(_shuffleOrder)
        : null;
    var currentMoved = false;
    for (final song in songs) {
      final existingIndex = list.indexWhere(
        (s) => s.source == song.source && s.id == song.id,
      );
      if (existingIndex >= 0) {
        list.removeAt(existingIndex);
        if (_currentIndex != null && existingIndex < _currentIndex!) {
          _currentIndex = _currentIndex! - 1;
        } else if (_currentIndex != null && existingIndex == _currentIndex) {
          currentMoved = true;
        }
        order = order == null ? null : _orderRemove(order, existingIndex);
      }
      list.add(song);
      // 移除的是当前播放项：它被追加到末尾，currentIndex 跟随到新位置。
      if (currentMoved) {
        _currentIndex = list.length - 1;
        currentMoved = false;
      }
      order = order == null ? null : _orderInsert(order, list.length - 1);
    }
    _queue = List.unmodifiable(list);
    if (order != null) {
      final current = _currentIndex;
      if (current != null) {
        final pos = order.indexOf(current);
        if (pos >= 0) _shuffleCursor = pos;
      }
      _shuffleOrder = List<int>.unmodifiable(order);
    } else {
      _syncShuffleOrder();
    }
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
  }

  /// 插入到当前播放项之后（下一首播放）。已存在同 (音源, id) 歌曲则先移除再插入。
  void playNext(Song song) {
    final existingIndex = _queue.indexWhere(
      (s) => s.source == song.source && s.id == song.id,
    );
    // 目标即当前播放项：移除再插回原位是空操作（否则会破坏洗牌序游标）。
    if (existingIndex >= 0 && existingIndex == _currentIndex) return;
    final insertAt = (_currentIndex ?? -1) + 1;
    final list = List<Song>.from(_queue);
    int newSongIndex;
    if (existingIndex >= 0) {
      list.removeAt(existingIndex);
      // 移除位置在插入位置之前，需补偿索引
      final adjustedInsertAt = existingIndex < insertAt
          ? insertAt - 1
          : insertAt;
      newSongIndex = adjustedInsertAt.clamp(0, list.length);
      list.insert(newSongIndex, song);
      // 若移除的是当前之前的项，currentIndex 已偏移，插入位置正好对齐
      if (_currentIndex != null && existingIndex < _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      }
    } else {
      newSongIndex = insertAt.clamp(0, list.length);
      list.insert(newSongIndex, song);
    }
    _queue = List.unmodifiable(list);
    // 随机模式下把新歌插到洗牌序的当前歌之后（真正的「下一首」），
    // 其余歌曲的相对播放顺序保持不变。
    _maintainShuffleOrder(
      removedIndex: existingIndex,
      insertedIndex: newSongIndex,
      insertAfterCurrent: true,
    );
    notifyListeners();
    _queueDirty = true;
    _scheduleSave();
  }

  /// 解析并加载当前曲目。
  ///
  /// 解析顺序（单档语义 + 本地缓存挂点）：
  /// 1. `SongUrlResolver.checkLocalCache` 查本地缓存（MVP 恒 miss）；
  /// 2. 取已缓存档位（有则单发）否则 [qualityLevel] → 试听/失败时补发 [fallbackLevel]；
  /// 3. 完整版优先；仅试听片段则照播并置 [_isTrial]（UI 提示）；
  /// 4. 两档都无 url → [_error] = [NoPlayableUrlException]（需会员/付费）。
  ///
  /// **降级容错**：某档返回完整版 url 但 `_setUrl` 失败（CDN 403、解码不支持等）
  /// 时，不中断循环、不缓存该档，继续尝试下一档，避免"切到不可用音质后卡死"。
  Future<void> _loadCurrent() async {
    final song = currentSong;
    if (song == null) return;
    // 用户切歌/主动操作会再次 _loadCurrent：取消网络故障兜底重试定时器，
    // 避免上一首歌遗留的定时器在用户已切走后仍自动发起加载。
    _networkRetryTimer?.cancel();
    _networkRetryTimer = null;
    // 串行化守卫：已有 _loadCurrent 在执行中 → 记当前 (source, songId)，
    // 前一次执行完毕后检查挂起是否仍是最后一次请求的歌，再补偿。
    if (_loadInProgress) {
      // 直接覆盖 pendingSongId，不累计——多次快速切歌只补偿最后一次。
      // 用户快速点 A→B→C，前两次都被挡，只保留 C，补偿时只加载 C。
      _pendingSongId = (song.source, song.id);
      return;
    }
    _loadInProgress = true;
    // 开始加载就清 pending：本次加载期间产生的新 pending，等本次结束补偿，
    // 不与上次的 pending 混淆。
    _pendingSongId = null;
    // 记本首歌 (音源, id)，补偿时排除「循环补偿同一首」
    final startedId = (song.source, song.id);
    try {
      await _loadCurrentInternal();
    } finally {
      _loadInProgress = false;
      // 补偿条件：
      // 1. 有挂起请求（_pendingSongId != null）
      // 2. 挂起请求的目标歌 ≠ 刚完成加载的歌（否则是循环补偿，跳过）
      //
      // 为什么不用 currentSong.id == pending？
      // 场景：加载 A 期间，用户先点 B（pending=B）又点 C（pending=C）
      //   → finally 时 currentSong=C，pending=C → 补偿 C（正确）
      //   → 如果 loading C 期间用户又点 D → pending=D
      //   → finally 时 currentSong=D，pending=D → 补偿 D（正确）
      // 但如果 loading A 期间用户点 A 自己（切换队列但 song 不变）
      //   → pending=A，finally currentSong=A，startedId=A
      //   → 补偿「同一首」（startedId==pending），跳过，避免循环。
      //
      // 用「pending != startedId」更可靠：挂起请求不同于刚加载的歌，
      // 就补偿；相同则丢弃。两者都是 (音源, songId)，跨源同 id 不算同一首。
      final pending = _pendingSongId;
      if (pending != null && pending != startedId) {
        _pendingSongId = null;
        unawaited(_loadCurrent());
      } else if (pending != null) {
        _pendingSongId = null;
      }
    }
  }

  /// _loadCurrent 的核心实现，被串行化包裹。
  Future<void> _loadCurrentInternal() async {
    final song = currentSong;
    if (song == null) return;
    // 自增 token：本次 _loadCurrent 的唯一标识。后续任何 await 点之后检查
    // `token == _currentLoadToken`，不等则说明用户已切歌，旧请求作废。
    //
    // 解决 just_audio_windows 在快速切歌时并发 setUrl 导致 native
    // MediaPlayer 状态混乱崩溃（"Loading interrupted" + 非 platform thread
    // 发送 platform channel 消息）。
    final token = ++_currentLoadToken;
    _buffering = true;
    _error = null;
    // 重置上一首的实际音质信息，避免 UI 在加载期间显示残留数据
    _currentLevel = null;
    _currentBr = 0;
    _currentType = null;
    // 正常切歌时重置进度缓存：网络请求期间旧歌 positionStream 仍会推进，
    // _onPosition 的 _buffering 守卫会跳过更新，此处先归 0 确保防抖落盘
    // 写入的是新歌的 0 进度而非旧歌残留值。恢复会话时保留 snap.positionMs。
    if (!_restoring) {
      _currentProgressMs = 0;
    }
    notifyListeners();
    // 立即同步歌曲信息到媒体会话（通知栏显示新歌标题）
    MediaSessionManager.instance.updateMediaItem(
      song,
      coverUrl: song.coverFor(300),
    );
    // 同步收藏状态到通知栏收藏按钮图标（空心/实心）。
    MediaSessionManager.instance.updateFavorite(liked: liked.isLiked(song));
    // 同步缓冲状态
    MediaSessionManager.instance.updatePlaybackState(
      playing: false,
      position: Duration.zero,
      buffering: true,
    );
    try {
      // 离线短路·精确档：当前音质档（qualityLevel）已有完整缓存则直接离线播，
      // 零网络、无视 CDN 时效。checkLocalCache（resolve 第一
      // 步）。只命中「档位精确一致」的完整 key，不在此退档——降档交给在线解析；
      // 在线全链失败后再由缓存兜底（bestUrlFor）。
      final cached = AudioCache.exactUrlFor(song, level: qualityLevel);
      if (token != _currentLoadToken) {
        return;
      }
      if (cached != null) {
        await _setUrl(
          // 带上缓存 key 里解析出的实际档位/编码/码率，避免 UI 音质栏（level）
          // 因 result.level 为 null 而隐藏（离线命中本来也不走 CDN 解析）；
          // br 让 kbps 在离线时也如实显示（缓存字节不携带码率，靠在线期登记）。
          SongUrlResult(
            url: cached.url,
            level: cached.level,
            type: cached.type,
            br: cached.br,
          ),
          fromLevelCache: true,
          loadToken: token,
        );
        return;
      }
      // Netease 就绪守卫放在离线短路之后：命中完整缓存时根本不需要
      // netease.api（纯本地直播），不应被 NeteaseProvider 的 async init
      // （尤其 cold start 走网络确认登录态分支）拖慢。仅在确需联网取 URL 前等待。
      if (!netease.initialized) {
        await netease.initializedFuture;
      }
      // init 已跑完但 api 仍未就绪（如会话存储初始化失败）→ 抛给下方兜底路径，
      // 不逐档位调 API，避免每个候选音质都抛一次 StateError 刷日志。
      if (!netease.apiReady) {
        throw StateError('NeteaseProvider 未就绪（会话存储初始化失败）');
      }
      // 实时选择优先：当前选择档位在前，历史成功档 / standard 兜底殿后。
      final known = _fullLevelCache[(song.source, song.id)];
      final levels = <String>[
        qualityLevel,
        if (known != null && known != qualityLevel) known,
        if (fallbackLevel != qualityLevel && fallbackLevel != known)
          fallbackLevel,
      ];
      // 网络瞬时故障退避重试：把「逐档取 URL → 试听 → 缓存兜底」整段包进循环。
      // - 网络错误（DNS 解析失败/超时/TLS/断网，NeteaseException.isNetwork）：
      //   属瞬时故障，不跳过、不计连续失败，原地退避重试 networkRetryAttempts 次；
      //   全部耗尽后保留当前曲、显式停止播放并挂 _networkRetryTimer 长周期自愈续播，
      //   网络恢复后自动从当前曲继续。
      // - 无版权/需会员（接口正常但 parse 无 url）/CDN 播放失败：非网络问题，走
      //   原有跳过链，防止卡死当前曲。
      var networkAttempts = 0;
      while (true) {
        SongUrlResult? trial;
        Object? loadError;
        Object? fetchError;
        for (final level in levels) {
          final Map<String, dynamic> body;
          try {
            body = await netease.api.songUrl([song.id], level: level);
          } catch (e, st) {
            // 取 URL 的网络请求失败（断网/DNS/代理/服务端异常）：记录首个错误，
            // 尝试其它档位，不在此中断——真正的无版权应能正常返回但无 url。
            fetchError ??= e;
            AppLog.warn(
              '获取歌曲 URL 失败：${song.name} (level=$level)',
              tag: 'player',
              error: e,
              stack: st,
            );
            continue;
          }
          if (token != _currentLoadToken) {
            return;
          }
          final result = SongUrlResolver.parse(body);
          if (result == null) {
            continue;
          }
          if (!result.isTrial) {
            try {
              await _setUrl(result, level: level, loadToken: token);
              return;
            } catch (e, st) {
              // url 设置失败（CDN 403、格式不支持等），清理 player 状态后降级。
              loadError = e;
              AppLog.warn(
                'URL 播放失败（CDN/格式）：${song.name} (level=$level)',
                tag: 'player',
                error: e,
                stack: st,
              );
              try {
                await _player.stop();
              } catch (_) {}
              continue;
            }
          }
          trial ??= result;
        }
        if (trial != null) {
          try {
            await _setUrl(trial, loadToken: token);
            return;
          } catch (e, st) {
            loadError = e;
            AppLog.warn(
              '试听 URL 播放失败：${song.name}',
              tag: 'player',
              error: e,
              stack: st,
            );
            try {
              await _player.stop();
            } catch (_) {}
          }
        }
        // 离线兜底：在线全链失败（断网/无可用 URL/试听也失败）且该歌存在任意档
        // 完整缓存时，按最高档播缓存，不计入连续失败、不触发自动跳过——避免
        // 「网络抖动/断网 → 被归类为跳过 → 把本有缓存可播的歌跳空」。
        if (token == _currentLoadToken) {
          final cachedHit = AudioCache.bestUrlFor(song, rank: _qualityRank);
          if (cachedHit != null) {
            try {
              await _setUrl(
                SongUrlResult(
                  url: cachedHit.url,
                  level: cachedHit.level,
                  type: cachedHit.type,
                  br: cachedHit.br,
                ),
                fromLevelCache: true,
                loadToken: token,
              );
              return;
            } catch (e, st) {
              loadError = e;
              AppLog.warn(
                '缓存兜底播放失败：${song.name}',
                tag: 'player',
                error: e,
                stack: st,
              );
              try {
                await _player.stop();
              } catch (_) {}
            }
          }
        }
        // 判定是否为网络类瞬时故障：仅取 URL 请求抛出的 NeteaseException。
        // CDN 播放失败（loadError）属源侧问题，不进网络重试路径。
        final isNetworkFailure =
            fetchError is NeteaseException && fetchError.isNetwork;
        if (isNetworkFailure && networkAttempts < networkRetryAttempts) {
          // 网络请求已失败：首轮立即暂停旧曲，避免退避重试期间（最长可达
          // 十几秒）旧歌仍在播放，造成「UI 已切新歌/加载中、底层还在播旧歌」
          // 的错位假象——进度条照走、拖动/暂停都作用在旧歌上（离线切未缓存
          // 歌的实测现象）。用 pause 而非 stop：保留旧 source（ExoPlayer
          // renderer 不进入 idle），网络恢复后 setUrl 替换 source 再 play 走
          // 标准路径，不触发「stop→setUrl→play 重绑失败」问题（见 _setUrl）。
          // 用户主动暂停（_userPaused=true）时不打扰其暂停意图。
          if (_player.playing && !_userPaused) {
            try {
              await _player.pause();
            } catch (_) {}
            _setUiPlaying(false);
            notifyListeners();
          }
          networkAttempts++;
          final delay = networkRetryBaseDelay * networkAttempts;
          final detail = fetchError.networkCauseDetail;
          AppLog.warn(
            '网络故障${detail != null ? '（$detail）' : ''}，'
            '${delay.inMilliseconds}ms 后重试'
            '（$networkAttempts/$networkRetryAttempts）：${song.name}',
            tag: 'player',
            error: fetchError,
          );
          // 保持 buffering UI，短退避后原地重试同一首歌。
          notifyListeners();
          await Future<void>.delayed(delay);
          if (token != _currentLoadToken) {
            return;
          }
          continue;
        }
        // 所有档位均不可播：区分三类失败，给 UI 准确的提示文案。
        // - 无版权/需会员（loadError == null 且 fetchError == null）：接口正常
        //   返回但全部档位 parse 出 null，即根本没有可用 url，属于"永久性不可播"，
        //   按原有逻辑自动跳过。
        // - CDN/源加载失败（loadError != null）：setUrl/播放报错（CDN 403、代理
        //   连不上等），非网络瞬时故障，仍按跳过逻辑处理，标记类型供 UI 区分。
        // - 网络瞬时故障（isNetworkFailure 且重试耗尽）：不跳过、不计连续失败，
        //   保留当前曲，显式停止播放并挂长周期定时器等待自愈续播。
        if (isNetworkFailure) {
          _error = fetchError;
          _buffering = false;
          final detail = fetchError.networkCauseDetail;
          AppLog.warn(
            '网络故障${detail != null ? '（$detail）' : ''}重试耗尽，'
            '保留当前曲等待网络恢复自动续播：${song.name}',
            tag: 'player',
            error: fetchError,
          );
          // 显式停止底层播放器并同步 UI：手动切歌不会先 stop 旧曲，若不停止
          // 会残留「UI 显示新歌+错误、底层还在播旧歌」的播放中假象。
          // 不 await：测试环境无 just_audio 平台实现时 stop() 会挂起在
          // platform channel 上；生产环境 stop 为尽力而为，异步完成即可。
          _player.stop().onError((_, _) {});
          _setUiPlaying(false);
          notifyListeners();
          _scheduleNetworkSelfHeal(song);
          return;
        }
        // fetchError 走到这里必为非网络错误（网络错误已在上方提前返回），
        // 若仍非空（业务码错误等）也归为 source 类型，与改动前语义一致。
        final isSourceFailure = loadError != null || fetchError != null;
        _skipKind = isSourceFailure ? 'source' : 'noPlayable';
        _consecutiveFailures++;
        _error = loadError ?? const NoPlayableUrlException();
        _buffering = false;
        final skipped = List<String>.from(_skippedSongs)..add(song.name);
        _skippedSongs = List.unmodifiable(skipped);
        AppLog.warn(
          isSourceFailure
              ? '源加载/网络失败，跳过：${song.name}'
              : '无可播放 URL（付费/无版权）：${song.name}',
          tag: 'player',
        );
        if (_consecutiveFailures <= 3 && hasNext) {
          notifyListeners();
          await _nextInternal();
        } else {
          // 连续跳过多首都失败：记录停止原因，UI 提示。
          _skipStopReason = _consecutiveFailures > 3 ? 'overLimit' : 'noMore';
          // 显式停止底层播放器并同步 UI，避免播放器仍停留在播放/缓冲状态，
          // 造成通知栏/播放页的"播放中"假象（即便已无歌可播）。
          try {
            await _player.stop();
          } catch (_) {}
          _buffering = false;
          _error = loadError ?? const NoPlayableUrlException();
          _setUiPlaying(false);
          notifyListeners();
        }
        // 跳过逻辑执行完毕，退出重试循环（仅网络错误会触发重试）。
        break;
      }
    } catch (e, st) {
      _error = e;
      AppLog.error('加载歌曲异常：${song.name}', tag: 'player', error: e, stack: st);
    } finally {
      // 仅当本次请求仍是最新时才清 buffering：否则可能覆盖新请求的 buffering 状态
      if (token == _currentLoadToken) {
        _buffering = false;
        notifyListeners();
      }
    }
  }

  /// 网络瞬时故障重试耗尽后的长周期自愈续播。
  ///
  /// 保留当前曲（不跳过），显式停止播放，挂一个定时器周期性重发 [_loadCurrent]。
  /// 后台网络（Doze/弱网）恢复后，本次重试会重新走短退避流程并成功续播当前曲。
  /// 定时器采用「重试一轮后递增间隔，上限 [networkRetryBaseDelay] × 8」的策略，
  /// 避免在弱网下高频空转。
  void _scheduleNetworkSelfHeal(Song song) {
    _networkRetryTimer?.cancel();
    // 递增间隔：baseDelay × (1,2,3,…,8)，之后封顶在 ×8，不再回退。
    // 注意不可用 % 8：streak 到 8 会 (8 % 8)+1=1 重新从 baseDelay 跳回，
    // 导致持续断网下退避间隔反复振荡。
    final attempts = math.min(_networkSelfHealStreak, 7) + 1;
    final delay = networkRetryBaseDelay * attempts;
    _networkSelfHealStreak++;
    _networkRetryTimer = Timer(delay, () {
      _networkRetryTimer = null;
      // 仅在用户仍未切走该曲时自愈续播。
      final current = currentSong;
      if (current != null &&
          current.source == song.source &&
          current.id == song.id) {
        unawaited(_loadCurrent());
      } else {
        _networkSelfHealStreak = 0;
      }
    });
  }

  /// 设置播放器 URL。
  ///
  /// [level] 为解析出该 URL 的音质档位，非空时写入 [_fullLevelCache] 供下次
  /// 直接命中（跳过档位探测）。本地缓存命中时 [fromLevelCache] 为 true，语义
  /// 相同但无需额外写缓存。
  ///
  /// [loadToken] 为本次加载请求的令牌（由调用方 `_loadCurrent` 传入）。
  /// `await _player.setUrl()` 之后检查 token 是否仍是最新，不是则立即
  /// return，防止「并发 setUrl」—— just_audio_windows 的 native MediaPlayer
  /// 在 STA 线程上并发 load 会导致状态错乱崩溃。
  Future<void> _setUrl(
    SongUrlResult result, {
    String? level,
    bool fromLevelCache = false,
    required int loadToken,
  }) async {
    final song = currentSong;
    _isTrial = result.isTrial;
    _currentLevel = result.level;
    _currentBr = result.br;
    _currentType = result.type;
    final playUrl = await resolvePlayUrl(song, result);
    // 直接 setUrl() 替换 source（just_audio 内部会释放旧 source 并 prepare
    // 新 source），不再显式先 stop()：
    //
    // 之前版本在播放中先 stop() 再 setUrl() 再 play()，ExoPlayer 上
    // renderer 会进入 idle，紧接的 play() 不总能重新绑定新渲染管线，
    // 表现为「UI 已切新歌但音频/进度停在旧歌，须手动 pause→play 才恢复」
    // （问题 2）。直接 setUrl+play 走标准替换路径，由末尾的 _recoverIfStuck
    // 兜底检测「播放中 position 不推进」的残余 native 场景。
    //
    // Windows MediaPlayer 每次 setUrl 内部会重置，无副作用。
    await _player.setUrl(playUrl);
    // 换源后检查音量是否被重置（+epsilon 容差：just_audio_windows 经
    // platform channel 传输 volume 会产生 float32 精度伪影，例如
    // 0.3 读回为 0.30000001192092896，直接 != 会误报成"被重置"）。
    if ((_player.volume - _appliedVolume).abs() > 0.001) {
      try {
        await _player.setVolume(_appliedVolume);
      } catch (e) {
        // 重施加失败静默忽略，音量保持 native 侧值
      }
    }
    // 关键检查点：setUrl 返回后如果 token 已被更新 → 用户已切歌，
    // 立即 return，不再写缓存/清 buffering/seek/play，避免与新请求竞争。
    if (loadToken != _currentLoadToken) {
      return;
    }
    // URL 已就绪：清除连续失败计数（成功路径），写音质档位缓存。
    _consecutiveFailures = 0;
    final songId = song?.id;
    final cachedLevel = fromLevelCache ? result.level : level;
    if (songId != null && cachedLevel != null && !result.isTrial) {
      _fullLevelCache[(song?.source ?? SongSource.netease, songId)] =
          cachedLevel;
    }
    // 试听片段：写入一次性提示标志，供 MainScaffold 消费。
    // 注意：使用「_pendingTrialSongName」而非「isTrial」，因为 isTrial 在
    // 整个试听期间一直为 true，会导致每次状态变化都重复弹提示。
    if (result.isTrial && song != null) {
      _pendingTrialSongName = song.name;
    }
    // URL 已就绪：加载完成，立即清除加载状态。后续 _startPlayback 的重试
    // 属于"尝试启动播放"，不应让 UI 继续显示加载中（恢复会话时
    // _startPlayback 可能因 native 中间状态重试多次，导致加载状态残留）。
    _buffering = false;
    notifyListeners();
    // 同步媒体会话（系统通知栏）
    if (song != null) {
      MediaSessionManager.instance.updateMediaItem(
        song,
        coverUrl: song.coverFor(300),
      );
      // 同步收藏状态（_setUrl 可能在 updateFavorite 之前被调用，
      // 或 media session 异步初始化完成晚于 _loadCurrentInternal，
      // 此处兜底确保通知栏收藏图标与实际状态一致）。
      MediaSessionManager.instance.updateFavorite(liked: liked.isLiked(song));
      // 更新播放状态（包括缓冲状态）
      MediaSessionManager.instance.updatePlaybackState(
        playing: _uiPlaying,
        position: Duration(milliseconds: _currentProgressMs),
        buffering: false,
      );
    }
    // 恢复会话时：setUrl 之后、启动播放之前先 seek 到保存的进度。
    if (_restoring && _currentProgressMs > 0) {
      final nearEnd =
          song != null &&
          song.durationMs > 0 &&
          _currentProgressMs >= song.durationMs - 2000;
      if (!nearEnd) {
        try {
          await _player.seek(Duration(milliseconds: _currentProgressMs));
        } catch (_) {}
      }
      if (loadToken != _currentLoadToken) {
        return;
      }
    }
    await _startPlayback();
    if (loadToken != _currentLoadToken) {
      return;
    }
    // 只在播放真正启动后才记录开始时间：_startPlayback 在 _userPaused 或
    // 重试全部失败时提前返回，此时 _player.playing 为 false，不应记时。
    if (_player.playing && !_userPaused) {
      _lastPlayStartTime = DateTime.now().millisecondsSinceEpoch;
      // 最近播放：播放真正启动即记录（去重顶到最前），无阈值。
      _recordRecentPlay(song);
      // 播放成功启动：网络已恢复，重置流中断自动恢复的连续失败计数。
      // 覆盖断点续播、网络自愈、普通重试三条路径的恢复成功场景。
      _streamRecoverStreak = 0;
      // 播放真正启动：发出内容重载信号，供此前因断网加载失败的封面/歌词重试。
      _contentTick++;
    }
    // _startPlayback 可能因 _userPaused=true 提前 return（没播起来），
    // 也可能重试后最终 playing=false（native bug）。但此时 Provider 内部状态
    // 已变化（isTrial、buffering、_pendingTrialSongName 等），需要再通知
    // 一次 listener，确保 MainScaffold 能消费试听/跳过提示。
    notifyListeners();
    // 问题 2 兜底：播放中切换 source 后，若 playing=true 但 position 长时间
    // 不推进（native 渲染管线未绑定新 source），做一次 stop→setUrl→play
    // 硬恢复。unawaited 不阻塞 UI；token/用户暂停/restoring 守卫防止误伤
    // 正在发生的切歌/暂停/恢复操作。
    if (!_userPaused && !_restoring && _player.playing) {
      unawaited(_recoverIfStuck(result: result, loadToken: loadToken));
    }
  }

  /// 启动播放并处理 just_audio_windows 的 native 中间状态 bug。
  ///
  /// **问题 1**：just_audio_windows 在 `mediaPlayer.Play()` 后触发
  /// `PlaybackStateChanged` 回调时，MediaPlayer 可能仍处于中间过渡状态
  /// （非 Playing），`broadcastDataEvent` 会报告 `playing=false`，覆盖
  /// just_audio 在 `play()` 开头设置的 `playing=true`。后续 native 端进入
  /// Playing 状态时的 `playing=true` 事件可能因非 platform thread 发送
  /// 被丢弃，导致 just_audio 永远认为播放已暂停。
  ///
  /// **问题 2**：恢复暂停场景 / 用户手动 pause 时，`playing=false` 是合理
  /// 结果，不能被当作 native bug 重试 play()。通过 [_userPaused] 标志区分：
  /// 每次迭代前检查该标志，用户明确想要暂停时立即退出循环。
  ///
  /// **问题 3（Android）**：`await _player.play()` 的 Future 可能长时间不
  /// resolve（实测：播放启动后 ~2ms 即广播 playing=true、音频正常播，但
  /// Future 直到用户下一次 pause() 才返回，长达 ~12s）。若硬 await 会阻塞
  /// 整个加载管线（`_loadInProgress` 持续 true）→ 播放中切歌被 `SKIP`，
  /// UI 显示新歌但音频/进度仍是旧歌，必须暂停才恢复（问题 2 的实际成因）。
  /// 故给 play() 加 100ms 超时：超时后直接按 `_player.playing` 判定，不再
  /// 等待完成信号；Windows 的 native 误报重试逻辑原样保留。
  ///
  /// **修复**：play() 后如果 playing 仍为 false 且非用户暂停意图，等待
  /// 短暂时间看 native 是否最终报告 playing=true，否则重试 play()。
  /// 最多重试 3 次。
  Future<void> _startPlayback() async {
    const retryDelay = Duration(milliseconds: 400);
    const maxRetries = 3;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      // 用户主动 pause 或恢复时明确要求暂停：不重试，立即放弃播放。
      if (_userPaused) {
        return;
      }
      // 触发播放；Android 上 play() 的 Future 可能不 resolve，加超时兜底，
      // 避免阻塞加载管线（见方法注释「问题 3」）。
      try {
        final playFuture = _player.play();
        // 超时后源 Future 的 timeout listener 会被移除，若它迟到地以错误
        // 完成（如 native 异常），会变 unhandled async error。挂一个忽略
        // 错误的兜底监听，防止该场景崩溃。
        // ignore: unawaited_futures
        playFuture.catchError((_) {});
        await playFuture.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () {},
        );
      } catch (_) {}
      if (_player.playing) return;
      if (_userPaused) return;
      // playing=false：可能是 native 中间状态覆盖了 playing=true。
      // 等待短暂时间看 native 是否最终报告 playing=true。
      if (attempt < maxRetries) {
        await Future.delayed(retryDelay);
        if (_userPaused || _player.playing) return;
      }
    }
  }

  /// 问题 2 兜底：播放中切换 source 后 position 不推进的硬恢复。
  ///
  /// 正常切歌时 position 应立即推进；若较长时间内仍停留在起点（且非缓冲
  /// 中），判定 native 渲染管线未绑定新 source，执行一次 stop→setUrl→play。
  /// 每个检查点都校验 [loadToken] 仍最新、用户未暂停、player 仍在播放、
  /// 非恢复会话，任一不满足立即放弃，避免与新的切歌/暂停/清空竞争。
  Future<void> _recoverIfStuck({
    required SongUrlResult result,
    required int loadToken,
  }) async {
    final startMs = _player.position.inMilliseconds;
    for (var i = 0; i < 5; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (loadToken != _currentLoadToken) return;
      if (_userPaused || !_player.playing || _restoring) return;
      // 网络缓冲期 position 也可能不推进，不算卡死。
      if (_player.processingState == ProcessingState.buffering) continue;
      if (_player.position.inMilliseconds > startMs + 400) return;
    }
    try {
      await _player.stop();
    } catch (_) {}
    if (loadToken != _currentLoadToken || _userPaused || _restoring) return;
    await _player.setUrl(result.url);
    if (loadToken != _currentLoadToken || _userPaused || _restoring) return;
    await _startPlayback();
  }

  /// 清除音质档位缓存（登出/切换账号后调用，避免跨账号误判可用档）。
  void clearLevelCache() => _fullLevelCache.clear();

  // ── 控制 ──

  /// 从设置同步 Windows 音量：实际值 = 百分比/100 ×
  /// [SettingsProvider.windowsVolumeCap]，立即重施加。由设置页音量滑块在
  /// 调整时调用；仅 Windows 生效（其余平台固定 [_kMobileVolume]）。
  void syncWindowsVolume() {
    if (!PlatformUtils.isWindows) return;
    _appliedVolume = settings.windowsVolume;
    unawaited(_player.setVolume(_appliedVolume));
  }

  Future<void> toggle() async {
    if (_player.playing) {
      _userPaused = true;
      await _player.pause();
    } else {
      _userPaused = false;
      await _player.play();
    }
  }

  Future<void> play() async {
    _userPaused = false;
    await _player.play();
  }

  Future<void> pause() async {
    _userPaused = true;
    await _player.pause();
  }

  /// 手动拖动进度：立即更新进度缓存并调度落盘，避免依赖 positionStream +
  /// 5s 节流导致「拖完立刻退出丢进度」。
  Future<void> seek(Duration position) async {
    _currentProgressMs = position.inMilliseconds;
    _scheduleSave();
    // 立即同步进度到媒体会话
    MediaSessionManager.instance.updatePlaybackState(
      playing: _uiPlaying,
      position: position,
    );
    try {
      await _player.seek(position);
    } catch (_) {
      // seek 失败静默忽略（如当前无加载曲目）
    }
  }

  /// 立即落盘当前状态（退出/退后台前调用；返回 Future 供调用方等待写盘完成）。
  Future<void> persistNow() => _persistNow();

  /// 记录播放统计（SQLite）
  ///
  /// 仅在非试听、累计听歌时长超过阈值时记录。
  /// 阈值：min(durationMs * 0.6, 60000)。
  void _recordPlaybackStats() {
    final song = currentSong;
    if (song == null || _isTrial) return;

    // 将当前播放会话的时长先累积（如果仍在播放中）。
    _accumulateListenMs();
    if (_accumulatedListenMs <= 0) return;

    final durationMs = song.durationMs;
    final thresholdMs = (durationMs * 0.6).round().clamp(0, 60000);

    final listenMs = _accumulatedListenMs;
    // 置零防止同一首歌被重复记录（_onCompleted → next() 路径）。
    _accumulatedListenMs = 0;

    // 播放时长未达阈值，不记录
    if (listenMs < thresholdMs) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    // 异步写入，不阻塞播放流程
    unawaited(_writePlaybackStats(song, listenMs, now));
  }

  Future<void> _writePlaybackStats(Song song, int listenMs, int nowMs) async {
    try {
      await DatabaseHelper.instance.recordPlay(
        source: song.source,
        sourceId: song.id.toString(),
        name: song.name,
        artist: song.artists.isNotEmpty ? song.artists.join('/') : null,
        album: song.albumName,
        coverUrl: song.coverUrl,
        durationMs: song.durationMs,
        listenMs: listenMs,
        nowMs: nowMs,
      );
    } catch (e) {
      // 静默失败，不影响播放
      AppLog.warn('记录播放统计失败', tag: 'player', error: e);
    }
  }

  /// 记录最近播放（去重时间线，无阈值，播放启动即记）。
  ///
  /// 与 [_writePlaybackStats] 独立：统计表有阈值（≥60% 时长）保证「有效播放」，
  /// 最近播放不设阈值，「播放过就要记录」，即使 1 秒切换也算一次最近播放。
  /// 试听片段（trial）不进最近播放，避免预览噪音刷列表。
  void _recordRecentPlay(Song? song) {
    if (song == null || _isTrial) return;
    unawaited(_writeRecentPlay(song, DateTime.now().millisecondsSinceEpoch));
  }

  Future<void> _writeRecentPlay(Song song, int nowMs) async {
    try {
      await DatabaseHelper.instance.recordRecentPlay(
        source: song.source,
        sourceId: song.id.toString(),
        name: song.name,
        artist: song.artists.isNotEmpty ? song.artists.join('/') : null,
        album: song.albumName,
        coverUrl: song.coverUrl,
        durationMs: song.durationMs,
        fee: song.fee,
        playedAtMs: nowMs,
      );
    } catch (e) {
      // 静默失败，不影响播放
      AppLog.warn('记录最近播放失败', tag: 'player', error: e);
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _pendingFalseStateTimer?.cancel();
    _networkRetryTimer?.cancel();
    _networkRetryTimer = null;
    // 归还 WiFi 锁，避免播放器销毁后锁残留。
    unawaited(WifiLock.release());
    liked.removeListener(_onLikedChanged);
    // 落盘最终状态（快照先同步构建，避免 dispose 后访问 player 抛错）。
    unawaited(_persistNow());
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}

/// 判断 Media3 播放错误码是否为可恢复的网络/IO 类。
///
/// 网络连接失败/超时、HTTP 状态错误属于瞬时故障，URL 失效可刷新重试；
/// 解析/解码/格式类错误不可恢复，重试也会复现，走原错误路径。
@visibleForTesting
bool isRecoverableStreamErrorCode(int code) {
  // code 未定义（<=0 或未知）：保守不恢复。
  if (code <= 0) return false;
  const recoverableCodes = <int>{
    2000000, // ERROR_CODE_IO_UNSPECIFIED
    2000001, // ERROR_CODE_IO_NETWORK_CONNECTION_FAILED
    2000002, // ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
    2000003, // ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE
    2000004, // ERROR_CODE_IO_BAD_HTTP_STATUS
    2000005, // ERROR_CODE_IO_FILE_NOT_FOUND
    2000008, // ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE
  };
  if (recoverableCodes.contains(code)) return true;
  // 网络类错误码范围（Media3 2000000-2000008），其余（解析/解码/音频轨/
  // DRM）不恢复。
  return code >= 2000000 && code < 3000000;
}

/// 决定要交给播放器播的 URL（音频缓存路由）。
///
/// 抽出 _setUrl 里的缓存代理路由逻辑为顶层函数，便于不依赖 AudioPlayer
/// 实例的回归测试（#1 回归防复发）。
///
/// 规则：
/// - 无歌 / 试听 / 缓存不可用 → 原样播 [result.url]（试听不进缓存）。
/// - [result.url] 已是本地代理地址（离线命中 `exactUrlFor`/`bestUrlFor` 返回的
///   `http://127.0.0.1:<port>/<key>`）→ **直接播，不再 routeUrl**。绝不能再把
///   代理地址喂给 routeUrl：routeUrl 会用 result.level/type（离线命中时均为
///   null）重推 key → 档位错位 404，且记住「代理地址」当 CDN 直链污染会话。
/// - 否则（CDN 直链）→ `AudioCache.routeUrl` 转发代理：命中本地、未命中回源。
@visibleForTesting
Future<String> resolvePlayUrl(Song? song, SongUrlResult result) async {
  final proxyBase = AudioCacheProxy.instance.baseUrl;
  final alreadyProxied = proxyBase != null && result.url.startsWith(proxyBase);
  if (song == null || result.isTrial || !AudioCache.ready || alreadyProxied) {
    return result.url;
  }
  return AudioCache.routeUrl(song, result);
}
