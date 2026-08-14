import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/lyric/lyric_model.dart';
import 'package:fluxwave/core/lyric/lyric_parser.dart';
import 'package:fluxwave/core/lyric/lyric_provider.dart';

void main() {
  group('LyricParser.parseLrc', () {
    test('标准 LRC 解析 + 倒序填充 endTime', () {
      const lrc = '''
[00:12.345]第一句
[00:17.678]第二句
[00:23.000]第三句
''';
      final lines = LyricParser.parseLrc(lrc);
      expect(lines.length, 3);
      expect(lines[0].text, '第一句');
      expect(lines[0].startTimeMs, 12345);
      expect(lines[0].endTimeMs, 17678); // = 下一行 start
      expect(lines[1].startTimeMs, 17678);
      expect(lines[1].endTimeMs, 23000);
      expect(lines[2].startTimeMs, 23000);
      expect(lines[2].endTimeMs, 28000); // 末行 +5s
      expect(lines.every((l) => l.words == null), true); // 行级无 words
    });

    test('跳过元数据行和空行', () {
      const lrc = '''
[ti:歌曲名]
[ar:歌手]
[00:12.345]实际歌词
''';
      final lines = LyricParser.parseLrc(lrc);
      expect(lines.length, 1);
      expect(lines[0].text, '实际歌词');
    });

    test('多时间戳共享歌词', () {
      const lrc = '[00:12.345][00:45.678]共享歌词';
      final lines = LyricParser.parseLrc(lrc);
      expect(lines.length, 2);
      expect(lines[0].text, '共享歌词');
      expect(lines[0].startTimeMs, 12345);
      expect(lines[1].text, '共享歌词');
      expect(lines[1].startTimeMs, 45678);
    });

    test('2位毫秒 ×10', () {
      const lrc = '[00:12.34]测试';
      final lines = LyricParser.parseLrc(lrc);
      expect(lines[0].startTimeMs, 12340); // 34 → 340ms
    });

    test('空文本返回空列表', () {
      expect(LyricParser.parseLrc(''), isEmpty);
      expect(LyricParser.parseLrc('  \n  '), isEmpty);
    });
  });

  group('LyricParser.parseYrc', () {
    test('逐字解析 + 字级时间戳', () {
      const yrc = '[12580,3470](12580,250,0)难(12830,300,0)以';
      final lines = LyricParser.parseYrc(yrc);
      expect(lines.length, 1);
      final line = lines[0];
      expect(line.startTimeMs, 12580);
      expect(line.endTimeMs, 16050); // 12580 + 3470
      expect(line.text, '难以');
      expect(line.words, isNotNull);
      expect(line.words!.length, 2);
      expect(line.words![0].text, '难');
      expect(line.words![0].startTimeMs, 12580);
      expect(line.words![0].endTimeMs, 12830); // 12580 + 250
      expect(line.words![1].text, '以');
      expect(line.words![1].startTimeMs, 12830);
      expect(line.words![1].endTimeMs, 13130); // 12830 + 300
    });

    test('多行 YRC 按时间排序', () {
      const yrc = '''
[30000,2000](30000,500,0)后(30500,500,0)行
[10000,2000](10000,500,0)前(10500,500,0)行
''';
      final lines = LyricParser.parseYrc(yrc);
      expect(lines.length, 2);
      expect(lines[0].startTimeMs, 10000); // 排序后前行在前
      expect(lines[1].startTimeMs, 30000);
    });

    test('isYrc 检测', () {
      expect(LyricParser.isYrc('[12580,3470](12580,250,0)难'), true);
      expect(LyricParser.isYrc('[00:12.345]普通LRC'), false);
    });
  });

  group('LyricParser.parseAuto', () {
    test('YRC 优先识别', () {
      const content = '[12580,3470](12580,250,0)难';
      final lines = LyricParser.parseAuto(content);
      expect(lines.first.isWordLevel, true);
    });

    test('回退 LRC', () {
      const content = '[00:12.345]普通歌词';
      final lines = LyricParser.parseAuto(content);
      expect(lines.first.isWordLevel, false);
    });
  });

  group('LyricParser.alignTranslation', () {
    test('300ms 容差内对齐翻译', () {
      final main = LyricParser.parseLrc('[00:12.345]原文\n[00:17.678]第二句');
      final trans = LyricParser.parseLrc(
        '[00:12.500]Translation\n[00:17.800]Second',
      );
      final result = LyricParser.alignTranslation(main, trans);
      expect(result[0].translation, 'Translation');
      expect(result[1].translation, 'Second');
    });

    test('过滤无效翻译（空、版权声明）', () {
      final main = LyricParser.parseLrc('[00:12.345]原文');
      final trans = LyricParser.parseLrc('[00:12.500]//');
      var result = LyricParser.alignTranslation(main, trans);
      expect(result[0].translation, isNull);

      final trans2 = LyricParser.parseLrc('[00:12.500]作品的著作权归作者');
      result = LyricParser.alignTranslation(main, trans2);
      expect(result[0].translation, isNull);
    });

    test('罗马音标记 isRoman', () {
      final main = LyricParser.parseLrc('[00:12.345]難以');
      final roman = LyricParser.parseLrc('[00:12.500]nan yi');
      final result = LyricParser.alignTranslation(main, roman, isRoman: true);
      expect(result[0].roman, 'nan yi');
      expect(result[0].translation, isNull);
    });

    test('多个翻译在容差内选最优（不因第一个匹配就 break）', () {
      // 主行 12345ms，两个翻译都在 300ms 容差内：
      // 译A 12500ms delta=155，译B 12400ms delta=55 ← 更接近
      // 必须选译B，而非找到译A就 break
      final main = LyricParser.parseLrc('[00:12.345]原文');
      final trans = LyricParser.parseLrc('[00:12.500]译A\n[00:12.400]译B');
      final result = LyricParser.alignTranslation(main, trans);
      expect(result[0].translation, '译B');
    });
  });

  group('LyricParser.findCurrentLineIndex', () {
    final lines = [
      const LyricLine(text: 'a', startTimeMs: 10000, endTimeMs: 15000),
      const LyricLine(text: 'b', startTimeMs: 20000, endTimeMs: 25000),
      const LyricLine(text: 'c', startTimeMs: 30000, endTimeMs: 35000),
    ];

    test('空列表返回 -1', () {
      expect(LyricParser.findCurrentLineIndex(const [], 1000), -1);
    });

    test('时间早于首行返回 0', () {
      expect(LyricParser.findCurrentLineIndex(lines, 5000), 0);
    });

    test('中间时间返回对应行', () {
      expect(LyricParser.findCurrentLineIndex(lines, 22000), 1);
      expect(LyricParser.findCurrentLineIndex(lines, 35000), 2);
    });

    test('正好在行首', () {
      expect(LyricParser.findCurrentLineIndex(lines, 20000), 1);
    });
  });

  group('LyricParser.calculateLineProgress', () {
    test('行级线性推进', () {
      const line = LyricLine(text: '测试', startTimeMs: 10000, endTimeMs: 20000);
      expect(LyricParser.calculateLineProgress(line, 10000), 0);
      expect(LyricParser.calculateLineProgress(line, 15000), 0.5);
      expect(LyricParser.calculateLineProgress(line, 20000), 1);
    });

    test('逐字累加字符', () {
      const line = LyricLine(
        text: '難以',
        startTimeMs: 10000,
        endTimeMs: 15000,
        words: [
          LyricWord(text: '難', startTimeMs: 10000, endTimeMs: 12000),
          LyricWord(text: '以', startTimeMs: 12000, endTimeMs: 14000),
        ],
      );
      expect(LyricParser.calculateLineProgress(line, 10000), 0);
      // 难字进行一半：1000ms / 2000ms = 0.5，0.5 * 1 char / 2 total = 0.25
      expect(
        LyricParser.calculateLineProgress(line, 11000),
        closeTo(0.25, 0.01),
      );
      // 难字完成：1 char / 2 total = 0.5
      expect(
        LyricParser.calculateLineProgress(line, 12000),
        closeTo(0.5, 0.01),
      );
      // 以字完成：2 char / 2 total = 1.0
      expect(LyricParser.calculateLineProgress(line, 14000), 1);
    });

    test('超出 endTime 返回 1', () {
      const line = LyricLine(text: '测试', startTimeMs: 10000, endTimeMs: 20000);
      expect(LyricParser.calculateLineProgress(line, 30000), 1);
    });
  });

  group('LyricLine', () {
    test('isWordLevel', () {
      const lineLevel = LyricLine(text: 'a', startTimeMs: 0, endTimeMs: 1);
      expect(lineLevel.isWordLevel, false);

      const wordLevel = LyricLine(
        text: 'a',
        startTimeMs: 0,
        endTimeMs: 1,
        words: [LyricWord(text: 'a', startTimeMs: 0, endTimeMs: 1)],
      );
      expect(wordLevel.isWordLevel, true);
    });

    test('copyWith translation/roman', () {
      const line = LyricLine(text: 'a', startTimeMs: 0, endTimeMs: 1);
      final translated = line.copyWith(translation: 'trans');
      expect(translated.translation, 'trans');
      expect(translated.text, 'a');
    });
  });

  group('LyricProvider', () {
    LyricProvider makeProvider(
      Future<Map<String, dynamic>> Function(int) fetch,
    ) {
      return LyricProvider.forTest(fetch);
    }

    test('缓存命中不重复请求', () async {
      var callCount = 0;
      final provider = makeProvider((_) async {
        callCount++;
        return {
          'code': 200,
          'lrc': {'lyric': '[00:01.000]测试'},
        };
      });
      await provider.load(1);
      await provider.load(1);
      expect(callCount, 1);
    });

    test('code != 200 返回空', () async {
      final provider = makeProvider((_) async => {'code': 404});
      final lines = await provider.load(1);
      expect(lines, isEmpty);
    });

    test('yrc 优先于 lrc', () async {
      final provider = makeProvider(
        (_) async => {
          'code': 200,
          'lrc': {'lyric': '[00:01.000]行级'},
          'yrc': {'lyric': '[1000,2000](1000,500,0)逐字'},
        },
      );
      final lines = await provider.load(1);
      expect(lines.first.isWordLevel, true);
    });

    test('翻译对齐', () async {
      final provider = makeProvider(
        (_) async => {
          'code': 200,
          'lrc': {'lyric': '[00:01.000]原文'},
          'tlyric': {'lyric': '[00:01.100]Translation'},
        },
      );
      final lines = await provider.load(1);
      expect(lines.first.translation, 'Translation');
    });

    test('网络失败抛异常且不缓存，重试可重新请求', () async {
      var calls = 0;
      final provider = makeProvider((_) async {
        calls++;
        if (calls == 1) throw Exception('network down');
        return {
          'code': 200,
          'lrc': {'lyric': '[00:01.000]测试'},
        };
      });
      // 第一次失败：异常向上抛出（失败结果不入缓存）
      await expectLater(provider.load(1), throwsA(isA<Exception>()));
      // 第二次重试：重新发起请求并成功（而非命中缓存的空结果）
      final lines = await provider.load(1);
      expect(lines, isNotEmpty);
      expect(calls, 2);
    });

    test('空结果不缓存：再次 load 会重新请求', () async {
      var calls = 0;
      final provider = makeProvider((_) async {
        calls++;
        return {'code': 404};
      });
      await provider.load(1);
      await provider.load(1);
      // 空/失败结果未缓存 → 第二次重新请求（配合断网恢复后歌词重试）。
      expect(calls, 2);
    });

    test('确定性无歌词（code==200 无文本）缓存：再次 load 不重新请求', () async {
      var calls = 0;
      final provider = makeProvider((_) async {
        calls++;
        return {
          'code': 200,
          'lrc': {'lyric': null},
        };
      });
      final first = await provider.load(1);
      expect(first, isEmpty);
      // 二次 load 命中空哨兵缓存：不再发网络请求。
      final second = await provider.load(1);
      expect(second, isEmpty);
      expect(calls, 1);
    });

    test('确定性无歌词与接口异常空可区分：后者仍可重试', () async {
      var calls = 0;
      final provider = makeProvider((_) async {
        calls++;
        // 第一次 code==200 无歌词（确定性），第二次接口异常 code!=200。
        if (calls == 1) {
          return {
            'code': 200,
            'lrc': {'lyric': null},
          };
        }
        return {'code': 500};
      });
      final first = await provider.load(1);
      expect(first, isEmpty);
      // 确定性空已缓存，但 invalidate 后 code!=200 的异常空不缓存，可重试。
      provider.invalidate(1);
      final second = await provider.load(1);
      expect(second, isEmpty);
      expect(calls, 2);
    });
  });
}
