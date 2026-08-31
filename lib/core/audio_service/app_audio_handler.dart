import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/song.dart';
import '../logging/app_log.dart';
import '../../widgets/cover_image.dart';

/// 应用级媒体会话处理器。
///
/// 作为 [AudioService] 的回调入口，处理系统媒体按钮事件（通知栏控制、
/// 耳机按键、锁屏控制等），并同步当前播放状态到系统媒体会话。
///
/// 使用方式：
/// 1. 应用启动时通过 [AudioService.init] 创建实例
/// 2. [PlayerProvider] 播放状态变化时调用 [setMediaItem] / [updatePlaybackState]
/// 3. 系统控制事件通过回调转发给 [PlayerProvider]
class AppAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  /// 回调：系统请求播放
  final VoidCallback? onPlay;

  /// 回调：系统请求暂停
  final VoidCallback? onPause;

  /// 回调：系统请求下一首
  final VoidCallback? onNext;

  /// 回调：系统请求上一首
  final VoidCallback? onPrevious;

  /// 回调：系统请求跳转
  final void Function(Duration position)? onSeek;

  /// 回调：系统请求停止
  final VoidCallback? onStop;

  /// 回调：系统请求切换当前歌曲收藏态（通知栏收藏按钮）。
  final Future<void> Function()? onToggleFavorite;

  AppAudioHandler({
    this.onPlay,
    this.onPause,
    this.onNext,
    this.onPrevious,
    this.onSeek,
    this.onStop,
    this.onToggleFavorite,
  });

  /// 上一次设置的媒体项，用于去重
  MediaItem? _lastMediaItem;

  /// 上一次播放状态的指纹，用于节流
  _PlaybackStateFingerprint? _lastStateFingerprint;

  /// 当前歌曲是否已收藏（决定通知栏收藏按钮空心/实心图标）。
  bool _favorite = false;

  /// 封面解析序号：并发请求只让最新一次生效，防止旧请求的慢解析覆盖新歌封面。
  int _artworkSeq = 0;

  /// 已解析出的封面文件 URI：songKey → `file://` URI。命中后同一首歌再次
  /// 下发时直接复用（不闪占位图），也避免重复下载/重写临时文件。
  final Map<String, Uri> _coverUris = {};

  /// 占位图临时文件 URI（惰性写入一次，缓存复用）。
  Future<Uri?>? _placeholderUriFuture;

  /// 封面临时文件基目录（`<temp>/fluxwave_artwork/`）。
  Future<String>? _artworkDirFuture;

  /// 是否已做过启动清理（每进程一次）。首次解析临时目录时清掉上一会话
  /// 残留的封面文件，把磁盘占用限制在本会话内。
  bool _artworkCleaned = false;

  /// 设置当前媒体信息（歌曲标题、歌手、封面、时长）。
  ///
  /// 封面不直接传 CDN URL：那会让原生加载器在断网/无缓存时拉取失败（且其请求
  /// 不带网易云 CDN 要求的 Referer/UA，联网也未必拉得到）。改为自行解析字节
  /// （复用 [CoverImage] 的下载与内存/磁盘缓存）后写临时文件，以 `file://` 交给
  /// 通知栏，从而覆盖三种场景：
  /// - 在线：下载封面 → 显示封面；
  /// - 离线但有缓存：磁盘缓存字节 → 同样显示封面；
  /// - 离线且无缓存：占位图兜底。
  ///
  /// 分两阶段下发：先立即用「已知封面或占位图」出一版（标题/歌手即时更新），
  /// 封面解析完成后再重发真实封面。断网→重连后，重发时的封面 `file://` URI
  /// 与占位图不同，会绕过 [_lastMediaItem] 去重，通知栏自动恢复正确封面。
  Future<void> setMediaItem(Song song, {String? coverUrl}) async {
    final seq = ++_artworkSeq;
    final songKey = '${song.source}_${song.id}';
    // 阶段 1：立即下发，保证标题/歌手即时更新。
    final known = _coverUris[songKey] ?? await _placeholderUri();
    _emitMediaItem(seq, song, known);
    if (coverUrl == null || coverUrl.isEmpty) return;
    // 阶段 2：后台解析真实封面（内存/磁盘/网络），更好则重发。
    // 整体包进 try/catch：文件写入/路径解析等任何异常都静默降级到阶段 1
    // 已下发的占位图，而非向调用方抛未处理异步异常（本方法是 unawaited 调用）。
    try {
      final bytes = await CoverImage.fetchBytes(coverUrl, songKey: songKey);
      if (bytes == null || seq != _artworkSeq) return;
      final uri = await _writeCoverFile(bytes, songKey);
      if (seq != _artworkSeq) return;
      _coverUris[songKey] = uri;
      if (uri != known) _emitMediaItem(seq, song, uri);
    } catch (e, st) {
      // 封面解析失败：通知栏已显示阶段 1 的占位图，静默降级，但留日志
      // 便于排障（若为编程错误也能看到线索）。
      AppLog.warn(
        '通知栏封面解析失败，保留占位图：${song.name}',
        tag: 'media',
        error: e,
        stack: st,
      );
    }
  }

  /// 下发媒体项：token 校验防旧请求覆盖新歌 + 去重相同项。
  void _emitMediaItem(int seq, Song song, Uri? artUri) {
    if (seq != _artworkSeq) return;
    final item = MediaItem(
      id: '${song.source}_${song.id}',
      title: song.name,
      artist: song.artists.isNotEmpty ? song.artistsLabel : null,
      album: song.albumName,
      duration: Duration(milliseconds: song.durationMs),
      artUri: artUri,
    );
    if (_lastMediaItem != null &&
        _lastMediaItem!.id == item.id &&
        _lastMediaItem!.title == item.title &&
        _lastMediaItem!.artUri == item.artUri) {
      return;
    }
    _lastMediaItem = item;
    mediaItem.add(item);
  }

  /// 占位图临时文件 URI：从资源包读一次、写临时文件一次，之后复用。
  /// 写入失败（异常场景）返回 null，通知栏显示默认图标。
  Future<Uri?> _placeholderUri() {
    return _placeholderUriFuture ??= _ensurePlaceholderFile();
  }

  Future<Uri?> _ensurePlaceholderFile() async {
    try {
      final dir = await _artworkDir();
      final file = File('$dir/placeholder.png');
      if (!await file.exists()) {
        final data = await rootBundle.load('assets/placeholder_cover.png');
        await file.create(recursive: true);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      return Uri.file(file.path);
    } catch (_) {
      return null;
    }
  }

  /// 将封面字节写入临时文件（同名覆盖，不重复写），返回 `file://` URI。
  Future<Uri> _writeCoverFile(Uint8List bytes, String songKey) async {
    final dir = await _artworkDir();
    final file = File('$dir/cover_$songKey.jpg');
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    return Uri.file(file.path);
  }

  Future<String> _artworkDir() {
    return _artworkDirFuture ??= () async {
      final temp = await getTemporaryDirectory();
      final dir = '${temp.path}/fluxwave_artwork';
      if (!_artworkCleaned) {
        _artworkCleaned = true;
        // 启动清理：删掉上一会话残留的封面临时文件（本会话按需重建，重建时
        // fetchBytes 仍命中内存/磁盘封面缓存，不重新下载）。清理放在本缓存
        // Future 体内、返回路径之前，占位图/封面写入都在 await 之后发生，
        // 「先删干净、再写新文件」顺序天然成立，无删掉正在写的文件的竞态。
        try {
          final old = Directory(dir);
          if (await old.exists()) {
            await old.delete(recursive: true);
          }
        } catch (_) {}
      }
      return dir;
    }();
  }

  /// 通知栏封面临时目录（`<temp>/fluxwave_artwork/`）总大小（字节）。
  ///
  /// 供设置页展示。该目录由启动时自动清理接管，且位于系统可清理的应用
  /// 缓存目录内（手机管家/系统「清理缓存」可清除），无需手动删除。
  static Future<int> artworkCacheBytes() async {
    try {
      final temp = await getTemporaryDirectory();
      final dir = Directory('${temp.path}/fluxwave_artwork');
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 更新播放状态（播放/暂停/进度/缓冲等）。
  ///
  /// 内部节流：相同状态不会重复发送。
  void updatePlaybackState({
    required bool playing,
    required Duration position,
    required Duration buffered,
    bool? buffering,
  }) {
    final fingerprint = _PlaybackStateFingerprint(
      playing: playing,
      positionMs: position.inMilliseconds,
      buffering: buffering ?? false,
    );

    // 节流：相同状态不重复更新
    if (_lastStateFingerprint == fingerprint) return;
    _lastStateFingerprint = fingerprint;

    final controls = _buildControls(playing);

    playbackState.add(playbackState.value.copyWith(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      // 紧凑区放前 3 个（收藏/上一首/播放暂停），下一首在展开区：
      // Android 紧凑区上限 3（MAX_COMPACT_ACTIONS），收藏不挤掉现有按钮。
      androidCompactActionIndices: const [0, 1, 2],
      processingState: buffering == true
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
      bufferedPosition: buffered,
    ));
  }

  /// 构建通知栏控制按钮列表：收藏（custom，图标随收藏态）+ 上一首 + 播放暂停 + 下一首。
  ///
  /// 收藏态变化或播放态变化都经此重发，避免两处逻辑漂移。
  List<MediaControl> _buildControls(bool playing) => [
    // 左侧新增收藏按钮：customAction 驱动，图标随收藏态切换。
    MediaControl.custom(
      androidIcon: _favorite
          ? 'drawable/ic_favorite_filled'
          : 'drawable/ic_favorite_border',
      label: _favorite ? '取消收藏' : '收藏',
      name: 'favorite',
    ),
    MediaControl.skipToPrevious,
    if (playing) MediaControl.pause else MediaControl.play,
    MediaControl.skipToNext,
  ];

  /// 更新收藏状态（通知栏收藏按钮空心/实心切换）。
  void updateFavorite({required bool liked}) {
    if (_favorite == liked) return;
    _favorite = liked;
    // 收藏态变化 → 重发当前播放状态（controls 里的收藏按钮图标随之更新）。
    final playing = playbackState.value.playing;
    playbackState.add(
      playbackState.value.copyWith(controls: _buildControls(playing)),
    );
  }

  /// 更新为停止状态（清空媒体信息）。
  void updateStopped() {
    _lastMediaItem = null;
    _lastStateFingerprint = null;
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    mediaItem.add(null);
  }

  // ── 系统控制回调 ──

  @override
  Future<void> play() async => onPlay?.call();

  @override
  Future<void> pause() async => onPause?.call();

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);

  @override
  Future<void> stop() async => onStop?.call();

  /// 通知栏自定义按钮（收藏）。
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) {
    if (name == 'favorite') return onToggleFavorite?.call() ?? Future.value(null);
    return Future.value(null);
  }
}

/// 播放状态指纹，用于去重
class _PlaybackStateFingerprint {
  final bool playing;
  final int positionMs;
  final bool buffering;

  const _PlaybackStateFingerprint({
    required this.playing,
    required this.positionMs,
    required this.buffering,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _PlaybackStateFingerprint &&
        other.playing == playing &&
        other.positionMs == positionMs &&
        other.buffering == buffering;
  }

  @override
  int get hashCode => Object.hash(playing, positionMs, buffering);
}
