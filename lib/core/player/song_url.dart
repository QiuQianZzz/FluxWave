import '../../models/song.dart';

/// 播放 URL 解析结果。
///
/// 仅承载"能否播放 / 是否试听 / 最终音质 / 码率 / 格式"，不依赖 Flutter，便于离线单测。
class SongUrlResult {
  final String url;
  final bool isTrial;
  final int fee;
  final String? level;

  /// 音频码率（bps，如 320000 = 320kbps）。
  final int br;

  /// 音频编码格式（如 'mp3' / 'flac' / 'ape'），小写字符串。
  final String? type;

  /// 文件大小（字节）。
  final int size;

  const SongUrlResult({
    required this.url,
    this.isTrial = false,
    this.fee = 0,
    this.level,
    this.br = 0,
    this.type,
    this.size = 0,
  });
}

/// 无可用播放地址（无版权 / 需会员）。
///
/// 标识非网络/解析类错误，UI 据此提示而不是重试。
class NoPlayableUrlException implements Exception {
  final String message;
  const NoPlayableUrlException([this.message = '当前歌曲无版权或需会员，无法播放']);

  @override
  String toString() => message;
}

/// 播放地址解析器：`/api/song/enhance/player/url/v1` 响应 → [SongUrlResult]。
///
/// 响应含
/// `data[0].url`（null = 无版权/需会员）+ `data[0].freeTrialInfo`（null = 完整版）。
class SongUrlResolver {
  const SongUrlResolver();

  /// 解析首个可播放项；无可用 url 返回 null（= 无版权/需会员，交由调用方提示）。
  static SongUrlResult? parse(Map<String, dynamic> body) {
    final code = body['code'];
    if (code != null && code != 200) return null;

    final data = body['data'];
    if (data is! List || data.isEmpty) return null;
    final first = data.first;
    if (first is! Map) return null;

    final url = first['url']?.toString();
    if (url == null || url.isEmpty) return null;

    final freeTrialInfo = first['freeTrialInfo'];
    final fee = first['fee'] as int? ?? 0;
    return SongUrlResult(
      url: _https(url),
      isTrial: freeTrialInfo != null,
      fee: fee,
      level: first['level']?.toString(),
      br: (first['br'] as num?)?.toInt() ?? 0,
      type: first['type']?.toString(),
      size: (first['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// 把 CDN 返回的 `http://` 播放地址升为 `https://`。
  ///
  /// 网易云 CDN（*.music.126.net）双协议均可访问；而 Android 9+ 默认禁用明文
  /// 流量，不改会直接播不出来。这里用本地 URL 转换更干净（零额外请求、不动网络配置、不留明文风险）。
  static String _https(String url) {
    if (url.startsWith('http://')) {
      return 'https://${url.substring(7)}';
    }
    return url;
  }

  /// 本地缓存挂点：命中返回可播放地址（完全离线、零网络），未命中返回 null。
  ///
  /// 这是 resolve 层的第一步，将来接入 `audio_cache` 或自建下载层时填充。
  /// MVP 阶段恒为 null（不缓存，每次从 CDN 流播）。
  static Future<SongUrlResult?> checkLocalCache(Song song) async => null;
}
