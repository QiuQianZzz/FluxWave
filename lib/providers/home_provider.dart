import 'package:flutter/foundation.dart';

import '../core/logging/app_log.dart';
import '../core/netease/netease_api.dart';
import '../core/netease/netease_client.dart';
import '../models/playlist.dart';

/// 首页「推荐歌单」状态：进入首页拉取一次，匿名即可用。
///
/// 纯内存态不落盘：推荐歌单随账号/时段变化、未登录也可用，离线兜底收益低。
/// 拉取失败置 [error] 交 UI 显示重试；已加载后重入不重拉，[reload] 才刷新。
/// 交互纪律同我的歌单：仅显式触发（进入页面/下拉刷新/重试），无自动轮询。
class HomeProvider extends ChangeNotifier {
  bool loading = false;
  Object? error;
  List<Playlist> playlists = const [];
  bool _loaded = false;

  /// 是否已成功拉取过（空列表也算，避免每次进 Tab 重拉）。
  bool get loaded => _loaded;

  /// 拉取推荐歌单；已加载时跳过（除非 [reload]）。
  Future<void> load(NeteaseApi api, {bool reload = false}) async {
    if (loading) return;
    if (!reload && _loaded) return;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final m = await api.recommendPlaylists(limit: 30);
      final code = m['code'];
      if (code != null && code != 200) {
        throw NeteaseException.non200(code as int, message: '推荐歌单加载失败');
      }
      final raw = m['result'];
      // 过滤「私人雷达」类个性化歌单。
      playlists = List.unmodifiable([
        if (raw is List)
          for (final e in raw)
            if (e is Map && !(e['name']?.toString().contains('雷达') ?? false))
              Playlist.fromJson(Map<String, dynamic>.from(e)),
      ]);
      _loaded = true;
      loading = false;
      error = null;
      notifyListeners();
    } catch (e, st) {
      AppLog.warn('推荐歌单加载失败', tag: 'home', error: e, stack: st);
      loading = false;
      error = e;
      notifyListeners();
    }
  }

  /// 重试 / 下拉刷新（强制重拉并保留旧数据上屏直到新数据回来）。
  Future<void> reload(NeteaseApi api) => load(api, reload: true);

  /// 复位（首页不常用；保留给登出等全局重置场景）。
  void clear() {
    loading = false;
    error = null;
    playlists = const [];
    _loaded = false;
    notifyListeners();
  }
}
