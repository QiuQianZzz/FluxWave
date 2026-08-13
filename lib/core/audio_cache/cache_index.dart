import 'dart:io';

import '../app_dirs.dart';

/// 缓存目录工具：管理每首歌的目录结构。
///
/// 目录结构：`cache/<songKey>/`，每首歌一个目录，包含：
/// - `audio.bin`：音频文件
/// - `cover.jpg`：封面图片（可选）
/// - `lyrics.txt`：歌词文本（可选）
///
/// 驱逐时直接删除整首歌目录，无需协调多个子目录。
class CacheIndex {
  CacheIndex._();

  /// 歌曲缓存键（`<source>_<songId>`）。
  static String songKey(String source, int songId) =>
      '${_sanitize(source)}_$songId';

  /// 从音频 key 提取歌曲 key（去掉 `_<level>_<type>` 后缀）。
  ///
  /// 音频 key 格式：`<source>_<songId>_<level>_<type>`
  static String? songKeyFromAudioKey(String audioKey) {
    final seg = audioKey.split('_');
    if (seg.length < 2) return null;
    // 旧格式首段即 songId（纯数字）。
    if (int.tryParse(seg[0]) != null) return seg[0];
    // 新格式：`<source>_<songId>_...`。
    if (seg.length >= 2) return '${seg[0]}_${seg[1]}';
    return null;
  }

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// 歌曲目录路径。
  static Future<Directory> songDir(String songKey) async {
    final cache = await appSupportDir('cache');
    return Directory('${cache.path}${Platform.pathSeparator}$songKey');
  }

  /// 删除歌曲目录（整首歌的所有缓存资源）。
  static Future<void> deleteSongDir(String songKey) async {
    try {
      final dir = await songDir(songKey);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
