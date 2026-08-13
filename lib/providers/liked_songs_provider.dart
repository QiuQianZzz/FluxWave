import 'package:flutter/foundation.dart';

import '../core/playback_stats/database_helper.dart';
import '../core/playback_stats/playback_stats_models.dart';
import '../models/song.dart';

/// 「我喜欢的音乐」状态：收藏集合 + 快速判断。
///
/// 数据源为 [DatabaseHelper] 的 `liked_song` 表（整曲快照离线可渲染）。
/// 启动时 [load] 全量载入内存：列表经 [songs]（最新收藏在前），O(1) 判断
/// 经 [isLiked]/[containsKey]。toggle 写库成功后立即同步内存并通知 UI。
class LikedSongsProvider extends ChangeNotifier {
  LikedSongsProvider({DatabaseHelper? storage})
      : _storage = storage ?? DatabaseHelper.instance;

  final DatabaseHelper _storage;

  bool _loaded = false;
  bool _loading = false;
  bool _disposed = false;
  List<LikedSong> _songs = const [];
  Map<String, LikedSong> _byKey = const {};

  /// 是否已从磁盘载入过（首次 load 后为 true）。
  bool get loaded => _loaded;

  /// 是否正在载入中。
  bool get loading => _loading;

  /// 收藏列表（最新在前）。
  List<LikedSong> get songs => _songs;

  /// 收藏总数。
  int get count => _songs.length;

  /// 歌曲全局键（音源命名空间防撞号）。
  static String keyOf(Song song) => '${song.source}_${song.id}';

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 从磁盘载入收藏（幂等：已载入则忽略）。
  Future<void> load() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final rows = await _storage.getLikedSongs();
      if (_disposed) return;
      _songs = List.unmodifiable(rows);
      _byKey = {
        for (final s in _songs) '${s.source}_${s.sourceId}': s,
      };
      _loaded = true;
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  /// 快速判断某首歌是否已收藏。
  bool isLiked(Song song) => _byKey.containsKey(keyOf(song));

  /// 按 (音源, 歌曲 id) 判断是否已收藏。
  bool isLikedId(String source, int id) =>
      _byKey.containsKey('${source}_$id');

  /// 收藏 / 取消收藏。返回切换后的收藏态（true = 已收藏）。
  Future<bool> toggle(Song song) async {
    if (!_loaded) await load();
    final liked = !isLiked(song);
    if (liked) {
      await _storage.addLikedSong(
        source: song.source,
        sourceId: '${song.id}',
        name: song.name,
        artist: song.artists.isEmpty ? null : song.artists.join(' / '),
        album: song.albumName,
        coverUrl: song.coverUrl,
        durationMs: song.durationMs,
        fee: song.fee,
      );
    } else {
      await _storage.removeLikedSong(
        source: song.source,
        sourceId: '${song.id}',
      );
    }
    if (_disposed) return liked;
    // 从磁盘重建内存集合，保证与落盘一致。
    final rows = await _storage.getLikedSongs();
    if (_disposed) return liked;
    _songs = List.unmodifiable(rows);
    _byKey = {
      for (final s in _songs) '${s.source}_${s.sourceId}': s,
    };
    notifyListeners();
    return liked;
  }
}