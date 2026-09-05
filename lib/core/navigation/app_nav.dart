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
///   播放页打开时，[TabAwarePageRoute.popGestureEnabled] 返回 false，
///   预测性返回手势不认领路由，由 [TabNavigator] 的 [PopScope] 关闭播放页。
/// - [pushGlobal]：始终落在根 Navigator（全屏覆盖），
///   用于登录扫码、全屏播放器等整页路由。
/// - [route]：创建 [TabAwarePageRoute]，供直接操作 NavigatorState 时使用
///   （如 MainScaffold 中通过 tabNav.push 添加路由）。
abstract final class AppNav {
  static Future<T?> push<T>(BuildContext context, Widget page) {
    return Navigator.of(context).push<T>(_route<T>(page));
  }

  static Future<T?> pushGlobal<T>(BuildContext context, Widget page) {
    return Navigator.of(context, rootNavigator: true).push<T>(_route<T>(page));
  }

  static Future<T?> pushNamedGlobal<T>(BuildContext context, String name) {
    return Navigator.of(context, rootNavigator: true).pushNamed<T>(name);
  }

  static TabAwarePageRoute<T> route<T>(Widget page, {RouteSettings? settings}) =>
      TabAwarePageRoute<T>(builder: (_) => page, settings: settings);

  static Route<T> _route<T>(Widget page) =>
      TabAwarePageRoute<T>(builder: (_) => page);
}

/// 感知 tab 活跃状态 + 播放页状态的页面路由。
///
/// Flutter 的预测性返回手势（[PredictiveBackPageTransitionsBuilder] 里的
/// `_PredictiveBackGestureDetector`）会对每个 `isCurrent && popGestureEnabled`
/// 的路由认领手势，commit 时直接调用 `navigator.maybePop()`（不经过
/// [PopScope]）。因此播放页打开时必须在此处返回 false，阻止路由认领手势，
/// 让返回事件冒泡到 [TabNavigator] 的 [PopScope] 统一处理。
///
/// 这里覆盖 [popGestureEnabled]：
/// - 播放页打开时 → 返回 false。
/// - 非活跃 tab 的子页 → 返回 false，避免跨 tab 误弹。
/// - subtreeContext 不可用或 Provider 查找失败 → 保守返回 false。
/// - 其余情况 → 正常允许。
class TabAwarePageRoute<T> extends MaterialPageRoute<T> {
  TabAwarePageRoute({required super.builder, super.settings});

  @override
  bool get popGestureEnabled {
    if (PredictiveBackGesture.hasActiveSheet) return false;
    final ctx = subtreeContext;
    if (ctx == null) return false;
    final tab = ctx.findAncestorWidgetOfExactType<TabNavigator>();
    if (tab != null) {
      // Tab 内路由：受播放页状态约束
      if (!tab.enabled) return false;
      try {
        final playerOverlay = ctx.read<PlayerOverlayState>();
        if (playerOverlay.showPlayer) return false;
      } catch (_) {
        AppLog.debug('popGestureEnabled Provider lookup failed', tag: 'nav');
        return false;
      }
    }
    // 非 tab 路由（pushGlobal 的登录页等）：不受播放页影响，正常允许预测性返回
    return super.popGestureEnabled;
  }
}
