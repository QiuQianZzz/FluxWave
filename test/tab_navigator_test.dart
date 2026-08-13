import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/pages/tab_navigator.dart';

/// 嵌套导航机制回归：[TabNavigator] 让 tab 内详情不盖住宿主（迷你播放栏/导航
/// 栏）、系统返回转发给 tab 栈、PopScope 拦截被转交给路由、非活动 tab 不抢 back。
void main() {
  testWidgets('tab 内 push 详情不盖住宿主；系统返回弹掉详情', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: TabNavigator(
                  navigatorKey: navKey,
                  enabled: true,
                  child: Builder(
                    builder: (context) => Center(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const Scaffold(
                              body: Center(child: Text('DETAIL')),
                            ),
                          ),
                        ),
                        child: const Text('OPEN'),
                      ),
                    ),
                  ),
                ),
              ),
              // 模拟 tab 外的迷你播放栏/底部导航
              const Text('HOST-UI'),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL'), findsOneWidget);
    // 宿主不被盖住：详情仍保留迷你播放栏可见
    expect(find.text('HOST-UI'), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('DETAIL'), findsNothing);
    expect(find.text('HOST-UI'), findsOneWidget);
  });

  testWidgets('栈顶 PopScope 拦截：back 转交路由自身处理，不弹路由', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabNavigator(
            navigatorKey: navKey,
            enabled: true,
            child: const Placeholder(),
          ),
        ),
      ),
    );

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) closed = true;
          },
          child: const Scaffold(body: Center(child: Text('BLOCKED'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(closed, isTrue, reason: '路由的 onPopInvoked 应被调用（我的页详情态）');
    expect(find.text('BLOCKED'), findsOneWidget, reason: '路由不被弹掉，由回调自理');
  });

  testWidgets('非活动 tab（enabled=false）不接管系统返回', (tester) async {
    final rootNav = GlobalKey<NavigatorState>();
    final inactiveKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNav,
        home: Scaffold(
          body: TabNavigator(
            navigatorKey: inactiveKey,
            enabled: false,
            child: const Placeholder(),
          ),
        ),
      ),
    );

    inactiveKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: Center(child: Text('INACTIVE DETAIL'))),
      ),
    );
    // 根上还有一个全屏页（如登录扫码），back 应弹它而不是非活动 tab 的详情
    rootNav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('ROOT PAGE'))),
      ),
    );
    await tester.pumpAndSettle();

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('ROOT PAGE'), findsNothing, reason: '根页面被弹走');
    expect(
      find.text('INACTIVE DETAIL', skipOffstage: false),
      findsOneWidget,
      reason: '非活动 tab 详情不被弹（enabled=false 拦住）',
    );
  });

  testWidgets('切 tab 再切回：enabled 恢复后系统返回仍弹 tab 内详情', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    var enabled = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return TabNavigator(
                navigatorKey: navKey,
                enabled: enabled,
                child: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(
                            body: Center(child: Text('DETAIL')),
                          ),
                        ),
                      ),
                      child: const Text('OPEN'),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    // 打开详情
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL'), findsOneWidget);

    // 模拟切到其他 tab（enabled=false），再切回（enabled=true）
    enabled = false;
    await tester.pump();
    enabled = true;
    await tester.pumpAndSettle();

    // 系统返回应弹掉详情，而不是退出应用
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(
      find.text('DETAIL'),
      findsNothing,
      reason: '切 tab 再切回后，系统返回应弹掉 tab 内详情',
    );
  });

  testWidgets('多 tab Offstage 常驻：切回后系统返回仍弹 tab 内详情', (tester) async {
    final tabAKey = GlobalKey<NavigatorState>();
    final tabBKey = GlobalKey<NavigatorState>();
    var current = 0;

    Widget buildTabA() => TabNavigator(
          navigatorKey: tabAKey,
          enabled: current == 0,
          child: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: Center(child: Text('DETAIL-A'))),
                  ),
                ),
                child: const Text('OPEN-A'),
              ),
            ),
          ),
        );

    Widget buildTabB() => TabNavigator(
          navigatorKey: tabBKey,
          enabled: current == 1,
          child: const Center(child: Text('TAB-B')),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(offstage: current != 0, child: buildTabA()),
                  Offstage(offstage: current != 1, child: buildTabB()),
                ],
              );
            },
          ),
        ),
      ),
    );

    // 在 tab A 打开详情
    await tester.tap(find.text('OPEN-A'));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL-A'), findsOneWidget);

    // 切到 tab B（current=1）
    current = 1;
    await tester.pumpAndSettle();
    // tab A 变为 offstage，但其 Navigator 栈仍保留 DETAIL-A
    expect(find.text('DETAIL-A', skipOffstage: false), findsOneWidget);

    // 切回 tab A（current=0）
    current = 0;
    await tester.pumpAndSettle();
    expect(find.text('DETAIL-A'), findsOneWidget);

    // 系统返回应弹掉 tab A 的详情，而不是退出应用
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(
      find.text('DETAIL-A'),
      findsNothing,
      reason: '多 tab Offstage 常驻，切回后系统返回应弹掉 tab 内详情',
    );
  });

  testWidgets('tab A 返回弹子页不应连累 tab B 的子页', (tester) async {
    final keyA = GlobalKey<NavigatorState>();
    final keyB = GlobalKey<NavigatorState>();
    var current = 0;
    StateSetter? setTabs;

    Widget tab(GlobalKey<NavigatorState> key, String root, String sub, int idx) {
      return TabNavigator(
        navigatorKey: key,
        enabled: current == idx,
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(body: Center(child: Text(sub))),
                ),
              ),
              child: Text(root),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setTabs = setState;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: current != 0,
                    child: Transform.translate(
                      offset: Offset.zero,
                      child: tab(keyA, 'A-ROOT', 'A-SUB', 0),
                    ),
                  ),
                  Offstage(
                    offstage: current != 1,
                    child: Transform.translate(
                      offset: Offset.zero,
                      child: tab(keyB, 'B-ROOT', 'B-SUB', 1),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    void switchTab(int idx) {
      setTabs!(() => current = idx);
    }

    // A 打开子页
    await tester.tap(find.text('A-ROOT'));
    await tester.pumpAndSettle();
    expect(find.text('A-SUB'), findsOneWidget);

    // 切到 B，B 打开子页
    switchTab(1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('B-ROOT'));
    await tester.pumpAndSettle();
    expect(find.text('B-SUB'), findsOneWidget);

    // 切回 A，系统返回弹掉 A 的子页
    switchTab(0);
    await tester.pumpAndSettle();
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('A-SUB'), findsNothing);

    // 切回 B：B 的子页应保留
    switchTab(1);
    await tester.pumpAndSettle();
    expect(
      find.text('B-SUB', skipOffstage: false),
      findsOneWidget,
      reason: 'A 返回弹子页不应连累 B 的子页',
    );
  });
}
