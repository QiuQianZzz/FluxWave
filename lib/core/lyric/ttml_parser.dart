import 'package:xml/xml.dart';

import 'lyric_model.dart';

/// TTML（Timed Text Markup Language）歌词解析器。
///
/// 移植自 `@applemusic-like-lyrics/ttml` 的 `TTMLParser`，
/// 将 Apple Music / AMLL DB 的 TTML XML 解析为 [LyricLine] 列表。
class TtmlParser {
  const TtmlParser._();

  // ── XML 命名空间 ──────────────────────────────────────────

  static const _nsTm = 'http://www.w3.org/ns/ttml#metadata';
  static const _nsXml = 'http://www.w3.org/XML/1998/namespace';
  static const _nsItunes = 'http://music.apple.com/lyric-ttml-internal';

  // ── XML 净化 ─────────────────────────────────────────────

  /// 修复 AMLL DB TTML 中常见的 XML 格式问题。
  ///
  /// 主要：将未转义的 `&`（非合法实体前缀）转为 `&amp;`。
  static String sanitize(String ttml) {
    if (ttml.isEmpty) return ttml;
    // 裸 & 且后面不是合法实体（amp/lt/gt/apos/quot/#数字实体）
    return ttml.replaceAll(
      RegExp(r'&(?!amp;|lt;|gt;|apos;|quot;|#\d+;|#x[0-9a-fA-F]+;)'),
      '&amp;',
    );
  }

  // ── 时间解析 ─────────────────────────────────────────────

