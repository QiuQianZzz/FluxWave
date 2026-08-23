import 'package:fluxwave/core/lyric/lyric_parser.dart';
import 'package:fluxwave/core/lyric/ttml_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _preamble = '<tt xmlns="http://www.w3.org/ns/ttml"'
    ' xmlns:ttm="http://www.w3.org/ns/ttml#metadata"'
    ' xmlns:itunes="http://music.apple.com/lyric-ttml-internal">'
    '<body><div>';
const _postamble = '</div></body></tt>';

String _w(String p) => '$_preamble$p$_postamble';

void main() {
  group('TtmlParser', () {
    test('parses basic word-level TTML', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:02.000">你</span>'
        '<span begin="00:02.000" end="00:03.000">好</span>'
        '</p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].text, '你好');
      expect(lines[0].startTimeMs, 1000);
      expect(lines[0].endTimeMs, 3000);
      expect(lines[0].words, isNotNull);
      expect(lines[0].words!.length, 2);
      expect(lines[0].words![0].text, '你');
      expect(lines[0].words![0].startTimeMs, 1000);
      expect(lines[0].words![0].endTimeMs, 2000);
      expect(lines[0].words![1].text, '好');
      expect(lines[0].words![1].startTimeMs, 2000);
      expect(lines[0].words![1].endTimeMs, 3000);
    });

    test('parses multiple lines', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">第一行</span></p>'
        '<p itunes:key="L2" begin="00:04.000" end="00:06.000">'
        '<span begin="00:04.000" end="00:06.000">第二行</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 2);
      expect(lines[0].text, '第一行');
      expect(lines[1].text, '第二行');
    });

    test('parses hh:mm:ss.xx time format', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="01:02:03.456" end="01:02:05.789">'
        '<span begin="01:02:03.456" end="01:02:05.789">测试</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].startTimeMs, 3723456);
      expect(lines[0].endTimeMs, 3725789);
    });

    test('parses seconds-only time format', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="6.703s" end="9.794s">'
        '<span begin="6.703s" end="9.794s">Hello</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].startTimeMs, 6703);
      expect(lines[0].endTimeMs, 9794);
    });

    test('parses single-digit seconds without s suffix', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="6.703" end="9.794">'
        '<span begin="6.703" end="9.794">Test</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].startTimeMs, 6703);
      expect(lines[0].endTimeMs, 9794);
    });

    test('extracts translation', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">你好</span>'
        '<span ttm:role="x-translation" xml:lang="zh-Hans">Hello</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].translation, 'Hello');
    });

    test('extracts romanization', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">你好</span>'
        '<span ttm:role="x-roman" xml:lang="zh-Latn">ni hao</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].roman, 'ni hao');
    });

    test('returns empty list for empty input', () {
      expect(TtmlParser.parse(''), isEmpty);
    });

    test('returns empty list for TTML without body', () {
      final ttml = '<tt xmlns="http://www.w3.org/ns/ttml">'
          '<head><metadata/></head></tt>';
      expect(TtmlParser.parse(ttml), isEmpty);
    });

    test('skips p elements without itunes:key', () {
      final ttml = _w(
        '<p begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">无key</span></p>'
        '<p itunes:key="L1" begin="00:04.000" end="00:06.000">'
        '<span begin="00:04.000" end="00:06.000">有key</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].text, '有key');
    });

    test('sorts lines by startTimeMs', () {
      final ttml = _w(
        '<p itunes:key="L2" begin="00:04.000" end="00:06.000">'
        '<span begin="00:04.000" end="00:06.000">第二行</span></p>'
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">第一行</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 2);
      expect(lines[0].text, '第一行');
      expect(lines[1].text, '第二行');
    });

    test('parses background vocal (x-bg) as isBG line', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">主唱</span>'
        '<span ttm:role="x-bg" begin="00:01.500" end="00:02.500">和声</span>'
        '</p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 2);
      // 主歌词行
      expect(lines[0].text, '主唱');
      expect(lines[0].isBG, false);
      // 背景人声行
      expect(lines[1].text, '和声');
      expect(lines[1].isBG, true);
      expect(lines[1].startTimeMs, 1500);
      expect(lines[1].endTimeMs, 2500);
    });

    test('parses background vocal with word-level timing', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:04.000">'
        '<span begin="00:01.000" end="00:04.000">主唱</span>'
        '<span ttm:role="x-bg" begin="00:02.000" end="00:03.000">'
        '<span begin="00:02.000" end="00:02.500">和</span>'
        '<span begin="00:02.500" end="00:03.000">声</span>'
        '</span></p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 2);
      expect(lines[1].isBG, true);
      expect(lines[1].words, isNotNull);
      expect(lines[1].words!.length, 2);
      expect(lines[1].words![0].text, '和');
      expect(lines[1].words![1].text, '声');
    });

    test('BG vocal without text is omitted', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">主唱</span>'
        '<span ttm:role="x-bg" begin="00:01.000" end="00:03.000">  </span>'
        '</p>',
      );
      final lines = TtmlParser.parse(ttml);
      expect(lines.length, 1);
      expect(lines[0].isBG, false);
    });
  });

  group('LyricParser TTML integration', () {
    test('isTtml detects TTML content', () {
      expect(LyricParser.isTtml('<tt xmlns="...">'), true);
      expect(LyricParser.isTtml('  <tt>'), true);
      expect(LyricParser.isTtml('<foo xmlns="http://www.w3.org/ns/ttml">'), true);
      expect(LyricParser.isTtml('[00:12.34]lyrics'), false);
      expect(LyricParser.isTtml('plain text'), false);
    });

    test('parseAuto dispatches to TTML parser', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">TTML</span></p>',
      );
      final lines = LyricParser.parseAuto(ttml);
      expect(lines.length, 1);
      expect(lines[0].text, 'TTML');
      expect(lines[0].words, isNotNull);
    });
  });

  group('TtmlParser.cleanTranslations', () {
    test('keeps single language unchanged', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">你好</span>'
        '<span ttm:role="x-translation" xml:lang="zh-Hans">Hello</span></p>',
      );
      final cleaned = TtmlParser.cleanTranslations(ttml);
      expect(cleaned, contains('xml:lang="zh-Hans"'));
    });

    test('selects Hans over other languages', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">你好</span>'
        '<span ttm:role="x-translation" xml:lang="ja">こんにちは</span>'
        '<span ttm:role="x-translation" xml:lang="zh-Hans">Hello</span></p>',
      );
      final cleaned = TtmlParser.cleanTranslations(ttml);
      expect(cleaned, contains('zh-Hans'));
      expect(cleaned, isNot(contains('ja')));
    });

    test('selects Hant when no Hans', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">你好</span>'
        '<span ttm:role="x-translation" xml:lang="ja">こんにちは</span>'
        '<span ttm:role="x-translation" xml:lang="zh-Hant">您好</span></p>',
      );
      final cleaned = TtmlParser.cleanTranslations(ttml);
      expect(cleaned, contains('zh-Hant'));
      expect(cleaned, isNot(contains('ja')));
    });
  });

  group('TtmlParser.sanitize', () {
    test('escapes bare ampersand', () {
      final input = '<p>R&B</p>';
      final result = TtmlParser.sanitize(input);
      expect(result, '<p>R&amp;B</p>');
    });

    test('preserves valid XML entities', () {
      final input = '<p>&amp;&lt;&gt;&apos;&quot;</p>';
      final result = TtmlParser.sanitize(input);
      expect(result, input);
    });

    test('preserves numeric entities', () {
      final input = '<p>&#65;&#x41;</p>';
      final result = TtmlParser.sanitize(input);
      expect(result, input);
    });

    test('sanitized content parses successfully', () {
      final ttml = _w(
        '<p itunes:key="L1" begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:03.000">R&amp;B</span></p>',
      );
      final lines = LyricParser.parseTtml(ttml);
      expect(lines.length, 1);
      expect(lines[0].text, 'R&B');
    });
  });
}