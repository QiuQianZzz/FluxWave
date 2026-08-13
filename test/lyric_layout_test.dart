import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/lyric_model.dart';
import 'package:fluxwave/widgets/lyric/lyric_layout.dart';

/// 布局模块纯函数测试：换行、度量、动画判定、静态排版。
void main() {
  const style = TextStyle(fontSize: 18, fontWeight: FontWeight.bold);

  group('resolveSyllables', () {
    test('YRC 行直接用 words', () {
      const line = LyricLine(
        text: '难以',
        startTimeMs: 0,
        endTimeMs: 1000,
        words: [
          LyricWord(text: '难', startTimeMs: 0, endTimeMs: 500),
          LyricWord(text: '以', startTimeMs: 500, endTimeMs: 1000),
        ],
      );
      final syllables = resolveSyllables(line);
      expect(syllables.length, 2);
      expect(syllables[0].startTimeMs, 0);
      expect(syllables[1].endTimeMs, 1000);
    });

    test('LRC 行生成伪逐字（ASCII 单词保持完整）', () {
      const line = LyricLine(
        text: 'Hello world',
        startTimeMs: 0,
        endTimeMs: 1000,
      );
      final syllables = resolveSyllables(line);
      // Hello / 空格 / world
      expect(syllables.length, greaterThanOrEqualTo(3));
      expect(syllables.first.content, 'Hello');
      expect(syllables.map((s) => s.content).join(), 'Hello world');
    });

    test('LRC 伪逐字时间线性均分', () {
      const line = LyricLine(text: 'abc', startTimeMs: 1000, endTimeMs: 2000);
      final syllables = resolveSyllables(line);
      expect(syllables.length, 1); // abc 连续 ASCII 合并
      expect(syllables.first.startTimeMs, 1000);
      expect(syllables.first.endTimeMs, 2000);
    });
  });

  group('groupIntoWords', () {
    test('按尾部空白分单词', () {
      final syllables = [
        const LyricSyllable(content: 'a', startTimeMs: 0, endTimeMs: 100),
        const LyricSyllable(content: ' ', startTimeMs: 100, endTimeMs: 110),
        const LyricSyllable(content: 'b', startTimeMs: 110, endTimeMs: 210),
      ];
      final words = groupIntoWords(syllables);
      expect(words.length, 2);
      expect(words[0].map((s) => s.content).join(), 'a ');
      expect(words[1].map((s) => s.content).join(), 'b');
    });
  });

  group('shouldUseSimpleAnimation', () {
    test('纯中文走简单动画', () {
      expect(shouldUseSimpleAnimation('我爱你'), isTrue);
    });
    test('拉丁文本不强制简单动画', () {
      expect(shouldUseSimpleAnimation('hello'), isFalse);
    });
  });

  group('measureSyllablesAndDetermineAnimation', () {
    test('慢速非 CJK 词启用 awesome', () {
      final syllables = [
        const LyricSyllable(content: 'heaven', startTimeMs: 0, endTimeMs: 2000),
      ];
      final measured = measureSyllablesAndDetermineAnimation(
        syllables: syllables,
        style: style,
        spaceWidth: 10,
      );
      expect(measured.single.useAwesomeAnimation, isTrue);
      expect(measured.single.charPainters, isNotNull);
    });

    test('快速词或 CJK 不启用 awesome', () {
      final fast = [
        const LyricSyllable(content: 'a', startTimeMs: 0, endTimeMs: 50),
      ];
      final measuredFast = measureSyllablesAndDetermineAnimation(
        syllables: fast,
        style: style,
        spaceWidth: 10,
      );
      expect(measuredFast.single.useAwesomeAnimation, isFalse);

      final cjk = [
        const LyricSyllable(content: '爱', startTimeMs: 0, endTimeMs: 2000),
      ];
      final measuredCjk = measureSyllablesAndDetermineAnimation(
        syllables: cjk,
        style: style,
        spaceWidth: 10,
      );
      expect(measuredCjk.single.useAwesomeAnimation, isFalse);
    });
  });

  group('calculateBalancedLines', () {
    List<SyllableLayout> buildSyllables(List<String> words) {
      final out = <SyllableLayout>[];
      for (var i = 0; i < words.length; i++) {
        final painter = TextPainter(
          text: TextSpan(text: words[i], style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        out.add(
          SyllableLayout(
            syllable: LyricSyllable(
              content: words[i],
              startTimeMs: i * 100,
              endTimeMs: (i + 1) * 100,
            ),
            textPainter: painter,
            wordId: i,
            useAwesomeAnimation: false,
            width: painter.width,
            firstBaseline: 0,
          ),
        );
      }
      return out;
    }

    test('窄宽多词换行且不丢词', () {
      final syllables = buildSyllables(['one', 'two', 'three', 'four', 'five']);
      final lines = calculateBalancedLines(
        syllableLayouts: syllables,
        availableWidth: 40,
        style: style,
      );
      expect(lines.length, greaterThan(1));
      // 拼接后文本不变
      final joined = lines
          .expand((l) => l.syllables)
          .map((s) => s.syllable.content)
          .join();
      expect(joined, 'onetwothreefourfive');
    });

    test('超宽可用宽度只排一行', () {
      final syllables = buildSyllables(['a', 'b']);
      final lines = calculateBalancedLines(
        syllableLayouts: syllables,
        availableWidth: 500,
        style: style,
      );
      expect(lines.length, 1);
    });

    test('空列表返回空', () {
      expect(
        calculateBalancedLines(
          syllableLayouts: const [],
          availableWidth: 100,
          style: style,
        ),
        isEmpty,
      );
    });
  });

  group('calculateStaticLineLayout', () {
    test('定位写入 wordPivot 与 charOffset', () {
      final painter = TextPainter(
        text: const TextSpan(text: 'hello', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final sl = SyllableLayout(
        syllable: const LyricSyllable(
          content: 'hello',
          startTimeMs: 0,
          endTimeMs: 2000,
        ),
        textPainter: painter,
        wordId: 0,
        useAwesomeAnimation: true,
        width: painter.width,
        firstBaseline: painter.computeLineMetrics().first.baseline,
        charPainters: [
          for (final c in 'hello'.split(''))
            TextPainter(
              text: TextSpan(text: c, style: style),
              textDirection: TextDirection.ltr,
            )..layout(),
        ],
        charGlowPainters: null,
        charWidths: [
          for (final c in 'hello'.split(''))
            () {
              final tp = TextPainter(
                text: TextSpan(text: c, style: style),
                textDirection: TextDirection.ltr,
              )..layout();
              return tp.width;
            }(),
        ],
      );
      final positioned = calculateStaticLineLayout(
        wrappedLines: [
          WrappedLine(syllables: [sl], totalWidth: painter.width),
        ],
        isLineRightAligned: false,
        canvasWidth: 500,
        lineHeight: 30,
        isRtl: false,
      );
      final out = positioned.single.single;
      expect(out.position.dx, 0);
      expect(out.charOffsetInWord, 0);
      expect(out.wordAnimInfo, isNotNull);
      expect(out.wordPivot.dx, greaterThan(0));
    });
  });

  group('calculateRowRenderData', () {
    test('isLineLevel 标记行级歌词（LRC 整行单一颜色揭示）', () {
      final painter = TextPainter(
        text: const TextSpan(text: 'hello', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final sl = SyllableLayout(
        syllable: const LyricSyllable(
          content: 'hello',
          startTimeMs: 0,
          endTimeMs: 2000,
        ),
        textPainter: painter,
        wordId: 0,
        useAwesomeAnimation: false,
        width: painter.width,
        firstBaseline: 0,
      );
      final lineRows = calculateRowRenderData([
        [sl],
      ], isLineLevel: true);
      expect(lineRows.single.isLineLevel, isTrue);
      final wordRows = calculateRowRenderData([
        [sl],
      ], isLineLevel: false);
      expect(wordRows.single.isLineLevel, isFalse);
    });
  });

  group('measureLyricLine 顶层入口', () {
    test('行级 LRC 输出非空 rows 与总高度', () {
      const line = LyricLine(text: '测试歌词', startTimeMs: 0, endTimeMs: 2000);
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 300,
        glowColor: Colors.white,
      );
      expect(layout.isEmpty, isFalse);
      expect(layout.totalHeight, greaterThan(0));
    });

    test('LRC 行级歌词慢速也不启用 awesome 逐字动画', () {
      // 'heaven' 整词 2000ms：若不禁止会满足 awesome 阈值。
      const line = LyricLine(text: 'heaven', startTimeMs: 0, endTimeMs: 2000);
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 300,
        glowColor: Colors.white,
      );
      for (final row in layout.rows) {
        for (final sl in row.rowLayouts) {
          expect(sl.useAwesomeAnimation, isFalse);
          expect(sl.wordAnimInfo, isNull);
        }
      }
    });

    test('YRC 慢速词保持 awesome 逐字动画', () {
      const line = LyricLine(
        text: 'heaven',
        startTimeMs: 0,
        endTimeMs: 2000,
        words: [LyricWord(text: 'heaven', startTimeMs: 0, endTimeMs: 2000)],
      );
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 300,
        glowColor: Colors.white,
      );
      final sl = layout.rows.single.rowLayouts.single;
      expect(sl.useAwesomeAnimation, isTrue);
      expect(sl.wordAnimInfo, isNotNull);
    });

    test('measureLyricLine：LRC 行整行标记 isLineLevel，YRC 行不标记', () {
      const lrc = LyricLine(text: '测试歌词', startTimeMs: 0, endTimeMs: 2000);
      final lrcLayout = measureLyricLine(
        line: lrc,
        style: style,
        availableWidth: 300,
      );
      expect(lrcLayout.rows.every((r) => r.isLineLevel), isTrue);

      const yrc = LyricLine(
        text: '难 以',
        startTimeMs: 0,
        endTimeMs: 2000,
        words: [
          LyricWord(text: '难', startTimeMs: 0, endTimeMs: 1000),
          LyricWord(text: ' ', startTimeMs: 1000, endTimeMs: 1010),
          LyricWord(text: '以', startTimeMs: 1010, endTimeMs: 2000),
        ],
      );
      final yrcLayout = measureLyricLine(
        line: yrc,
        style: style,
        availableWidth: 300,
      );
      expect(yrcLayout.rows.every((r) => !r.isLineLevel), isTrue);
    });

    test('逐字行输出 rows', () {
      const line = LyricLine(
        text: '难 以',
        startTimeMs: 0,
        endTimeMs: 2000,
        words: [
          LyricWord(text: '难', startTimeMs: 0, endTimeMs: 1000),
          LyricWord(text: ' ', startTimeMs: 1000, endTimeMs: 1010),
          LyricWord(text: '以', startTimeMs: 1010, endTimeMs: 2000),
        ],
      );
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 300,
        glowColor: Colors.white,
      );
      expect(layout.isEmpty, isFalse);
    });
  });

  group('WordAnimationInfo 逐字动画幅度', () {
    LyricLineLayout layoutFor({required int durationMs}) {
      const chars = ['h', 'e', 'l', 'o'];
      final per = durationMs ~/ chars.length;
      return measureLyricLine(
        line: LyricLine(
          text: 'hello',
          startTimeMs: 0,
          endTimeMs: durationMs,
          words: [
            for (var i = 0; i < chars.length; i++)
              LyricWord(
                text: chars[i],
                startTimeMs: i * per,
                endTimeMs: (i + 1) * per,
              ),
          ],
        ),
        style: style,
        availableWidth: 300,
      );
    }

    WordAnimationInfo infoOf(LyricLineLayout l) => l.rows.isEmpty
        ? throw StateError('no rows')
        : l.rows.first.rowLayouts
              .map((s) => s.wordAnimInfo)
              .firstWhere((a) => a != null)!;

    test('慢词放大幅度更大，且 clamp 在范围内', () {
      final fast = infoOf(layoutFor(durationMs: 1200));
      final slow = infoOf(layoutFor(durationMs: 4000));
      expect(fast.swellAmount, greaterThan(0));
      expect(fast.swellAmount, lessThan(slow.swellAmount), reason: '慢词应放大更多');
      expect(slow.swellAmount, lessThanOrEqualTo(0.1));
    });
  });
}
