import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../models/song.dart';

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

  /// 设置当前媒体信息（歌曲标题、歌手、封面、时长）。
  ///
  /// 内部去重：相同的媒体信息不会重复发送。
  void setMediaItem(Song song, {String? coverUrl}) {
    final item = MediaItem(
      id: '${song.source}_${song.id}',
      title: song.name,
      artist: song.artists.isNotEmpty ? song.artists.join(' / ') : null,
      album: song.albumName,
      duration: Duration(milliseconds: song.durationMs),
      artUri: coverUrl != null ? Uri.tryParse(coverUrl) : null,
    );

    // 去重：相同的歌曲信息不重复更新
    if (_lastMediaItem != null &&
        _lastMediaItem!.id == item.id &&
        _lastMediaItem!.title == item.title &&
        _lastMediaItem!.artUri == item.artUri) {
      return;
    }

    _lastMediaItem = item;
    mediaItem.add(item);
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
