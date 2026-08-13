import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证首页封面卡片结构在有限约束下不会被 SizedBox.square(∞) 撑爆：
/// `Column > Expanded > SizedBox.square(dimension: double.infinity)`
/// 的布局结果必须是有限尺寸、无异常（等价于 SizedBox.expand，父约束会夹紧 ∞）。
void main() {
  testWidgets('Expanded 内 SizedBox.square(∞) 尺寸有限、无溢出', (tester) async {
    // 复刻首页卡片：网格格内 Column(CrossAxisAlignment.start) + Expanded 封面区
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 260, // 模拟 0.82 网格格的有限高度
              child: Material(
                color: Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SizedBox.square(
                        dimension: double.infinity,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: const ColoredBox(
                            key: Key('cover-fill'),
                            color: Colors.red,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('歌单名'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final coverSize = tester.getSize(find.byKey(const Key('cover-fill')));
    expect(coverSize.width.isFinite, isTrue, reason: '封面宽必须有限');
    expect(coverSize.height.isFinite, isTrue, reason: '封面高必须有限');
    expect(coverSize.width, moreOrLessEquals(200, epsilon: 0.1));
    // 高度取 Expanded 分到的剩余空间（< 260 且留出文字行高度）
    expect(coverSize.height, greaterThan(0));
    expect(coverSize.height, lessThan(260));
  });
}
