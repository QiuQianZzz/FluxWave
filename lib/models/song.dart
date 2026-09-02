import 'artist.dart';

/// 歌曲音源的标识常量集。
///
/// 每条 [Song] 都携带所属音源做命名空间：持久化的播放队列、音频缓存 key、
/// 歌单详情缓存文件名等均依赖它区分「网易云 id 123」与「其它源 id 123」，
/// 避免跨源撞号串数据。未来接入酷狗/bilibili 时为各自新增常量即可。
class SongSource {
  const SongSource._();

  /// 网易云音乐。
  static const String netease = 'netease';
}

/// 歌曲模型：从网易云搜索结果解析。
///
/// 字段结构（id/name/artists/album/duration/fee），
/// 供搜索、播放队列、歌单等场景复用。多音源持久化经 [source] 命名空间。
class Song {
  /// 所属音源（默认网易云）。进队列/落盘必带，见 [SongSource]。
  final String source;

  final int id;
  final String name;
  final List<ArtistSummary> artists;
  final int? albumId;
  final String? albumName;
  final String? coverUrl;
  final int durationMs;
  final int fee; // 0 免费 1 VIP 4 专辑 8 单曲付费

  const Song({
    required this.id,
    required this.name,
    this.artists = const [],
    this.albumId,
    this.albumName,
    this.coverUrl,
    this.durationMs = 0,
    this.fee = 0,
    this.source = SongSource.netease,
  });

  /// 歌手展示（/ 分隔）。
  String get artistsLabel => artists.map((a) => a.name).join(' / ');

  /// 缩略封面 URL（CDN 按 `?param=100x100` 返回对应小图）。
  ///
  /// 列表/迷你播放只用小图，避免整图（300x300+）下载挤占带宽与 [imageCache]。
  /// 需要更大尺寸（如播放页封面）用 [coverFor]。
  String? get coverSmall => thumbnailUrl(coverUrl);

  /// 指定尺寸的封面 URL（供播放页/详情等场景按需取图）。
  String? coverFor(int size) => thumbnailUrl(coverUrl, size: size);

  /// 网易云图片缩略 URL 通用工具（封面/头像/歌单图等均可复用）。
  ///
  /// CDN 支持 `?param=WxH` 指定任意尺寸。空 URL 返回 null；
  /// URL 已带 `param=` 时原样返回，不重复追加。
  static String? thumbnailUrl(String? url, {int size = 100}) {
    if (url == null || url.isEmpty) return null;
    const marker = 'param=';
    if (url.contains(marker)) return url; // 已带尺寸参数，不重复追加
    final sep = url.contains('?') ? '&' : '?';
    return '$url$sep$marker${size}y$size';
  }

  /// 时长展示 mm:ss。
  String get durationLabel {
    final total = durationMs ~/ 1000;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 是否所有歌手 id 均为 0（来源如本地 SQLite 只存了名字）。
  bool get needsArtistIds =>
      artists.isNotEmpty && artists.every((a) => a.id == 0);

  /// 批量补全歌手 ID：找出 [needsArtistIds] 的歌曲，通过 [fetchByIds] 拉取
  /// 完整信息并替换。返回补全后的列表（与原列表等长，仅替换缺失项）。
  ///
  /// [fetchByIds] 应等价于 `NeteaseApi.songDetailByIds`，用回调避免循环依赖。
  static Future<List<Song>> ensureArtistIds(
    List<Song> songs,
    Future<List<Song>> Function(List<int> ids) fetchByIds,
  ) async {
    final indices = <int>[];
    for (var i = 0; i < songs.length; i++) {
      if (songs[i].needsArtistIds) indices.add(i);
    }
    if (indices.isEmpty) return songs;

    final ids = indices.map((i) => songs[i].id).toList();
    final fresh = await fetchByIds(ids);
    if (fresh.isEmpty) return songs;

    final freshMap = {for (final s in fresh) s.id: s};
    final result = List<Song>.from(songs);
    for (final idx in indices) {
      final updated = freshMap[result[idx].id];
      if (updated != null) result[idx] = updated;
    }
    return result;
  }

  /// 是否 VIP/付费内容。
  ///
  /// `fee` 语义：0=免费、1=VIP、4=购买专辑、8=会员高音质
  /// （**视作免费可听**）。故仅 1/4 视为付费，8 不算，避免误标角标。
  bool get isPaid => fee == 1 || fee == 4;

  /// 从搜索接口 `result.songs[]` / 歌单 `tracks[]` / song/detail `songs[]` 单曲解析。
  ///
  /// 同时兼容三处字段命名差异：artists/ar、album/al、duration/dt
  /// （歌单详情与 song/detail 的曲目用 `dt` 表示毫秒时长）。
  factory Song.fromSearch(Map<String, dynamic> json) {
    final rawArtists = json['artists'] ?? json['ar'];
    final artists = <ArtistSummary>[];
    if (rawArtists is List) {
      for (final a in rawArtists) {
        if (a is Map) {
          final id = a['id'] as int? ?? 0;
          final name = a['name']?.toString() ?? '';
          if (name.isNotEmpty) artists.add(ArtistSummary(id: id, name: name));
        }
      }
    }
    final album = json['album'] ?? json['al'];
    int? albumId;
    String? albumName;
    String? coverUrl;
    if (album is Map) {
      albumId = album['id'] as int?;
      albumName = album['name']?.toString();
      coverUrl = album['picUrl']?.toString() ?? album['pic']?.toString();
    }
    return Song(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
      artists: artists,
      albumId: albumId,
      albumName: albumName,
      coverUrl: coverUrl,
      durationMs: (json['duration'] ?? json['dt'] ?? 0) as int? ?? 0,
      fee: json['fee'] as int? ?? 0,
    );
  }

  /// 序列化为 JSON（供播放队列持久化）。
  Map<String, dynamic> toJson() => {
    'source': source,
    'id': id,
    'name': name,
    'artists': artists.map((a) => a.toJson()).toList(growable: false),
    'albumId': albumId,
    'albumName': albumName,
    'coverUrl': coverUrl,
    'durationMs': durationMs,
    'fee': fee,
  };

  /// 从 [toJson] 产物恢复；字段缺失时用安全默认值（容错坏数据）。
  factory Song.fromJson(Map<String, dynamic> json) {
    final rawArtists = json['artists'] as List?;
    List<ArtistSummary> artists;
    if (rawArtists != null && rawArtists.isNotEmpty) {
      final first = rawArtists.first;
      if (first is Map && first.containsKey('id')) {
        // 新格式：List<{id, name}>
        artists = rawArtists
            .whereType<Map>()
            .map((a) => ArtistSummary.fromJson(Map<String, dynamic>.from(a)))
            .toList(growable: false);
      } else {
        // 旧格式：List<String>（向后兼容）
        artists = rawArtists
            .map((e) => ArtistSummary(id: 0, name: e.toString()))
            .toList(growable: false);
      }
    } else {
      artists = const [];
    }
    return Song(
      source: json['source']?.toString() ?? SongSource.netease,
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      artists: artists,
      albumId: (json['albumId'] as num?)?.toInt(),
      albumName: json['albumName']?.toString(),
      coverUrl: json['coverUrl']?.toString(),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      fee: (json['fee'] as num?)?.toInt() ?? 0,
    );
  }
}
