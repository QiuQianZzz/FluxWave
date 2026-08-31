import 'package:flutter/foundation.dart';

import '../core/logging/app_log.dart';
import '../core/netease/netease_api.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';

const _kSongPageSize = 50;
const _kAlbumPageSize = 30;

/// 歌手详情页状态管理。
///
/// 对齐 NeriPlayer `NeteaseArtistDetailViewModel` 的并发加载 + 分页模式：
/// - `loadArtist` 并发拉取 detail + songs + albums（3 个 async）；
/// - `loadMoreSongs` / `loadMoreAlbums` 分页续拉；
/// - 重复调用 `loadArtist` 自动取消旧请求。
class ArtistProvider extends ChangeNotifier {
  bool loading = false;
  Object? error;
  ArtistDetail? detail;
  int followerCount = 0;
  List<Song> songs = const [];
  List<AlbumSummary> albums = const [];
  bool songsHasMore = false;
  bool albumsHasMore = false;
  bool songsLoadingMore = false;
  bool albumsLoadingMore = false;

  int _artistId = 0;
  int _songOffset = 0;
  int _albumOffset = 0;

  /// 加载歌手详情（并发拉取 detail + songs + albums）。
  ///
  /// 重复调用自动取消上一次未完成的请求。
  Future<void> loadArtist(NeteaseApi api, int id) async {
    if (loading) {
      // 取消旧请求：递增 artistId 使旧请求的 await 回来后检测到不匹配而丢弃。
      _artistId = -id; // 保证与新 id 不同
    }
    final savedId = id;
    _artistId = id;
    _songOffset = 0;
    _albumOffset = 0;
    loading = true;
    error = null;
    notifyListeners();

    try {
      // 并发拉取三个接口（对齐 NeriPlayer coroutineScope + async）。
      final results = await Future.wait([
        api.artistDetail(id),
        api.artistSongs(id, limit: _kSongPageSize),
        api.artistAlbums(id, limit: _kAlbumPageSize),
      ]);

      // 请求已被取消（用户快速切换歌手）。
      if (_artistId != savedId) return;

      final detailResp = results[0];
      final songsResp = results[1];
      final albumsResp = results[2];

      // 解析歌手详情。
      final detailData = detailResp['data'];
      final artist = (detailData is Map) ? detailData['artist'] : detailResp['artist'];
      if (artist is Map) {
        detail = ArtistDetail.fromJson(Map<String, dynamic>.from(artist));
      } else {
        detail = ArtistDetail(id: id, name: '');
      }

      // 解析粉丝数。
      final dynamicData = detailResp['data'];
      if (dynamicData is Map) {
        followerCount = dynamicData['followerCount'] as int? ?? 0;
      }

      // 解析歌曲列表。
      final rawSongs = songsResp['songs'];
      if (rawSongs is List) {
        songs = rawSongs
            .whereType<Map>()
            .map((s) => Song.fromSearch(Map<String, dynamic>.from(s)))
            .toList(growable: false);
      }
      songsHasMore = songsResp['more'] == true;
      _songOffset = songs.length;

      // 解析专辑列表。
      final rawAlbums = albumsResp['hotAlbums'];
      if (rawAlbums is List) {
        albums = rawAlbums
            .whereType<Map>()
            .map((a) => AlbumSummary.fromJson(Map<String, dynamic>.from(a)))
            .where((a) => a.id > 0 && a.name.isNotEmpty)
            .toList(growable: false);
      }
      albumsHasMore = albumsResp['more'] == true;
      _albumOffset = albums.length;

      loading = false;
      error = null;
      notifyListeners();
    } catch (e, st) {
      if (_artistId != savedId) return; // 旧请求的错误，丢弃
      AppLog.warn('歌手加载失败：$id', tag: 'artist', error: e, stack: st);
      loading = false;
      error = e;
      notifyListeners();
    }
  }

  /// 加载更多歌曲（分页）。
  Future<void> loadMoreSongs(NeteaseApi api) async {
    final id = _artistId;
    if (id <= 0 || songsLoadingMore || !songsHasMore) return;
    songsLoadingMore = true;
    notifyListeners();

    try {
      final m = await api.artistSongs(id, offset: _songOffset, limit: _kSongPageSize);
      if (_artistId != id) return;

      final raw = m['songs'];
      if (raw is List) {
        final page = raw
            .whereType<Map>()
            .map((s) => Song.fromSearch(Map<String, dynamic>.from(s)))
            .toList(growable: false);
        songs = [...songs, ...page];
        _songOffset += page.length;
      }
      songsHasMore = m['more'] == true;
      songsLoadingMore = false;
      notifyListeners();
    } catch (e, st) {
      if (_artistId != id) return;
      AppLog.warn('歌手歌曲加载更多失败', tag: 'artist', error: e, stack: st);
      songsLoadingMore = false;
      notifyListeners();
    }
  }

  /// 加载更多专辑（分页）。
  Future<void> loadMoreAlbums(NeteaseApi api) async {
    final id = _artistId;
    if (id <= 0 || albumsLoadingMore || !albumsHasMore) return;
    albumsLoadingMore = true;
    notifyListeners();

    try {
      final m = await api.artistAlbums(id, offset: _albumOffset, limit: _kAlbumPageSize);
      if (_artistId != id) return;

      final raw = m['hotAlbums'];
      if (raw is List) {
        final page = raw
            .whereType<Map>()
            .map((a) => AlbumSummary.fromJson(Map<String, dynamic>.from(a)))
            .where((a) => a.id > 0 && a.name.isNotEmpty)
            .toList(growable: false);
        albums = [...albums, ...page];
        _albumOffset += page.length;
      }
      albumsHasMore = m['more'] == true;
      albumsLoadingMore = false;
      notifyListeners();
    } catch (e, st) {
      if (_artistId != id) return;
      AppLog.warn('歌手专辑加载更多失败', tag: 'artist', error: e, stack: st);
      albumsLoadingMore = false;
      notifyListeners();
    }
  }

  /// 重试（强制重拉当前歌手）。
  Future<void> retry(NeteaseApi api) async {
    final id = _artistId;
    if (id <= 0) return;
    await loadArtist(api, id);
  }

  /// 复位（登出等全局重置场景）。
  void clear() {
    loading = false;
    error = null;
    detail = null;
    followerCount = 0;
    songs = const [];
    albums = const [];
    songsHasMore = false;
    albumsHasMore = false;
    songsLoadingMore = false;
    albumsLoadingMore = false;
    _artistId = 0;
    _songOffset = 0;
    _albumOffset = 0;
    notifyListeners();
  }
}
