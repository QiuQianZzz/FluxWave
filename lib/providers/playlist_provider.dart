import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/logging/app_log.dart';
import '../core/netease/netease_api.dart';
import '../core/netease/netease_client.dart';
import '../models/playlist.dart';
import '../models/song.dart';

/// 「我的歌单」状态：一次性拉全用户歌单，页签切换不重新请求、数据保留。
///
/// 列表元信息会按 uid **持久化缓存到 SharedPreferences**（仅元信息，不含
/// 曲目，信息量小）。进入「我的」时先秒显本地缓存再后台静默刷新：网络失败
/// 时保留缓存数据走离线态，而不是清空列表。缓存失效判定：非 [reload] 且
/// 已有缓存时仍会刷新一次，实现「先展示再比对」。
///
/// 交互纪律同搜索页：仅显式触发（进入页面/下拉刷新/重试），无防抖自动请求。
class PlaylistProvider extends ChangeNotifier {
  /// 当前已加载的用户 id；null 表示未加载/登出。
  int? uid;

  /// 音源命名空间（默认网易云）。缓存键 `playlist_cache_<source>_<uid>`
  /// 按此隔离，防不同音源同 uid 串数据；后续接酷狗/bilibili 时由调用方
  /// 在 [load] 传入对应 [SongSource] 常量即可。
  String source = SongSource.netease;

  bool loading = false;
  Object? error;
  List<Playlist> playlists = const [];
  bool _loaded = false;

  /// 该 uid 是否有可用的本地缓存（内存态即定期持久化的缓存）。
  bool _usedCache = false;

  /// 该用户歌单是否已成功拉取过（空列表也算，避免每次进页都重拉）。
  bool get loaded => _loaded;

  /// 「我喜欢的音乐」歌单 id（找不到兜底首个）。
  int? get likedId => findLikedPlaylistId(playlists, uid ?? 0);

  /// 「我喜欢的音乐」歌单对象（无则为 null）。
  Playlist? get likedPlaylist {
    for (final p in playlists) {
      if (isLikedPlaylist(p, uid ?? 0)) return p;
    }
    return null;
  }

  /// 我创建的歌单（creator 是本人）。
  List<Playlist> get created => playlists
      .where((p) => p.id != likedId && p.creatorId == uid)
      .toList(growable: false);

  /// 收藏的他人歌单（creator 非本人，且非「我喜欢的音乐」）。
  List<Playlist> get collected => playlists
      .where((p) => p.creatorId != uid && p.id != likedId)
      .toList(growable: false);

  static String _cacheKey(String source, int userId) =>
      'playlist_cache_${source}_$userId';

  /// 拉取我的全部歌单。同 uid 同音源且已加载时跳过（除非 [reload]）。
  ///
  /// 流程：先读本地缓存（若有）立即上屏 → 再拉网络比对；
  /// 网络失败时有缓存则保留缓存（error 置空，走缓存态）。
  ///
  /// [source] 音源命名空间（默认 [SongSource.netease]），缓存键据此隔离。
  /// 换音源调用等同切换数据集：跳过判定要求 source 一致，否则重新拉取并切换
  /// [source] 字段，避免「数据是 A 源、source 字段却是 B 源」的错位。
  ///
  /// 分页拉全：首页 limit=1000 通常一次拿全；不足时按 offset 继续补齐
  /// 
  Future<void> load(
    int userId,
    NeteaseApi api, {
    bool reload = false,
    String source = SongSource.netease,
  }) async {
    // 仅「真已从网络拉到过」的会话跳过重拉；纯缓存态（_usedCache=true）仍需
    // 重进时刷一次网络比对（缓存先上屏，这里后台刷新）。source 一致才可跳过。
    if (!reload &&
        loaded &&
        uid == userId &&
        source == this.source &&
        !loading &&
        !_usedCache) {
      return;
    }
    this.source = source;
    uid = userId;
    loading = true;
    error = null;
    notifyListeners();

    try {
      // 缓存兜底：仅首次进入（当前 uid 无内存数据）时读缓存，避免每次进页
      // 又读一次磁盘；新数据到货后覆盖。
      if (!reload && !loaded) {
        await _restoreCache(userId, source);
      }

      final all = await _fetchAll(userId, api);

      playlists = List.unmodifiable(all);
      _loaded = true;
      _usedCache = false;
      loading = false;
      error = null;
      notifyListeners();
      await _persistCache(userId, source, all);
    } catch (e, st) {
      AppLog.warn('歌单加载失败 uid=$userId', tag: 'playlist', error: e, stack: st);
      // 网络失败 + 已有缓存 → 保留缓存数据，不置 error（离线可用）。
      if (_usedCache) {
        loading = false;
        notifyListeners();
      } else {
        error = e;
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 从本地缓存恢复当前 uid 的歌单（仅元信息，不入曲目）。
  Future<void> _restoreCache(int userId, String source) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(source, userId));
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final list = <Playlist>[
        for (final e in decoded)
          if (e is Map) Playlist.fromJson(Map<String, dynamic>.from(e)),
      ];
      if (list.isEmpty) return;
      playlists = List.unmodifiable(list);
      _loaded = true;
      _usedCache = true;
    } catch (e, st) {
      // 缓存损坏 → 忽略，走正常网络拉取
      AppLog.warn('歌单缓存读取失败 uid=$userId', tag: 'playlist', error: e, stack: st);
    }
  }

  Future<List<Playlist>> _fetchAll(int userId, NeteaseApi api) async {
    final all = <Playlist>[];
    var offset = 0;
    const limit = 1000;
    var total = limit; // 未知总量时按一次拿全推断
    while (offset < total && all.length < total) {
      final m = await api.userPlaylists(userId, limit: limit, offset: offset);
      final code = m['code'];
      if (code != null && code != 200) {
        throw NeteaseException.non200(code as int, message: '歌单加载失败');
      }
      final raw = m['playlist'];
      final batch = <Playlist>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) {
            batch.add(Playlist.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      all.addAll(batch);
      // count 为总歌单数；为空说明没有更多
      final count = m['count'];
      total = count is int ? count : batch.length;
      if (batch.isEmpty || (count is int && all.length >= count)) break;
      offset += limit;
    }
    return all;
  }

  /// 拉取成功后按 (source, uid) 落盘（仅元信息）。失败忽略（不影响当前会话）。
  Future<void> _persistCache(
    int userId,
    String source,
    List<Playlist> list,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode([for (final p in list) p.toJson()]);
      await prefs.setString(_cacheKey(source, userId), payload);
    } catch (e, st) {
      AppLog.warn('歌单缓存写入失败 uid=$userId', tag: 'playlist', error: e, stack: st);
    }
  }

  /// 复位内存态（登出/切换账号时调用）。
  ///
  /// 只清内存：`playlists`/`uid`/加载标记复位，避免登出后页面残留展示。
  /// **不删磁盘缓存**——列表按 `(source, uid)` 键控，换账号读不到旧数据、
  /// 无污染，保留磁盘数据让同账号重登还能秒显。真正的登出清理（cookie/
  /// 会话）由 [NeteaseProvider.logout] 负责，这里只管 UI 状态。
  void clear() {
    uid = null;
    loading = false;
    error = null;
    playlists = const [];
    _loaded = false;
    _usedCache = false;
    notifyListeners();
  }
}
