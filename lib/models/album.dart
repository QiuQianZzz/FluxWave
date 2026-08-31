/// 专辑简要信息（歌手页专辑列表）。
class AlbumSummary {
  final int id;
  final String name;
  final String? picUrl;
  final int size;

  const AlbumSummary({
    required this.id,
    required this.name,
    this.picUrl,
    this.size = 0,
  });

  /// 缩略封面 URL（CDN 按 `?param=100x100` 返回对应小图）。
  String? get coverSmall {
    final url = picUrl;
    if (url == null || url.isEmpty) return null;
    const marker = 'param=';
    if (url.contains(marker)) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}param=100y100';
  }

  factory AlbumSummary.fromJson(Map<String, dynamic> json) {
    return AlbumSummary(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
      picUrl: json['picUrl']?.toString(),
      size: json['size'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'picUrl': picUrl,
    'size': size,
  };
}
