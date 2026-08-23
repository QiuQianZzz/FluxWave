import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// AMLL TTML DB 客户端。
///
/// 按 songId 从 AMLL DB 镜像站直接下载 TTML 歌词。
/// URL 模板：`{baseUrl}/ncm-lyrics/{songId}.ttml`
///
/// 内置多个镜像源，按优先级依次尝试，首个成功即返回。
class AmllDbClient {
  const AmllDbClient._();

  /// AMLL DB 镜像站列表（按优先级排列）。
  static const mirrors = [
    'https://amlldb.bikonoo.com',
    'https://cdn.jsdmirror.cn/gh/Steve-xmh/amll-ttml-db@main',
    'https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/refs/heads/main',
  ];

  /// 按 songId 直接下载 TTML 歌词。
  ///
  /// 依次尝试 [mirrors] 中的镜像源，首个返回 200 且内容非空的即返回。
  /// 全部失败返回 null。
  static Future<String?> fetchTtml({
    required int songId,
    String? baseUrl,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final sources = baseUrl != null ? [baseUrl, ...mirrors] : mirrors;
    for (final base in sources) {
      final result = await _fetchFromMirror(base, songId, timeout);
      if (result != null) return result;
    }
    return null;
  }

  static Future<String?> _fetchFromMirror(
    String base,
    int songId,
    Duration timeout,
  ) async {
    final url = '$base/ncm-lyrics/$songId.ttml';
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(timeout);
      if (response.statusCode == 200) {
        final content = await response.transform(utf8.decoder).join();
        if (content.trim().isEmpty) return null;
        return content;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }
}
