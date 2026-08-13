import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/player_provider.dart';
import 'title_bar.dart';

/// 退出 / 退后台前的持久化兜底。
///
/// - **桌面端**：拦截窗口关闭，`await` 落盘完成后再真正关闭，避免进程先于
///   异步写盘被拆除导致最后一段进度丢失；
/// - **移动端**：AppLifecycle 进入后台 / 销毁前立即落盘（退出同样会经过
///   后台状态，因此一并覆盖）。
///
/// 必须在 [PlayerProvider] 的 MultiProvider 之下使用。
///
/// 仅当 [TitleBar.enabled]（window_manager 初始化成功）才注册关闭拦截，
/// 测试 / 初始化失败场景自动跳过，不影响正常运行。
class PlayerPersistenceGuard extends StatefulWidget {
  final Widget child;

  const PlayerPersistenceGuard({super.key, required this.child});

  @override
  State<PlayerPersistenceGuard> createState() => _PlayerPersistenceGuardState();
}

class _PlayerPersistenceGuardState extends State<PlayerPersistenceGuard>
    with WindowListener {
  late final PlayerProvider _player;
  AppLifecycleListener? _lifecycle;

  /// 紧急落盘去重窗口：合并 destroy→detached 或连续生命周期事件的重复写。
  /// 去重只作用于「兜底落盘」调用，正常使用（长时间后进后台）不受影响，
  /// 因此保留「状态组每次必写」的兜底语义，仅避免紧邻的重复写盘。
  static const Duration _flushDedup = Duration(milliseconds: 300);
  bool _flushRunning = false;
  DateTime? _lastFlushAt;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _player = context.read<PlayerProvider>();
    if (_isDesktop && TitleBar.enabled) {
      try {
        windowManager.setPreventClose(true);
        windowManager.addListener(this);
      } catch (_) {
        // window_manager 不可用：回退到 dispose 兜底
      }
    }
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  /// 紧急落盘：上一次写盘完成不足 [_flushDedup] 时跳过（已覆盖），
  /// 已有写盘在进行时合并，避免并发重复写。
  Future<void> _flush() async {
    final now = DateTime.now();
    if (_flushRunning ||
        (_lastFlushAt != null && now.difference(_lastFlushAt!) < _flushDedup)) {
      return;
    }
    _flushRunning = true;
    try {
      await _player.persistNow();
    } finally {
      _flushRunning = false;
      _lastFlushAt = DateTime.now();
    }
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // 移动端退后台/销毁：立即落盘（fire-and-forget，进程仍有宽限期完成写盘）
      unawaited(_flush());
    }
  }

  @override
  void onWindowClose() async {
    // 落盘后再关闭窗口。main.cpp 在消息循环退出后会 ExitProcess 强制退出
    // 进程，跳过 native 析构（避免 just_audio_windows 的 MediaPlayer COM
    // 释放阻塞 5s），因此必须在此处完成落盘。
    try {
      await _flush().timeout(const Duration(seconds: 1), onTimeout: () {});
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    if (_isDesktop && TitleBar.enabled) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
