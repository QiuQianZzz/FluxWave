import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/navigation/player_overlay_state.dart';
import '../../pages/tab_navigator.dart';
import '../../widgets/predictive_back_gesture.dart';

/// 统一导航入口。
///
/// - [push]：在「就近」Navigator 上 push。tab 内容页（歌单详情、雷达页等）
///   默认落在该 tab 的嵌套 Navigator 上，迷你播放栏与导航栏保持可见。
///   当播放页打开时，[TabAwarePageRoute.popGestureEnabled] 返回 false，
///   预测性返回手势不认领路由，由 [NavigatorPopHandler] 关闭播放页。
/// - [pushGlobal]：始终落在根 Navigator（全屏覆盖），
///   用于登录扫码、全屏播放器等整页路由。
abstract final class AppNav {
  static Future<T?> push<T>(BuildContext context, Widget page) {
    return Navigator.of(context).push<T>(_route<T>(context, page));
  }

  static Future<T?> pushGlobal<T>(BuildContext context, Widget page) {
    return Navigator.of(context, rootNavigator: true).push<T>(_route<T>(context, page));
  }

  static Future<T?> pushNamedGlobal<T>(BuildContext context, String name) {
    return Navigator.of(context, rootNavigator: true).pushNamed<T>(name);
  }

  static Route<T> _route<T>(BuildContext context, Widget page) {
    return TabAwarePageRoute<T>(builder: (_) => page);
  }
}

/// 感知 tab 活跃状态 + 播放页状态的页面路由。
///
/// Flutter 的预测性返回手势（[PredictiveBackPageTransitionsBuilder] 里的
/// `_PredictiveBackGestureDetector`）会对每个 `isCurrent && popGestureEnabled`
/// 的路由认领手势，commit 时调用 `navigator.maybePop()`。
///
/// 这里覆盖 [popGestureEnabled]：
/// - 播放页打开时 → 返回 false，手势不被路由认领，转交 [NavigatorPopHandler]
///   关闭播放页。
/// - 非活跃 tab 的子页 → 返回 false，避免跨 tab 误弹。
/// - 其余情况 → 正常允许。
class TabAwarePageRoute<T> extends MaterialPageRoute<T> {
  TabAwarePageRoute({required super.builder, super.settings});

  @override
  bool get popGestureEnabled {
    if (PredictiveBackGesture.hasActiveSheet) return false;
    final ctx = subtreeContext;
    if (ctx != null) {
      final tab = ctx.findAncestorWidgetOfExactType<TabNavigator>();
      if (tab != null && !tab.enabled) return false;
      try {
        final playerOverlay = Provider.of<PlayerOverlayState>(ctx, listen: false);
        if (playerOverlay.showPlayer) return false;
      } catch (_) {
        AppLog.debug('popGestureEnabled Provider lookup failed', tag: 'nav');
      }
    } else {
      AppLog.debug('popGestureEnabled subtreeContext=null', tag: 'nav');
    }
    return super.popGestureEnabled;
  }
}
