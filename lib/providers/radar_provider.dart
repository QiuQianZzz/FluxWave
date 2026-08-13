import 'package:flutter/foundation.dart';

import '../core/logging/app_log.dart';
import '../core/netease/netease_api.dart';
import '../core/netease/netease_client.dart';
import '../models/playlist.dart';

/// 雷达歌单固定 id（私人 / 会员 / 时光 / 乐迷 / 宝藏 / 新歌 / 神秘）。
/// 雷达没有「推荐歌单」那样的列表接口，只能按固定 id 逐个拉详情。每个雷达是账号专属虚拟歌单：id 固定、内容按账号
/// 会话即时生成。
const radarPlaylistIds = <int>[
  3136952023, // 私人雷达
  8402996200, // 会员雷达
  5320167908, // 时光雷达
  5327906368, // 乐迷雷达
  5362359247, // 宝藏雷达
  5300458264, // 新歌雷达
  5341776086, // 神秘雷达
];

/// 「雷达歌单」合集状态：仅在用户进入雷达页（显式触发）时预取一次。
///
/// - 需登录：未登录的账号拉取无意义，由 UI 层门控，这里不校验。
/// - 逐个拉详情（[api.playlistDetail]），`allSettled` 语义容忍个别失败
///   （如非会员的会员雷达被拒），成功项才保留，顺序按 [radarPlaylistIds]；
///   全部失败时置 [error]，页面据此走失败重试而非误导性空列表。
/// - 纯内存态不落盘：每个雷达随账号/时段变化；重拉走 [reload]，登出走 [clear]。
class RadarProvider extends ChangeNotifier {
  bool loading = false;
  Object? error;
  List<Playlist> radars = const [];
  bool _loaded = false;

  /// 是否已成功拉取过（失败后仍为 false，可重试）。
  bool get loaded => _loaded;

  /// 拉取雷达歌单；已加载时跳过（除非 [reload]）。
  Future<void> load(NeteaseApi api, {bool reload = false}) async {
    if (loading) return;
    if (!reload && _loaded) return;
    loading = true;
    error = null;
    notifyListeners();

    final results = await Future.wait(
      radarPlaylistIds.map((id) async {
        try {
          final m = await api.playlistDetail(id);
          final code = m['code'];
          if (code != null && code != 200) {
            throw NeteaseException.non200(code as int, message: '雷达歌单加载失败');
          }
          final raw = m['playlist'];
          if (raw is! Map) throw const FormatException('雷达歌单结果缺 playlist');
          return Playlist.fromJson(Map<String, dynamic>.from(raw));
        } catch (e) {
          AppLog.warn('雷达 $id 获取失败，跳过', tag: 'radar', error: e);
          return null;
        }
      }),
    );

    radars = List.unmodifiable(results.whereType<Playlist>());
    loading = false;
    if (radars.isEmpty) {
      // 全部失败：保持未加载态 + error，UI 走失败重试，不伪装成空列表。
      _loaded = false;
      error = NeteaseException('雷达歌单加载失败');
      notifyListeners();
      return;
    }
    error = null;
    _loaded = true;
    notifyListeners();
  }

  /// 重试 / 下拉刷新（强制重拉并保留旧数据上屏直到新数据回来）。
  Future<void> reload(NeteaseApi api) => load(api, reload: true);

  /// 复位（登出等全局重置场景）。
  void clear() {
    loading = false;
    error = null;
    radars = const [];
    _loaded = false;
    notifyListeners();
  }
}
