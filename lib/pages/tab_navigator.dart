import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/logging/app_log.dart';
import '../core/navigation/app_nav.dart';
import '../core/navigation/player_overlay_state.dart';

/// 单个 tab 的独立导航栈。
///
/// 把 tab 页面包进专属 [Navigator]：tab 内 push（歌单详情/雷达页等）只覆盖本
/// tab 区域，迷你播放栏与导航栏保持可见。同时注册 [PopScope] 把系统返回转发
/// 给本栈——
///
/// - 播放页打开时 → 关闭播放页（优先于路由 pop）
/// - 栈可 pop（有详情路由）→ 弹掉栈顶路由；
/// - 栈空且无拦截 → 放行给根 Navigator（等价退出应用）。
///
/// [enabled] 表示是否是当前活动 tab。
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
  late final List<NavigatorObserver> _observers =
      [if (widget.observer != null) widget.observer!];

  /// 镜像嵌套 Navigator 的栈深状态：栈内只有 1 个路由时为 true（可 pop），
  /// 2+ 路由时为 false（不可 pop）。由 [NotificationListener] 监听更新。
  bool _canPop = true;

  void _onPop() {
    if (!widget.enabled) return;
    final playerOverlay = context.read<PlayerOverlayState>();
    AppLog.debug('_onPop showPlayer=${playerOverlay.showPlayer}', tag: 'nav');
    if (playerOverlay.showPlayer) {
      playerOverlay.close();
      return;
    }
    widget.navigatorKey.currentState?.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final playerOverlay = context.watch<PlayerOverlayState>();
    return PopScope<void>(
      // 优先级：非活动 tab 放行 > 播放页打开拦截 > 栈深决定。
      canPop: !widget.enabled ? true : (playerOverlay.showPlayer ? false : _canPop),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onPop();
      },
      child: NotificationListener<NavigationNotification>(
        onNotification: (notification) {
          final nextCanPop = !notification.canHandlePop;
          if (nextCanPop != _canPop) {
            setState(() => _canPop = nextCanPop);
          }
          return false;
        },
        child: Navigator(
          key: widget.navigatorKey,
          observers: _observers,
          onGenerateRoute: (settings) {
            if (settings.name != Navigator.defaultRouteName) {
              throw UnsupportedError(
                'tab 内不支持命名路由 "${settings.name}"，请用 AppNav.pushNamedGlobal',
              );
            }
            return TabAwarePageRoute<void>(
              settings: settings,
              builder: (_) => widget.child,
            );
          },
        ),
      ),
    );
  }
}
