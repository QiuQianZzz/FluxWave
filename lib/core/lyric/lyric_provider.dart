import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio_cache/lyrics_cache.dart';
import '../netease/netease_api.dart';
import 'lyric_model.dart';
import 'lyric_parser.dart';

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

  // 进程内缓存：songId → 解析后的歌词。容量 40。
  static const _kCacheLimit = 40;
  final _cache = <int, List<LyricLine>>{};
  final _loading = <int, Future<List<LyricLine>>>{};

  LyricProvider(NeteaseApi api) : _fetchLyric = api.lyric;

  /// 测试用构造：直接注入 fetch 函数。
  @visibleForTesting
  LyricProvider.forTest(this._fetchLyric);

  /// 加载歌词。命中缓存立即返回；并发请求同一 songId 时共享同一个 Future。
  ///
  /// [songKey] 可选（`<source>_<songId>`），传入时启用磁盘缓存。
  Future<List<LyricLine>> load(int songId, {String? songKey}) async {
    final cached = _cache[songId];
    if (cached != null) return cached;

    final pending = _loading[songId];
    if (pending != null) return pending;

    final fut = _fetchAndParse(songId, songKey: songKey);
    _loading[songId] = fut;
    try {
      final lines = await fut;
      // 只缓存有内容的成功结果：空列表（真无歌词/失败）不缓存，否则断网
      // 失败返回的空结果会被永久缓存，后续任何重载都直接命中缓存返回空，
      // 表现为「切歌回来仍是暂无歌词」。
      if (lines.isNotEmpty) _putCache(songId, lines);
      return lines;
    } finally {
      _loading.remove(songId);
    }
  }

  /// 同步取缓存（无网络请求）；无缓存返回 null。
  List<LyricLine>? cached(int songId) => _cache[songId];

  /// 失效单首歌的缓存（切歌时不必要调用，仅用于强制刷新）。
  void invalidate(int songId) {
    _cache.remove(songId);
  }

  /// 清空所有缓存。
  void clear() {
    _cache.clear();
  }

  Future<List<LyricLine>> _fetchAndParse(
    int songId, {
    String? songKey,
  }) async {
    // 1. 尝试磁盘缓存（原始文本）。磁盘读取失败不视为歌词失败，回退网络。
    if (songKey != null) {
      try {
        final diskCached = await LyricsCache.instance.read(songKey);
        if (diskCached != null && diskCached.isNotEmpty) {
          final lines = LyricParser.parseAuto(diskCached);
          if (lines.isNotEmpty) return lines;
        }
      } catch (_) {}
    }

    // 2. 网络加载。网络/接口异常向上抛出：不缓存失败结果，调用方据此区分
    //    「加载失败」（可重试）与「真没有歌词」（返回空列表，成功语义）。
    final body = await _fetchLyric(songId);
    if (body['code'] != 200) return const [];

    // 主歌词：yrc 优先，回退 lrc
    final yrc = _extractLyricText(body, 'yrc');
    final lrc = _extractLyricText(body, 'lrc');
    final mainText = yrc.isNotEmpty ? yrc : lrc;
    if (mainText.isEmpty) return const [];

    // 解析主歌词
    final mainLines = LyricParser.parseAuto(mainText);
    if (mainLines.isEmpty) return const [];

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

    // 3. 写入磁盘缓存（原始文本，不含翻译/罗马音对齐后的结构）
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

  void _putCache(int songId, List<LyricLine> lines) {
    if (_cache.length >= _kCacheLimit && !_cache.containsKey(songId)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[songId] = lines;
  }
}
