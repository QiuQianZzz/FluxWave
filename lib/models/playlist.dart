import 'song.dart';

/// 歌单模型：从 `/api/user/playlist` 与 `/api/v6/playlist/detail` 的
/// `playlist` 字段解析（两接口结构同构）。
///
/// [source] 命名空间（默认网易云，见 [SongSource]）：歌单详情缓存文件名、
/// 列表缓存 key 都按它区分不同音源下同 id 歌单，防跨源串数据。
class Playlist {
  final String source;
  final int id;
  final String name;
  final String? coverUrl;
  final String? description;
  final int? trackCount;
  final String? creatorNickname;
  final int? creatorId;
  final bool subscribed; // 是否收藏的他人歌单（user/playlist 专属字段）
  final int? specialType; // 5 = 「我喜欢的音乐」等特殊歌单

  const Playlist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.description,
    this.trackCount,
    this.creatorNickname,
    this.creatorId,
    this.subscribed = false,
    this.specialType,
    this.source = SongSource.netease,
  });

  /// 指定尺寸封面（列表/详情页按需取图）。
  String? coverFor(int size) => Song.thumbnailUrl(coverUrl, size: size);

  /// 歌单封面小图（列表用，300px，避免整图挤占带宽）。
  String? get coverSmall => coverFor(300);

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final creator = json['creator'];
    return Playlist(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      // 推荐接口（personalized/recommend/resource）的封面字段是 picUrl，
      // 歌单详情/列表是 coverImgUrl。
      coverUrl: json['coverImgUrl']?.toString() ?? json['picUrl']?.toString(),
      description: json['description']?.toString(),
      trackCount: (json['trackCount'] as num?)?.toInt(),
      creatorNickname: creator is Map ? creator['nickname']?.toString() : null,
      creatorId: creator is Map ? (creator['userId'] as num?)?.toInt() : null,
      subscribed: json['subscribed'] == true,
      specialType: (json['specialType'] as num?)?.toInt(),
      source: json['source']?.toString() ?? SongSource.netease,
    );
  }

  /// 序列化为 JSON（供歌单列表本地缓存放盘/读取）。
  ///
  /// 仅存元信息（名称/封面/曲数/创建者/specialType/source），不存曲目——
  /// 列表缓存只服务「我的」平铺页秒显与离线兜底，详情仍按需实时拉取。
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'coverImgUrl': coverUrl,
    'description': description,
    'trackCount': trackCount,
    'creatorNickname': creatorNickname,
    'creatorId': creatorId,
    'subscribed': subscribed,
    'specialType': specialType,
    'source': source,
  };
}

/// 是否为「我喜欢的音乐」歌单。
///
/// 创建者是本人 且
/// (specialType==5 || 名字含「我喜欢的音乐」)。比直接取 `playlists[0]`
/// 更稳（不依赖列表排序约定）。
bool isLikedPlaylist(Playlist p, int selfId) =>
    p.creatorId == selfId && (p.specialType == 5 || p.name.contains('我喜欢的音乐'));

/// 从歌单列表找出「我喜欢的音乐」歌单 id。
///
/// 按 [isLikedPlaylist] 扫描；找不到时兜底返回列表第一项（
/// `likedPlaylistId = playlists[0].id` 语义，绝大多数账号首项即我喜欢）。
int? findLikedPlaylistId(List<Playlist> list, int selfId) {
  for (final p in list) {
    if (isLikedPlaylist(p, selfId)) return p.id;
  }
  return list.isEmpty ? null : list.first.id;
}
