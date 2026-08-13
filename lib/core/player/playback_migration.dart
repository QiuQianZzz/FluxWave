import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/song.dart';
import 'playback_storage.dart';

/// 历史 SharedPreferences 键名（迁移只读源；新数据一律走 [PlayerPlaybackStorage]）。
const String kLegacySnapshotKey = 'playback_snapshot_v1'; // 最早：整份单键快照

/// 迁移：最早的单键整份快照 → 文件队列 + SP 状态。
///
/// 应用尚未分发，无中间版本数据（SP 队列时代 / 旧文件名均未落地到真实用户），
/// 故只保留这一条跨到当前格式的迁移。幂等且自终止：队列文件已存在 → 短路不动；
/// 源缺失/空/损坏 → 清旧键，不污染新会话。
Future<void> migrateLegacy(PlayerPlaybackStorage storage) async {
  final prefs = await SharedPreferences.getInstance();
  if (await storage.hasFileQueue()) return;
  final raw = prefs.getString(kLegacySnapshotKey);
  if (raw == null || raw.isEmpty) return;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      await prefs.remove(kLegacySnapshotKey);
      return;
    }
    final queue = (decoded['queue'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Song.fromJson)
        .toList();
    if (queue.isEmpty) {
      await prefs.remove(kLegacySnapshotKey);
      return;
    }
    final currentIndex = (decoded['currentIndex'] as num?)?.toInt();
    final positionMs = (decoded['positionMs'] as num?)?.toInt() ?? 0;
    final playing = decoded['playing'] as bool? ?? false;
    await storage.saveQueue(queue, currentIndex);
    await storage.saveState(positionMs: positionMs, playing: playing);
    await prefs.remove(kLegacySnapshotKey);
  } catch (_) {
    await prefs.remove(kLegacySnapshotKey);
  }
}
