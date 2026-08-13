import 'package:flutter/foundation.dart';

import '../core/logging/app_log.dart';
import '../core/netease/netease_api.dart';
import '../core/netease/netease_client.dart';
import '../models/song.dart';

/// 搜索状态管理：跨 Tab 存活（页签切换/滑动时页面会 dispose，结果不丢）。
///
/// 交互策略（对齐风控纪律）：**仅显式提交触发请求**（回车/搜索键/右侧按钮），
/// 不做输入防抖自动搜索。同关键词重复提交直接复用上次结果，不重发。
class SearchProvider extends ChangeNotifier {
  /// 输入框内容（未提交前的草稿，切页后保留）。
  String keyword = '';

  /// 是否执行过搜索（决定空状态 vs 结果态）。
  bool submitted = false;

  bool loading = false;
  Object? error;
  List<Song> songs = const [];
  String lastKeyword = '';

  void setKeyword(String v) {
    if (v == keyword) return;
    keyword = v;
    notifyListeners();
  }

  /// 提交搜索。[text] 为输入框原始文本；空输入忽略。
  Future<void> submit(String text, NeteaseApi api) async {
    final t = text.trim();
    if (t.isEmpty) return;
    // 同关键词且已有结果 → 直接复用，不重发请求。
    if (lastKeyword == t && songs.isNotEmpty) {
      submitted = true;
      notifyListeners();
      return;
    }
    submitted = true;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final m = await api.search(t, limit: 30);
      final code = m['code'];
      if (code != null && code != 200) {
        throw NeteaseException.non200(code as int, message: '搜索失败');
      }
      final list = <Song>[];
      final result = m['result'];
      if (result is Map) {
        final raw = result['songs'];
        if (raw is List) {
          for (final s in raw) {
            if (s is Map) {
              list.add(Song.fromSearch(Map<String, dynamic>.from(s)));
            }
          }
        }
      }
      lastKeyword = t;
      songs = list;
      loading = false;
      notifyListeners();
    } catch (e, st) {
      AppLog.warn('搜索失败：$t', tag: 'search', error: e, stack: st);
      error = e;
      loading = false;
      notifyListeners();
    }
  }

  /// 清空输入与结果，回到初始空态。
  void clear() {
    keyword = '';
    submitted = false;
    loading = false;
    error = null;
    songs = const [];
    lastKeyword = '';
    notifyListeners();
  }
}
