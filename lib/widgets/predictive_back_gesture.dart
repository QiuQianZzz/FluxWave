import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

/// 让底部弹层（PopupRoute/DialogRoute）响应 Android 预测性返回手势，并跟随
/// 系统边缘 back 手势做"整体等比缩小"预览（宽高同缩、原比例不变、内容不压扁）。
///
/// Flutter 的预测性返回动画只内置在 PageRoute（`PredictiveBackPageTransitionsBuilder`
/// 里的 `_PredictiveBackGestureDetector`）；`showModalBottomSheet` 生成的 PopupRoute
/// 没人认领系统 back 手势，所以默认只有普通返回（无预览）。Compose 的
/// ModalBottomSheet 是组件内部用 PredictiveBackHandler 自己驱动——本组件同理。
///
/// 用法：把这个组件包在任意底部面板外层，配合一个"pop 时下滑关闭"的转场即可。
/// 直接 [showPredictiveBackSheet] 可开箱即用。
///
/// 行为：
///  * 仅当 [enabled] 为 true 时才认领手势；关时退回系统普通返回（无预览动画）；
///  * [handleStartBackGesture] 认领手势（仅边缘滑动，返回按钮不参与）；
///  * [handleUpdateBackGestureProgress] 直接驱动缩放跟随系统手势进度；
///  * [handleCommitBackGesture] 确认返回 → 先播完剩余收缩动画，再由外层路由的
///    下滑转场关闭（面板以收缩后的宽度下滑，保持最小收缩量）；
///  * [handleCancelBackGesture] 取消 → 缩放平滑恢复原尺寸、面板保持打开。
///
/// 前提：AndroidManifest 中 `enableOnBackInvokedCallback=true`（已配置），
/// 否则系统不会发送预测性手势事件。
class PredictiveBackGesture extends StatefulWidget {
  const PredictiveBackGesture({
    super.key,
    required this.child,
    this.scaleTo = 0.85,
    this.alignment = Alignment.bottomCenter,
    this.enabled = true,
    this.onDismiss,
  }) : assert(scaleTo > 0 && scaleTo <= 1, 'scaleTo 必须为 (0, 1] 内的比例');

  /// 当前是否有 [showPredictiveBackSheet] 弹层活跃。
  /// PageRoute 可据此禁用自身的 `popGestureEnabled`，避免与弹层同时认领手势。
  static bool get hasActiveSheet => _activeSheetCount > 0;
  static int _activeSheetCount = 0;

  /// 被预览缩放的面板内容（应包含背景/圆角/阴影的整块，勿只包内部列表）。
  final Widget child;

  /// 收缩后尺寸占展开的比例（1=不缩，0.85=缩 15%）。
  final double scaleTo;

  /// 缩放锚点。底部弹层用 [Alignment.bottomCenter]（底部不动，向顶部收拢）。
  final Alignment alignment;

  /// 是否启用预测性返回动画（与设置里的"预测性返回"开关对齐）；关时
  /// 不认领系统 back 手势，退回普通返回。
  final bool enabled;

  /// 拖拽关闭回调。非 null 时启用向下拖拽关闭手势。
  final VoidCallback? onDismiss;

  @override
  State<PredictiveBackGesture> createState() => _PredictiveBackGestureState();
}

class _PredictiveBackGestureState extends State<PredictiveBackGesture>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  ModalRoute<dynamic>? _route;

  /// 手势缩放量（0=原始尺寸，1=完全收拢），由系统 back 手势 progress 直接驱动。
  late final AnimationController _shrink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// commit 时一次性播完剩余收缩的速度：要快，收紧后立即下收，
  /// 避免用户觉得停顿。
  static const Duration _shrinkFillDuration = Duration(milliseconds: 80);
  static const Curve _shrinkFillCurve = Curves.easeOutCubic;

  // ── 拖拽关闭 ──
  final _dragNotifier = ValueNotifier<double>(0);
  bool _dismissing = false;

  /// 手势可被认领的条件：本弹层是最上层路由。
  /// 注意：不检查 [ModalRoute.popGestureEnabled]，因为手势认领通过
  /// [PredictiveBackHandler] mixin 在组件层面完成，而非路由层面。
  /// 自定义 [_PredictiveBackSheetRoute] 设置 popGestureEnabled=false
  /// 以阻止路由自身认领预测性返回，避免与底层 PageRoute 冲突。
  bool get _isEnabled => _route?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute.of 依赖 _ModalScopeStatus，必须在 initState 之后（didChangeDependencies）获取。
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shrink.dispose();
    _dragNotifier.dispose();
    _dismissing = false;
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 返回按钮（isButtonEvent）或本弹层非最上层路由时，
    // 不认领手势，退回系统普通返回（无预览动画）。
    return widget.enabled && !backEvent.isButtonEvent && _isEnabled;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    // 跟手：直接写 controller.value 驱动缩放预览（不触碰 route 动画）。
    _shrink.value = backEvent.progress.clamp(0.0, 1.0);
  }

  @override
  void handleCommitBackGesture() {
    // 确认返回：先快速播完剩余收缩动画（到最小收缩量），再触发下滑关闭；
    // 否则在收缩未完成时松手会以当前大小直接下收。
    final route = _route;
    if (route == null || !route.isCurrent) return;
    _shrink
        .animateTo(1, duration: _shrinkFillDuration, curve: _shrinkFillCurve)
        .whenCompleteOrCancel(() {
          // 仅在仍是最上层路由时弹出，避免并发关闭路径误弹下层页面。
          if (!mounted || route.navigator == null) return;
          route.navigator?.pop();
        });
  }

  @override
  void handleCancelBackGesture() {
    // 取消：缩放平滑恢复原尺寸，面板保持打开。
    _shrink.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final child = AnimatedBuilder(
      animation: _shrink,
      builder: (context, child) {
        final p = _shrink.value;
        final s = 1.0 - (1.0 - widget.scaleTo) * p;
        return Transform.scale(
          scale: s,
          alignment: widget.alignment,
          child: child,
        );
      },
      child: widget.child,
    );

    if (widget.onDismiss == null) return child;

    return GestureDetector(
      onVerticalDragStart: (_) {
        if (_shrink.isAnimating || _dismissing) return;
        _dragNotifier.value = 0;
      },
      onVerticalDragUpdate: (details) {
        if (_dismissing) return;
        if (details.primaryDelta != null) {
          final next = _dragNotifier.value + details.primaryDelta!;
          _dragNotifier.value = next > 0 ? next : 0;
        }
      },
      onVerticalDragEnd: (details) {
        if (_dismissing) return;
        final v = details.primaryVelocity ?? 0;
        if (_dragNotifier.value > 80 || v > 800) {
          _dismissing = true;
          widget.onDismiss?.call();
          // 微任务后检查：若 route 仍在（pop 失败），重置 flag 允许重试。
          Future.microtask(() {
            if (mounted && _dismissing) {
              _dismissing = false;
              _dragNotifier.value = 0;
            }
          });
          return;
        }
        _dragNotifier.value = 0;
      },
      onVerticalDragCancel: () {
        if (_dismissing) return;
        _dragNotifier.value = 0;
      },
      child: ValueListenableBuilder<double>(
        valueListenable: _dragNotifier,
        builder: (context, offset, child) {
          return Transform.translate(
            offset: Offset(0, offset),
            child: child,
          );
        },
        child: child,
      ),
    );
  }
}

