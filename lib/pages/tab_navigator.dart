import 'package:flutter/material.dart';

/// 单个 tab 的独立导航栈。
///
/// 把 tab 页面包进专属 [Navigator]：tab 内 push（歌单详情/雷达页等）只覆盖本
/// tab 区域，迷你播放栏与导航栏保持可见。同时注册 [NavigatorPopHandler] 把
/// 系统返回转发给本栈——
///
/// - 栈可 pop（有详情路由）→ 弹掉栈顶路由；
/// - 栈顶路由被 PopScope 拦截（如「我的」页详情态）→ 转交路由自身处理；
/// - 栈空且无拦截 → 放行给根 Navigator（等价退出应用）。
///
/// [enabled] 表示是否是当前活动 tab。非活动 tab 经 Offstage 常驻时会同样常驻
/// 根路由的 PopScope 注册，必须关掉以免抢走系统返回（框架按声明顺序结算）。
class TabNavigator extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final bool enabled;
  final NavigatorObserver? observer;

  const TabNavigator({
    super.key,
    required this.navigatorKey,
    required this.child,
    required this.enabled,
    this.observer,
  });

  @override
  State<TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<TabNavigator> {
  @override
  Widget build(BuildContext context) {
    return NavigatorPopHandler<void>(
      enabled: widget.enabled,
      onPopWithResult: (_) {
        if (!widget.enabled) return;
        widget.navigatorKey.currentState?.maybePop();
      },
      child: Navigator(
        key: widget.navigatorKey,
        observers: [if (widget.observer != null) widget.observer!],
        onGenerateRoute: (settings) {
          // tab 内不支持命名路由；全屏/全局页一律走 AppNav.pushNamedGlobal。
          if (settings.name != Navigator.defaultRouteName) {
            throw UnsupportedError(
              'tab 内不支持命名路由 "${settings.name}"，请用 AppNav.pushNamedGlobal',
            );
          }
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => widget.child,
          );
        },
      ),
    );
  }
}