  static final _timeSecRe = RegExp(r'^(\d+(?:\.\d+)?)s$');
  static final _timeShortRe = RegExp(r'^(?:(\d{1,2}):)?(\d{1,2})\.(\d{1,})$');
  static final _timeLongRe = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})\.(\d{1,})$');

  static int _parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    final v = raw.trim();
    if (v.isEmpty) return 0;

    final secMatch = _timeSecRe.firstMatch(v);
    if (secMatch != null) {
      final seconds = double.tryParse(secMatch.group(1)!) ?? 0;
      return (seconds * 1000).round();
    }

    final longMatch = _timeLongRe.firstMatch(v);
    if (longMatch != null) {
      final hh = int.parse(longMatch.group(1)!);
      final mm = int.parse(longMatch.group(2)!);
      final ss = int.parse(longMatch.group(3)!);
      final ms = _normalizeMs(longMatch.group(4)!);
      return hh * 3600000 + mm * 60000 + ss * 1000 + ms;
    }

    final shortMatch = _timeShortRe.firstMatch(v);
    if (shortMatch != null) {
      final mm = shortMatch.group(1) != null
          ? int.parse(shortMatch.group(1)!)
          : 0;
      final ss = int.parse(shortMatch.group(2)!);
      final ms = _normalizeMs(shortMatch.group(3)!);
      return mm * 60000 + ss * 1000 + ms;
    }

    return 0;
  }

  static int _normalizeMs(String raw) {
    final padded = raw.padRight(3, '0').substring(0, 3);
    return int.tryParse(padded) ?? 0;
  }

  // ── 属性读取 ─────────────────────────────────────────────

  static String? _getAttr(XmlElement el, String ns, String localName,
      {String? fallbackAttr}) {
    for (final a in el.attributes) {
      if (a.name.namespaceUri == ns && a.name.local == localName) {
        return a.value;
      }
    }
    if (fallbackAttr != null) {
      final fb = el.getAttribute(fallbackAttr);
      if (fb != null && fb.isNotEmpty) return fb;
    }
    for (final a in el.attributes) {
      if (a.name.local == localName && a.value.isNotEmpty) {
        return a.value;
      }
    }
    return null;
  }

  static String _getRole(XmlElement el) {
    return _getAttr(el, _nsTm, 'role', fallbackAttr: 'role') ?? '';
  }

  // ── 文本提取 ─────────────────────────────────────────────

  static final _multiSpaceRe = RegExp(r'\s+');

  static String _normalizeText(String? text, {bool trim = true}) {
    if (text == null || text.isEmpty) return '';
    final normalized = text.replaceAll(_multiSpaceRe, ' ');
    return trim ? normalized.trim() : normalized;
  }

  static String _getInnerText(XmlElement el) {
    final buf = StringBuffer();
    for (final child in el.children) {
      if (child is XmlText) {
        buf.write(child.value);
      } else if (child is XmlElement) {
        buf.write(_getInnerText(child));
      }
    }
    return buf.toString();
  }

  // ── 节点处理 ─────────────────────────────────────────────

  static _NodeState _extractNodeState(XmlElement element) {
    final state = _NodeState();
    _processChildren(state, element);
    return state;
  }

  static void _processChildren(_NodeState state, XmlElement parent) {
    for (final node in parent.childElements) {
      final role = _getRole(node);

      if (role == 'x-bg') {
        state.bgVocal = _parseBgVocal(node);
      } else if (role == 'x-translation') {
        state.translationText = _normalizeText(_getInnerText(node));
      } else if (role == 'x-roman') {
        state.romanText = _normalizeText(_getInnerText(node));
      } else {
        final begin = _getAttr(node, _nsXml, 'begin', fallbackAttr: 'begin');
        final end = _getAttr(node, _nsXml, 'end', fallbackAttr: 'end');

        if (begin != null && end != null) {
          _processWordElement(state, node, begin, end);
        } else {
          _processChildren(state, node);
        }
      }
    }
  }

  static void _processWordElement(
      _NodeState state, XmlElement el, String begin, String end) {
    final startTime = _parseTime(begin);
    final endTime = _parseTime(end);
    final rawText = _getInnerText(el);
    final isFormatting = rawText.contains('\n');

    String normalizedText;
    bool startsWithSpace = false;
    bool endsWithSpace = false;

    if (!isFormatting) {
      normalizedText = _normalizeText(rawText, trim: false);
      startsWithSpace = normalizedText.startsWith(' ');
      endsWithSpace = normalizedText.endsWith(' ');
    } else {
      normalizedText = _normalizeText(rawText);
    }

    final cleanText = normalizedText.trim();
    if (cleanText.isEmpty) return;

    if (startsWithSpace && state.words.isNotEmpty) {
      final last = state.words.last;
      state.words[state.words.length - 1] = _WordEntry(
          last.text, last.startTime, last.endTime,
          endsWithSpace: true);
    }

    state.fullText += normalizedText;
    state.words.add(_WordEntry(cleanText, startTime, endTime,
        endsWithSpace: endsWithSpace));
  }

  static _BgVocalState _parseBgVocal(XmlElement el) {
    final bg = _BgVocalState();
    final begin = _getAttr(el, _nsXml, 'begin', fallbackAttr: 'begin');
    final end = _getAttr(el, _nsXml, 'end', fallbackAttr: 'end');
    bg.startTime = _parseTime(begin);
    bg.endTime = _parseTime(end);
    bg.text = _normalizeText(_getInnerText(el));

    for (final child in el.descendants) {
      if (child is XmlElement) {
        final cBegin =
            _getAttr(child, _nsXml, 'begin', fallbackAttr: 'begin');
        final cEnd = _getAttr(child, _nsXml, 'end', fallbackAttr: 'end');
        if (cBegin != null && cEnd != null) {
          final wordText = _normalizeText(_getInnerText(child));
          if (wordText.isNotEmpty) {
            bg.words.add(
                _WordEntry(wordText, _parseTime(cBegin), _parseTime(cEnd)));
          }
        }
      }
    }

    bg.text = bg.text
        .replaceFirst(RegExp(r'^[(（]+'), '')
        .replaceFirst(RegExp(r'[)）]+$'), '');

    return bg;
  }

  // ── 行级处理 ─────────────────────────────────────────────

  static LyricLine? _processLineElement(XmlElement p) {
    final id = _getAttr(p, _nsItunes, 'key', fallbackAttr: 'itunes:key');
    if (id == null || id.isEmpty) return null;

    final state = _extractNodeState(p);
    _finalizeWords(state.words);

    final beginAttr = _getAttr(p, _nsXml, 'begin', fallbackAttr: 'begin');
    final endAttr = _getAttr(p, _nsXml, 'end', fallbackAttr: 'end');
    var startTime = _parseTime(beginAttr);
    var endTime = _parseTime(endAttr);

    if (state.words.isNotEmpty) {
      final minStart = state.words
          .map((w) => w.startTime)
          .reduce((a, b) => a < b ? a : b);
      final maxEnd = state.words
          .map((w) => w.endTime)
          .reduce((a, b) => a > b ? a : b);
      if (startTime == 0 || (minStart > 0 && minStart < startTime)) {
        startTime = minStart;
      }
      if (endTime == 0 || maxEnd > endTime) {
        endTime = maxEnd;
      }
    }

    final cleanFullText = _normalizeText(state.fullText);
    if (state.words.isEmpty && cleanFullText.isNotEmpty) {
      state.words.add(_WordEntry(
          cleanFullText,
          startTime > 0 ? startTime : 0,
          endTime > 0 ? endTime : 0));
    }

    if (cleanFullText.isEmpty && state.words.isEmpty) return null;
    if (startTime == 0 && endTime == 0) return null;

    final lyricWords = state.words
        .map((w) => LyricWord(
              text: w.text + (w.endsWithSpace ? ' ' : ''),
              startTimeMs: w.startTime,
              endTimeMs: w.endTime,
            ))
        .toList();

    return LyricLine(
      text: cleanFullText,
      startTimeMs: startTime,
      endTimeMs: endTime,
      words: lyricWords,
      translation: state.translationText,
      roman: state.romanText,
    );
  }

  static void _finalizeWords(List<_WordEntry> words) {
    if (words.isEmpty) return;
    words[0] = _WordEntry(
      words[0].text.trimLeft(),
      words[0].startTime,
      words[0].endTime,
      endsWithSpace: words[0].endsWithSpace,
    );
    final lastIdx = words.length - 1;
    words[lastIdx] = _WordEntry(
      words[lastIdx].text.trimRight(),
      words[lastIdx].startTime,
      words[lastIdx].endTime,
      endsWithSpace: false,
    );
  }

  // ── 公开 API ─────────────────────────────────────────────

  /// 解析 TTML XML 字符串为 [LyricLine] 列表。
  ///
  /// XML 格式异常时返回空列表（不抛出）。
  static List<LyricLine> parse(String ttmlText) {
    if (ttmlText.isEmpty) return const [];

    final document = XmlDocument.parse(sanitize(ttmlText));
    final lines = <LyricLine>[];

    // 优先按命名空间查找 <body>，找不到则遍历所有元素按 localName 匹配。
    var body = document.findAllElements('body').firstOrNull;
    body ??= document.descendants.whereType<XmlElement>()
        .where((e) => e.name.local == 'body').firstOrNull;
    if (body == null) return const [];

    for (final child in body.childElements) {
      final localName = child.name.local;
      if (localName == 'div') {
        for (final p in child.findAllElements('p')) {
          final line = _processLineElement(p);
          if (line != null) lines.add(line);
        }
      } else if (localName == 'p') {
        final line = _processLineElement(child);
        if (line != null) lines.add(line);
      }
    }

    lines.sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));
    return lines;
  }

  /// 清洗 TTML 中非主语言的翻译。
  static String cleanTranslations(String ttmlContent) {
    if (ttmlContent.isEmpty) return ttmlContent;

    final sanitized = sanitize(ttmlContent);
    late final XmlDocument doc;
    try {
      doc = XmlDocument.parse(sanitized);
    } catch (_) {
      return sanitized;
    }

    final langSet = <String>{};
    for (final el in doc.descendants.whereType<XmlElement>()) {
      final lang = el.getAttribute('xml:lang') ?? '';
      if (lang.isNotEmpty) langSet.add(lang);
    }

    if (langSet.length <= 1) return ttmlContent;

    final majorLang = _selectMajorLang(langSet.toList());
    if (majorLang == null) return ttmlContent;

    final toRemove = <XmlElement>[];
    for (final el in doc.descendants.whereType<XmlElement>()) {
      final lang = el.getAttribute('xml:lang') ?? '';
      if (lang.isEmpty || lang == majorLang) continue;
      final tag = el.name.local;
      if (tag == 'translation' || tag == 'span') {
        toRemove.add(el);
      }
    }
    for (final el in toRemove) {
      el.parent?.children.remove(el);
    }

    return doc.toXmlString().replaceAll(RegExp(r'\n\s*'), '');
  }

  static String? _selectMajorLang(List<String> langs) {
    if (langs.isEmpty) return null;
    for (final lang in langs) {
      if (lang.contains('Hans')) return lang;
    }
    for (final lang in langs) {
      if (lang.contains('Hant')) return lang;
    }
    for (final lang in langs) {
      if (lang.startsWith('zh')) return lang;
    }
    return langs.first;
  }
}

// ── 内部数据结构 ──────────────────────────────────────────

class _WordEntry {
  final String text;
  final int startTime;
  final int endTime;
  final bool endsWithSpace;

  const _WordEntry(this.text, this.startTime, this.endTime,
      {this.endsWithSpace = false});
}

class _NodeState {
  String fullText = '';
  final List<_WordEntry> words = [];
  String? translationText;
  String? romanText;
  _BgVocalState? bgVocal;
}

class _BgVocalState {
  String text = '';
  int startTime = 0;
  int endTime = 0;
  final List<_WordEntry> words = [];
}
