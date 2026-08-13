import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import '../permissions/notification_permission.dart';
import '../platform_utils.dart';
import 'app_audio_handler.dart';

/// 媒体会话管理器：负责初始化 [AudioService] 并持有 [AppAudioHandler] 实例。
///
/// 使用方式：
/// ```dart
/// // 应用启动时初始化
/// await MediaSessionManager.instance.init(
///   onPlay: () => playerProvider.play(),
///   onPause: () => playerProvider.pause(),
///   onNext: () => playerProvider.next(),
///   onPrevious: () => playerProvider.previous(),
///   onSeek: (pos) => playerProvider.seek(pos),
/// );
///
/// // 播放状态变化时更新
/// MediaSessionManager.instance.updateMediaItem(song, coverUrl: url);
/// MediaSessionManager.instance.updatePlaybackState(playing: true, position: pos);
/// ```
class MediaSessionManager {
  MediaSessionManager._();
  static final MediaSessionManager instance = MediaSessionManager._();

  AppAudioHandler? _handler;
  bool _initialized = false;

  /// 是否已初始化。
  bool get isInitialized => _initialized;

  /// 当前的 handler（未初始化时为 null）。
  AppAudioHandler? get handler => _handler;

  /// 初始化媒体会话。
  ///
  /// 在应用启动时调用一次。仅 Android/iOS 生效；桌面平台跳过。
  Future<void> init({
    VoidCallback? onPlay,
    VoidCallback? onPause,
    VoidCallback? onNext,
    VoidCallback? onPrevious,
    void Function(Duration position)? onSeek,
    VoidCallback? onStop,
    Future<void> Function()? onToggleFavorite,
  }) async {
    if (_initialized) return;

    // 桌面平台不需要媒体通知
    if (PlatformUtils.isDesktop) {
      _initialized = true;
      return;
    }

    // Android 13+ 需要运行时申请通知权限
    if (PlatformUtils.isAndroid) {
      final granted = await NotificationPermission.requestIfNeeded();
      debugPrint('[MediaSession] 通知权限申请结果: $granted');
      // 即使权限未授予也继续初始化，用户可以在设置里手动开启
    }

    try {
      _handler = await AudioService.init<AppAudioHandler>(
        builder: () => AppAudioHandler(
          onPlay: onPlay,
          onPause: onPause,
          onNext: onNext,
          onPrevious: onPrevious,
          onSeek: onSeek,
          onStop: onStop,
          onToggleFavorite: onToggleFavorite,
        ),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.qiuqianzzz.fluxwave.media',
          androidNotificationChannelName: 'FluxWave 播放控制',
          androidNotificationChannelDescription:
              '显示当前播放歌曲信息及播放控制',
          // 暂停时保留前台服务与通知，方便从通知栏恢复播放
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'mipmap/ic_launcher',
          fastForwardInterval: Duration(seconds: 10),
          rewindInterval: Duration(seconds: 10),
        ),
      );
      _initialized = true;
      debugPrint('[MediaSession] 初始化成功');
    } catch (e) {
      debugPrint('[MediaSession] 初始化失败: $e');
      _initialized = true; // 标记已尝试，避免重复初始化
    }
  }

  /// 更新当前媒体信息。
  void updateMediaItem(Song song, {String? coverUrl}) {
    _handler?.setMediaItem(song, coverUrl: coverUrl);
  }

  /// 更新播放状态。
  void updatePlaybackState({
    required bool playing,
    Duration? position,
    Duration? buffered,
    bool? buffering,
  }) {
    _handler?.updatePlaybackState(
      playing: playing,
      position: position ?? Duration.zero,
      buffered: buffered ?? Duration.zero,
      buffering: buffering,
    );
  }

  /// 更新为停止状态。
  void updateStopped() {
    _handler?.updateStopped();
  }

  /// 更新当前歌曲收藏态（通知栏收藏按钮空心/实心切换）。
  void updateFavorite({required bool liked}) {
    _handler?.updateFavorite(liked: liked);
  }
}
