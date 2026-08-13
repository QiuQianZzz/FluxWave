import 'package:flutter/material.dart';

import '../../pages/tab_navigator.dart';

/// 统一导航入口。
///
/// - [push]：在「就近」Navigator 上 push。tab 内容页（歌单详情、雷达页等）
///   默认落在该 tab 的嵌套 Navigator 上，迷你播放栏与导航栏保持可见。
/// - [pushGlobal]/[pushNamedGlobal]：始终落在根 Navigator（全屏覆盖），
///   用于登录扫码、全屏播放器等整页路由。
///
/// 未来接入自定义预测性返回手势/更换过渡动画时，只改 [_route]（或
/// main_scaffold 的 back 协调层）一处即可全局生效。
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

  static Route<T> _route<T>(Widget page) =>
      TabAwarePageRoute<T>(builder: (_) => page);
}

/// 感知 tab 活跃状态的页面路由。
///
/// Flutter 的预测性返回手势（[PredictiveBackPageTransitionsBuilder] 里的
/// `_PredictiveBackGestureDetector`）会对每个 `isCurrent && popGestureEnabled`
/// 的路由认领手势，commit 时全部 pop。多 tab 场景下，非活跃 tab 的子页路由
/// 同样满足这两个条件，导致「在 tab A 上预测性返回弹 A 的子页时，B 的子页也
/// 被一起弹掉」。
///
/// 这里覆盖 [popGestureEnabled]：当页面所在 [TabNavigator] 非活跃（enabled=false）
/// 时返回 false，使该路由不认领预测性返回手势。返回按钮走 [PopScope]/
/// [NavigatorPopHandler]，不受影响。
class TabAwarePageRoute<T> extends MaterialPageRoute<T> {
  TabAwarePageRoute({required super.builder, super.settings});

  @override
  bool get popGestureEnabled {
    final ctx = subtreeContext;
    if (ctx != null) {
      final tab = ctx.findAncestorWidgetOfExactType<TabNavigator>();
      // 非活跃 tab（Offstage 常驻）的子页不应认领预测性返回手势。
      if (tab != null && !tab.enabled) return false;
    }
    return super.popGestureEnabled;
  }
}
