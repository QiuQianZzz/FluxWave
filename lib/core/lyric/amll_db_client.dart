import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// AMLL TTML DB 客户端。
///
/// 按 songId 从 AMLL DB 镜像站直接下载 TTML 歌词。
/// URL 模板：`{baseUrl}/ncm-lyrics/{songId}.ttml`
class AmllDbClient {
  const AmllDbClient._();

  /// 默认 AMLL DB 镜像站地址。
  static const defaultBaseUrl = 'https://amlldb.bikonoo.com';

  /// 按 songId 直接下载 TTML 歌词。
  ///
  /// 返回 TTML XML 字符串；下载失败或 404 返回 null。
  static Future<String?> fetchTtml({
    required int songId,
    String baseUrl = defaultBaseUrl,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final url = '$baseUrl/ncm-lyrics/$songId.ttml';
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
