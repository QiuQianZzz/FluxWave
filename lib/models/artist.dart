/// 歌手简要信息（用于歌曲内的歌手引用、搜索结果等场景）。
class ArtistSummary {
  final int id;
  final String name;

  const ArtistSummary({required this.id, required this.name});

  factory ArtistSummary.fromJson(Map<String, dynamic> json) {
    return ArtistSummary(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// 歌手详情（歌手页头部完整信息）。
class ArtistDetail {
  final int id;
  final String name;
  final String? coverUrl;
  final String? avatarUrl;
  final String alias;
  final String briefDesc;
  final int musicSize;
  final int albumSize;
  final bool followed;

  const ArtistDetail({
    required this.id,
    required this.name,
    this.coverUrl,
    this.avatarUrl,
    this.alias = '',
    this.briefDesc = '',
    this.musicSize = 0,
    this.albumSize = 0,
    this.followed = false,
  });

  String? get coverSmall => _thumbnail(coverUrl);

  String? get avatarSmall => _thumbnail(avatarUrl);

  /// 原图（不缩略），用于歌手页背景大图。
  String? get coverFull => coverUrl;

  /// 原图（不缩略），用于歌手页头像。
  String? get avatarFull => avatarUrl;

  static String? _thumbnail(String? url, {int size = 100}) {
    if (url == null || url.isEmpty) return null;
    const marker = 'param=';
    if (url.contains(marker)) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url$sep$marker${size}y$size';
  }

  factory ArtistDetail.fromJson(Map<String, dynamic> json) {
    return ArtistDetail(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
      coverUrl: json['cover']?.toString() ?? json['picUrl']?.toString(),
      avatarUrl: json['avatar']?.toString() ?? json['img1v1Url']?.toString(),
      alias: (json['alias'] as List?)?.cast<String>().join(' / ') ?? '',
      briefDesc: json['briefDesc']?.toString() ?? '',
      musicSize: json['musicSize'] as int? ?? 0,
      albumSize: json['albumSize'] as int? ?? 0,
      followed: json['followed'] as bool? ?? false,
    );
  }
}
