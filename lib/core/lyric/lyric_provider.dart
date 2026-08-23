import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio_cache/lyrics_cache.dart';
import '../netease/netease_api.dart';
import 'amll_db_client.dart';
import 'lyric_model.dart';
import 'lyric_parser.dart';
import 'ttml_parser.dart';

/// 歌词加载编排。
///
/// 负责：
/// 1. 调用 `NeteaseApi.lyric` 拿原始响应；
/// 2. 字段提取（yrc > lrc，ytlrc > tlyric，yromalrc > romalrc）；
/// 3. 解析 + 翻译/罗马音对齐；
/// 4. 进程内 LRU 缓存（key = songId）；
/// 5. 磁盘缓存（`cache/<songKey>/lyrics.txt`），app 重启后命中可跳过网络。
class LyricProvider {
  /// 歌词请求函数（注入 [NeteaseApi.lyric]，便于测试 mock）。
  final Future<Map<String, dynamic>> Function(int songId) _fetchLyric;

  // 进程内缓存（LRU）：songId → 解析后的歌词。容量 40。
  // 使用 LinkedHashMap（insertionOrder = false）实现 LRU：
  // - 读取时 remove + reinsert 移到末尾（最近使用）
  // - 淘汰时 removeFirst（最久未使用）
  static const _kCacheLimit = 40;
  final _cache = <int, List<LyricLine>>{};
  final _loading = <int, Future<List<LyricLine>>>{};

  // 代际计数器：每次 invalidateSong 递增，过滤过期请求的结果写入。
  final _generation = <int, int>{};

  /// 确定性无歌词哨兵：接口正常（code==200）但无歌词文本。
  ///
  /// 与「加载失败」（抛异常、不缓存、可重试）和「接口异常返回空」
  /// （code != 200，同样不缓存）严格区分。用 `List.unmodifiable(const [])`
  /// 而非 `const []`：后者是常量规范化的单例，无法与普通空列表做
  /// `identical` 区分。
  static final List<LyricLine> _noLyrics = List.unmodifiable(const []);

  LyricProvider(NeteaseApi api) : _fetchLyric = api.lyric;

  /// 测试用构造：直接注入 fetch 函数。
  @visibleForTesting
  LyricProvider.forTest(this._fetchLyric);

  /// 加载歌词。命中缓存立即返回；并发请求同一 songId 时共享同一个 Future。
  ///
  /// [songKey] 可选（`<source>_<songId>`），传入时启用磁盘缓存。
  /// [enableTtml] 控制是否尝试 AMLL DB TTML 逐字歌词（默认 true）。
  ///
  /// 缓存策略（断网失败结果不缓存，可重试）：
  /// - 成功：非空歌词 → 缓存；
  /// - 确定性无歌词（code==200 但无文本）→ 缓存空哨兵，命中直接返回空，
  ///   避免对无歌词歌曲每次播放都重新请求；
  /// - 失败（网络/接口异常、code != 200）→ 返回空但不缓存，重试重新请求。
  Future<List<LyricLine>> load(
    int songId, {
    String? songKey,
    bool enableTtml = true,
  }) async {
    final cached = _cache.remove(songId);
    if (cached != null) {
      _cache[songId] = cached;
      return cached;
    }

    final pending = _loading[songId];
    if (pending != null) return pending;

    final gen = _generation[songId] ?? 0;
    final fut = _fetchAndParse(songId, songKey: songKey, enableTtml: enableTtml);
    _loading[songId] = fut;
    try {
      final lines = await fut;
      // 过期请求：中间被 invalidateSong 过，结果已失效，不写入缓存。
      if ((_generation[songId] ?? 0) != gen) return lines;
      if (lines.isNotEmpty) {
        _putCache(songId, lines);
      } else if (identical(lines, _noLyrics)) {
        _putCache(songId, _noLyrics);
      }
      return lines;
    } finally {
      _loading.remove(songId);
    }
  }

  /// 同步取缓存（无网络请求）；无缓存返回 null。命中时标记为最近使用。
  List<LyricLine>? cached(int songId) {
    final lines = _cache.remove(songId);
    if (lines != null) _cache[songId] = lines; // reinsert at end = most recently used
    return lines;
  }

  /// 失效单首歌的缓存（切歌时不必要调用，仅用于强制刷新）。
  void invalidate(int songId) {
    _cache.remove(songId);
  }

  /// 失效单首歌的内存 + 磁盘缓存（开关切换时调用，强制重新加载）。
  Future<void> invalidateSong(int songId, {String? songKey}) async {
    _cache.remove(songId);
    _generation[songId] = (_generation[songId] ?? 0) + 1;
    if (songKey != null) {
      await LyricsCache.instance.delete(songKey);
    }
  }

  /// 清空所有缓存。
  void clear() {
    _cache.clear();
  }