/// 弹出带预测性返回的底部面板（开箱即用）。
///
/// 使用自定义 [_PredictiveBackSheetRoute]（popGestureEnabled=false）阻止
/// 路由层面认领预测性返回手势，仅由 [PredictiveBackGesture] 组件通过
/// [PredictiveBackHandler] mixin 独占手势，避免底层 PageRoute 同时 pop。
/// 打开/关闭为纯底部滑入/滑出（无缩放），预测性返回预览由
/// [PredictiveBackGesture] 缩放到位时"整体等比缩小 + 底部锚定"，松手
/// 确认后才以下滑动画关闭。
/// [enabled] 为 false 时不做预测性返回预览（退回普通返回），用于对齐设置开关。
Future<T?> showPredictiveBackSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Color? barrierColor,
  Color? backgroundColor,
  ShapeBorder? shape,
  double scaleTo = 0.85,
  bool barrierDismissible = true,
  String? barrierLabel,
  bool enabled = true,
}) {
  PredictiveBackGesture._activeSheetCount++;
  final route = _PredictiveBackSheetRoute<T>(
    builder: builder,
    barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.32),
    barrierLabel: barrierLabel ?? '关闭',
    backgroundColor: backgroundColor,
    shape: shape,
    scaleTo: scaleTo,
    enabled: enabled,
    barrierDismissible: barrierDismissible,
  );
  final result = Navigator.of(context).push<T>(route);
  result.whenComplete(() => PredictiveBackGesture._activeSheetCount--);
  return result;
}

/// 自定义 PopupRoute：popGestureEnabled=false 阻止路由层面认领预测性返回，
/// 仅由 [PredictiveBackGesture] 组件通过 [PredictiveBackHandler] 独占。
///
/// 同时暴露 [activeSheetCount] 静态计数器：有 sheet 活跃时底层 PageRoute
/// 可据此禁用自身的 `popGestureEnabled`，避免两个路由同时认领手势。
class _PredictiveBackSheetRoute<T> extends PopupRoute<T> {
  _PredictiveBackSheetRoute({
    required this.builder,
    required this._barrierColor,
    required this._barrierLabel,
    this.backgroundColor,
    this.shape,
    this.scaleTo = 0.85,
    this.enabled = true,
    this.barrierDismissible = true,
  });

  final WidgetBuilder builder;
  final Color? backgroundColor;
  final ShapeBorder? shape;
  final double scaleTo;
  final bool enabled;
  final Color _barrierColor;
  final String _barrierLabel;
  @override
  final bool barrierDismissible;

  @override
  Color? get barrierColor => _barrierColor;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  /// 关键：阻止路由自身认领预测性返回手势，仅由 PredictiveBackGesture 组件独占。
  @override
  bool get popGestureEnabled => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // Stack + Positioned 让内容自适应高度（对齐 showModalBottomSheet 的行为）。
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              ),
              child: ColoredBox(
                color: _barrierColor,
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: PredictiveBackGesture(
            scaleTo: scaleTo,
            enabled: enabled,
            onDismiss: () {
              final route = ModalRoute.of(context);
              if (route?.isCurrent == true) {
                Navigator.of(context).pop();
              }
            },
            child: Material(
              color: backgroundColor ?? Theme.of(context).colorScheme.surface,
              shape:
                  shape ??
                  const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
              clipBehavior: Clip.antiAlias,
              child: builder(context),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
      child: child,
    );
  }
}
