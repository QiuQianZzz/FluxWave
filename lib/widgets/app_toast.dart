import 'dart:async';

import 'package:flutter/material.dart';

/// 轻量全局提示，基于 ValueNotifier 驱动。
///
/// 在 MainScaffold 的 Stack 顶层渲染，不依赖 Overlay（Overlay 在 Windows
/// 端可能因层级/动画时序导致不可见）。双端统一从顶部滑入，3s 自动消失。
///
/// 同一时间只显示一条，新提示替换旧提示。
class AppToast {
  AppToast._();

  /// 当前待显示的消息（null = 隐藏）。MainScaffold 的 ValueListenableBuilder 监听。
  static final ValueNotifier<String?> message = ValueNotifier(null);

  static Timer? _timer;

  /// 显示 [message]，3s 后自动消失。context 仅用于后续可能的路由判断，
  /// 当前实现不依赖它。
  static void show(BuildContext context, String msg) {
    _timer?.cancel();
    _timer = null;
    message.value = msg;
    _timer = Timer(const Duration(milliseconds: 3000), () {
      message.value = null;
      _timer = null;
    });
  }
}
