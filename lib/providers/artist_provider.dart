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
  // ── 公开只读状态 ──
  bool get loading => _loading;
  Object? get error => _error;
  ArtistDetail? get detail => _detail;
  int get followerCount => _followerCount;
  List<Song> get songs => _songs;
  List<AlbumSummary> get albums => _albums;
  bool get songsHasMore => _songsHasMore;
  bool get albumsHasMore => _albumsHasMore;
  bool get songsLoadingMore => _songsLoadingMore;
  bool get albumsLoadingMore => _albumsLoadingMore;
  Object? get songsError => _songsError;
  Object? get albumsError => _albumsError;

  // ── 内部可变状态 ──
  bool _loading = false;
  Object? _error;
  ArtistDetail? _detail;
  int _followerCount = 0;
  List<Song> _songs = const [];
  List<AlbumSummary> _albums = const [];
  bool _songsHasMore = false;
  bool _albumsHasMore = false;
  bool _songsLoadingMore = false;
  bool _albumsLoadingMore = false;
  Object? _songsError;
  Object? _albumsError;

  int _artistId = 0;
  int _songOffset = 0;
  int _albumOffset = 0;
  int _loadToken = 0;

  /// 加载歌手详情（并发拉取 detail + songs + albums）。
  ///
  /// 重复调用自动取消上一次未完成的请求。
  Future<void> loadArtist(NeteaseApi api, int id) async {
    if (_loading) {
      // 递增 token 使旧请求的 await 回来后检测到不匹配而丢弃。
      _loadToken++;
    }
    final savedToken = _loadToken;
    _artistId = id;
    _songOffset = 0;
    _albumOffset = 0;
    _loading = true;
    _error = null;
    notifyListeners();

    // 并发拉取三个接口，各自独立容错。
    ArtistDetail? loadedDetail;
    int loadedFollowerCount = 0;
    List<Song> loadedSongs = const [];
    bool loadedSongsMore = false;
    List<AlbumSummary> loadedAlbums = const [];
    bool loadedAlbumsMore = false;
    Object? detailErr;
    Object? songsErr;
    Object? albumsErr;

    // detail
    try {
      final resp = await api.artistDetail(id);
      if (_loadToken != savedToken) return;
      final detailData = resp['data'];
      final artist = (detailData is Map) ? detailData['artist'] : resp['artist'];
      if (artist is Map) {
        loadedDetail = ArtistDetail.fromJson(Map<String, dynamic>.from(artist));
      } else {
        loadedDetail = ArtistDetail(id: id, name: '');
      }
      if (detailData is Map) {
        loadedFollowerCount = detailData['followerCount'] as int? ?? 0;
      }
    } catch (e) {
      if (_loadToken != savedToken) return;
      detailErr = e;
    }

    // songs
    try {
      final resp = await api.artistSongs(id, limit: _kSongPageSize);
      if (_loadToken != savedToken) return;
      final rawSongs = resp['songs'];
      if (rawSongs is List) {
        loadedSongs = rawSongs
            .whereType<Map>()
            .map((s) => Song.fromSearch(Map<String, dynamic>.from(s)))
            .toList(growable: false);
      }
      loadedSongsMore = resp['more'] == true;
    } catch (e) {
      if (_loadToken != savedToken) return;
      songsErr = e;
    }

    // albums
    try {
      final resp = await api.artistAlbums(id, limit: _kAlbumPageSize);
      if (_loadToken != savedToken) return;
      final rawAlbums = resp['hotAlbums'];
      if (rawAlbums is List) {
        loadedAlbums = rawAlbums
            .whereType<Map>()
            .map((a) => AlbumSummary.fromJson(Map<String, dynamic>.from(a)))
            .where((a) => a.id > 0 && a.name.isNotEmpty)
            .toList(growable: false);
      }
      loadedAlbumsMore = resp['more'] == true;
    } catch (e) {
      if (_loadToken != savedToken) return;
      albumsErr = e;
    }

    if (_loadToken != savedToken) return;

    // 三项全失败才报错。
    if (loadedDetail == null && loadedSongs.isEmpty && loadedAlbums.isEmpty) {
      _loading = false;
      _error = detailErr ?? songsErr ?? albumsErr ?? Exception('加载失败');
      notifyListeners();
      return;
    }

    _detail = loadedDetail;
    _followerCount = loadedFollowerCount;
    _songs = loadedSongs;
    _songsHasMore = loadedSongsMore;
    _songsError = songsErr;
    _songOffset = _songs.length;
    _albums = loadedAlbums;
    _albumsHasMore = loadedAlbumsMore;
    _albumsError = albumsErr;
    _albumOffset = _albums.length;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  /// 加载更多歌曲（分页）。
  Future<void> loadMoreSongs(NeteaseApi api) async {
    final id = _artistId;
    final token = _loadToken;
    if (id <= 0 || _songsLoadingMore || !_songsHasMore) return;
    _songsLoadingMore = true;
    notifyListeners();

    try {
      final m = await api.artistSongs(id, offset: _songOffset, limit: _kSongPageSize);
      if (_loadToken != token) return;

      final raw = m['songs'];
      if (raw is List) {
        final page = raw
            .whereType<Map>()
            .map((s) => Song.fromSearch(Map<String, dynamic>.from(s)))
            .toList(growable: false);
        _songs = [..._songs, ...page];
        _songOffset += page.length;
      }
      _songsHasMore = m['more'] == true;
      _songsLoadingMore = false;
      notifyListeners();
    } catch (e, st) {
      if (_loadToken != token) return;
      AppLog.warn('歌手歌曲加载更多失败', tag: 'artist', error: e, stack: st);
      _songsLoadingMore = false;
      notifyListeners();
    }
  }

  /// 加载更多专辑（分页）。
  Future<void> loadMoreAlbums(NeteaseApi api) async {
    final id = _artistId;
    final token = _loadToken;
    if (id <= 0 || _albumsLoadingMore || !_albumsHasMore) return;
    _albumsLoadingMore = true;
    notifyListeners();

    try {
      final m = await api.artistAlbums(id, offset: _albumOffset, limit: _kAlbumPageSize);
      if (_loadToken != token) return;

      final raw = m['hotAlbums'];
      if (raw is List) {
        final page = raw
            .whereType<Map>()
            .map((a) => AlbumSummary.fromJson(Map<String, dynamic>.from(a)))
            .where((a) => a.id > 0 && a.name.isNotEmpty)
            .toList(growable: false);
        _albums = [..._albums, ...page];
        _albumOffset += page.length;
      }
      _albumsHasMore = m['more'] == true;
      _albumsLoadingMore = false;
      notifyListeners();
    } catch (e, st) {
      if (_loadToken != token) return;
      AppLog.warn('歌手专辑加载更多失败', tag: 'artist', error: e, stack: st);
      _albumsLoadingMore = false;
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
    _loading = false;
    _error = null;
    _detail = null;
    _followerCount = 0;
    _songs = const [];
    _albums = const [];
    _songsHasMore = false;
    _albumsHasMore = false;
    _songsLoadingMore = false;
    _albumsLoadingMore = false;
    _songsError = null;
    _albumsError = null;
    _artistId = 0;
    _songOffset = 0;
    _albumOffset = 0;
    _loadToken++;
    notifyListeners();
  }
}
