import 'package:flutter/material.dart';

import '../logging/app_log.dart';

/// 播放页叠加层的状态。
///
/// 通过 [Provider] 注入 widget 树，让 [TabNavigator] 的 [NavigatorPopHandler]
/// 能在返回手势时优先关闭播放页而非弹出路由。
class PlayerOverlayState extends ChangeNotifier {
  bool _showPlayer = false;
  VoidCallback? _closeCallback;

  bool get showPlayer => _showPlayer;

  void setCloseCallback(VoidCallback callback) {
    _closeCallback = callback;
  }

  void setShowPlayer(bool value) {
    if (_showPlayer == value) return;
    _showPlayer = value;
    AppLog.debug('setShowPlayer=$value', tag: 'nav');
    notifyListeners();
  }

  void open() {
    if (_showPlayer) return;
    _showPlayer = true;
    AppLog.debug('open', tag: 'nav');
    notifyListeners();
  }

  void close() {
    AppLog.debug('close (showPlayer=$_showPlayer)', tag: 'nav');
    if (!_showPlayer) return;
    _closeCallback?.call();
  }
}
