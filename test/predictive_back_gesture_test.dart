import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/widgets/predictive_back_gesture.dart';

void main() {
  const codec = StandardMethodCodec();

  Future<void> sendBackGesture(
    WidgetTester tester,
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      codec.encodeMethodCall(MethodCall(method, args ?? const {})),
      (_) {},
    );
  }

  Map<String, Object?> swipeArgs(double progress) => {
    'progress': progress,
    'touchOffset': [100.0, 500.0],
    'swipeEdge': 0,
  };

  /// 面板当前 X 轴缩放（只查 [PredictiveBackGesture] 子树，避免命中路由转场的
  /// 其它 Transform）。注意不能用 Transform.getMaxScaleOnAxis()——
  /// Transform.scale 的矩阵是 diagonal3Values(s, s, 1)，z=1 时该函数恒返回 1.0。
  double sheetScaleX(WidgetTester tester) {
    final t = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(PredictiveBackGesture),
            matching: find.byType(Transform),
          )
          .first,
    );
    return t.transform.entry(0, 0);
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: Center(child: Text('home'))),
      ),
    );
    final ctx = tester.element(find.text('home'));
    unawaited(
      showPredictiveBackSheet<void>(
        ctx,
        builder: (_) =>
            const SizedBox(height: 300, child: Center(child: Text('sheet'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);
  }

  testWidgets('预测返回 commit 后弹层以下滑转场关闭', (tester) async {
    await openSheet(tester);

    await sendBackGesture(tester, 'startBackGesture', swipeArgs(0.2));
    await sendBackGesture(tester, 'updateBackGestureProgress', swipeArgs(0.9));
    await tester.pump();

    // 手势预览期间面板等比缩小（scaleTo 0.85 × 进度 0.9 → x 轴 0.865）
    final s = sheetScaleX(tester);
    expect(s < 1.0, isTrue);
    expect(s, closeTo(0.865, 0.001));

    await sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('收缩未完成时 commit：先播完剩余收缩再下收关闭', (tester) async {
    await openSheet(tester);

    // 只拉到一半（scale ≈ 1 - 0.15×0.5 = 0.925）就松手确认
    await sendBackGesture(tester, 'startBackGesture', swipeArgs(0.5));
    await sendBackGesture(tester, 'updateBackGestureProgress', swipeArgs(0.5));
    await tester.pump();
    expect(sheetScaleX(tester), closeTo(0.925, 0.001));

    await sendBackGesture(tester, 'commitBackGesture');
    // 收缩动画（180ms）播完后 pop 才触发下滑关闭。逐步 pump，确认先播完
    // 剩余收缩到 scaleTo（0.85）再下收，而不是以当前 0.925 直接下收。
    var reachedMin = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if ((sheetScaleX(tester) - 0.85).abs() < 0.001) {
        reachedMin = true;
        break;
      }
    }
    expect(reachedMin, isTrue);

    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('预测返回 cancel 后面板保持打开且缩放恢复', (tester) async {
    await openSheet(tester);

    await sendBackGesture(tester, 'startBackGesture', swipeArgs(0.4));
    await sendBackGesture(tester, 'updateBackGestureProgress', swipeArgs(0.8));
    await tester.pump();
    expect(sheetScaleX(tester), closeTo(0.88, 0.001));

    await sendBackGesture(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();

    expect(find.text('sheet'), findsOneWidget);
    expect(sheetScaleX(tester), closeTo(1.0, 0.001));
  });

  testWidgets('返回按钮事件（isButtonEvent）不认领，走普通返回', (tester) async {
    await openSheet(tester);

    // 按钮事件：touchOffset 为 null → isButtonEvent=true，start 不认领；
    // commit 时观察者列表为空 → 框架走普通 pop。
    await sendBackGesture(tester, 'startBackGesture', {
      'progress': 0.0,
      'touchOffset': null,
      'swipeEdge': 0,
    });
    await sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
  });
}