  Future<List<LyricLine>> _fetchAndParse(
    int songId, {
    String? songKey,
    bool enableTtml = true,
  }) async {
    // 1. 尝试磁盘缓存（TTML 和平台歌词分开存储，互不干扰）。
    if (songKey != null) {
      try {
        final diskCached = await LyricsCache.instance.read(
          songKey,
          isTtml: enableTtml,
        );
        if (diskCached != null && diskCached.isNotEmpty) {
          final lines = LyricParser.parseAuto(diskCached);
          if (lines.isNotEmpty) return lines;
        }
      } catch (_) {}
    }

    // 2. 尝试 AMLL DB TTML（逐字级别最高质量），需开关开启。
    //    若 TTML 解析后无逐字数据（纯行级），降级到 Netease（YRC 可能有逐字）。
    if (enableTtml) {
      try {
        final ttmlContent = await AmllDbClient.fetchTtml(songId: songId);
        if (ttmlContent != null && ttmlContent.isNotEmpty) {
          final sanitized = TtmlParser.sanitize(ttmlContent);
          final cleaned = TtmlParser.cleanTranslations(sanitized);
          final lines = LyricParser.parseTtml(cleaned);
          if (lines.isEmpty) {
            final rawLines = LyricParser.parseTtml(sanitized);
            if (rawLines.isNotEmpty && _hasWordLevel(rawLines)) {
              if (songKey != null) {
                LyricsCache.instance.write(songKey, ttmlContent, isTtml: true);
              }
              return rawLines;
            }
          } else if (_hasWordLevel(lines)) {
            if (songKey != null) {
              LyricsCache.instance.write(songKey, ttmlContent, isTtml: true);
            }
            return lines;
          }
        }
      } catch (_) {}
    }

    // 3. 网络加载（Netease）。网络/接口异常向上抛出：不缓存失败结果，调用方据此区分
    //    「加载失败」（可重试）与「真没有歌词」（返回空列表，成功语义）。
    final body = await _fetchLyric(songId);
    if (body['code'] != 200) return const [];

    // 主歌词：yrc 优先，回退 lrc
    final yrc = _extractLyricText(body, 'yrc');
    final lrc = _extractLyricText(body, 'lrc');
    final mainText = yrc.isNotEmpty ? yrc : lrc;

    // code==200 但无歌词文本 → 确定性无歌词（哨兵，可缓存）。
    if (mainText.isEmpty) return _noLyrics;

    // 解析主歌词
    final mainLines = LyricParser.parseAuto(mainText);
    if (mainLines.isEmpty) return _noLyrics;

    // 翻译：ytlrc 优先，回退 tlyric
    final transText = _extractLyricText(body, 'ytlrc').isNotEmpty
        ? _extractLyricText(body, 'ytlrc')
        : _extractLyricText(body, 'tlyric');
    var result = mainLines;
    if (transText.isNotEmpty) {
      final transLines = LyricParser.parseLrc(transText);
      result = LyricParser.alignTranslation(
        result,
        transLines,
        isRoman: false,
      );
    }

    // 罗马音：yromalrc 优先，回退 romalrc
    final romanText = _extractLyricText(body, 'yromalrc').isNotEmpty
        ? _extractLyricText(body, 'yromalrc')
        : _extractLyricText(body, 'romalrc');
    if (romanText.isNotEmpty) {
      final romanLines = LyricParser.parseLrc(romanText);
      result = LyricParser.alignTranslation(
        result,
        romanLines,
        isRoman: true,
      );
    }

    // 4. 写入磁盘缓存（平台歌词，原始文本，不含翻译/罗马音对齐后的结构）
    if (songKey != null && mainText.isNotEmpty) {
      LyricsCache.instance.write(songKey, mainText);
    }

    return result;
  }

  /// 提取响应字段 `{field: {lyric: "..."}}` 中的 lyric 字符串。
  static String _extractLyricText(Map<String, dynamic> body, String field) {
    final obj = body[field];
    if (obj is! Map) return '';
    final lyric = obj['lyric'];
    return lyric is String ? lyric : '';
  }

  /// 检查歌词行是否包含逐字数据（至少 30% 的行有 words）。
  static bool _hasWordLevel(List<LyricLine> lines) {
    if (lines.isEmpty) return false;
    var wordCount = 0;
    for (final line in lines) {
      if (line.words != null && line.words!.isNotEmpty) wordCount++;
    }
    return wordCount >= lines.length * 0.3;
  }

  void _putCache(int songId, List<LyricLine> lines) {
    _cache.remove(songId); // remove first to update insertion order
    if (_cache.length >= _kCacheLimit) {
      _cache.remove(_cache.keys.first); // evict least recently used
    }
    _cache[songId] = lines;
  }
}
