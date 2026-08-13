import 'package:flutter/foundation.dart';

import '../core/logging/app_log.dart';
import '../core/netease/netease_api.dart';
import '../core/netease/netease_client.dart';
import '../models/song.dart';

/// 「每日推荐」状态：进页拉取一次（对齐 Home/Radar 的内存态纪律）。
///
/// - **仅登录可用**：未登录由 UI 层门控跳登录，这里不校验（对齐 RadarProvider）。
/// - 每日 30 首歌曲（响应 `data.dailySongs[]`，结构兼容 [Song.fromSearch]）。
/// - 纯内存态不落盘：每日推荐随账号/日期变化；重拉走 [reload]，登出走 [clear]。
///   已加载后重入不重拉，仅显式刷新/下拉重新拉。
class DailyProvider extends ChangeNotifier {
  bool loading = false;
  Object? error;
  List<Song> songs = const [];
  bool _loaded = false;

  /// 是否已成功拉取过（空列表也算；失败后仍为 false，可重试）。
  bool get loaded => _loaded;

  /// 拉取每日推荐；已加载时跳过（除非 [reload]）。
  Future<void> load(NeteaseApi api, {bool reload = false}) async {
    if (loading) return;
    if (!reload && _loaded) return;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final m = await api.dailySongs();
      final code = m['code'];
      if (code != null && code != 200) {
        throw NeteaseException.non200(code as int, message: '每日推荐加载失败');
      }
      final raw = m['data'];
      songs = List.unmodifiable([
        if (raw is Map)
          for (final e in (raw['dailySongs'] ?? const []))
            if (e is Map) Song.fromSearch(Map<String, dynamic>.from(e)),
      ]);
      _loaded = true;
      loading = false;
      error = null;
      notifyListeners();
    } catch (e, st) {
      AppLog.warn('每日推荐加载失败', tag: 'daily', error: e, stack: st);
      loading = false;
      error = e;
      notifyListeners();
    }
  }

  /// 重试 / 下拉刷新（强制重拉并保留旧数据上屏直到新数据回来）。
  Future<void> reload(NeteaseApi api) => load(api, reload: true);

  /// 复位（登出等全局重置场景）。
  void clear() {
    loading = false;
    error = null;
    songs = const [];
    _loaded = false;
    notifyListeners();
  }
}
