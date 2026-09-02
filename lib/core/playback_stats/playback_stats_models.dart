import '../../core/logging/app_log.dart';
import '../../models/artist.dart';
import '../../models/song.dart';

/// 将艺术家名列表与 ID 列表配对为 [ArtistSummary] 列表。
///
/// 若 [ids] 为 null 或长度不匹配 [names]，缺失的 ID 填 0（兼容旧数据）。
List<ArtistSummary> _parseArtists(String? names, String? ids) {
  if (names == null || names.isEmpty) return const [];
  final nameList = names.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  if (nameList.isEmpty) return const [];
  final idList = ids?.split(',').map((s) => int.tryParse(s.trim()) ?? 0).toList();
  final artists = List.generate(
    nameList.length,
    (i) => ArtistSummary(
      id: (idList != null && i < idList.length) ? idList[i] : 0,
      name: nameList[i],
    ),
  );
  // 日志：解析结果
  final hasZeroId = artists.any((a) => a.id == 0);
  if (hasZeroId) {
    AppLog.warn(
      '_parseArtists: 存在 id=0 的歌手，跳转歌手页将不可用',
      tag: 'migration',
      error: {
        'names': names,
        'ids': ids,
        'parsed': artists.map((a) => '${a.id}:${a.name}').join(', '),
      },
    );
  }
  return artists;
}

/// 最近播放条目（去重时间线：每首歌一行，最新播放在前）。
class RecentPlay {
  final String source;
  final String sourceId;
  final String name;
  final String? artist;
  final String? artistIds;
  final String? album;
  final String? coverUrl;
  final int durationMs;
  final int fee;
  final int playedAt;

  const RecentPlay({
    required this.source,
    required this.sourceId,
    required this.name,
    this.artist,
    this.artistIds,
    this.album,
    this.coverUrl,
    this.durationMs = 0,
    this.fee = 0,
    required this.playedAt,
  });

  Map<String, dynamic> toMap() => {
    'source': source,
    'source_id': sourceId,
    'name': name,
    'artist': artist,
    'artist_ids': artistIds,
    'album': album,
    'cover_url': coverUrl,
    'duration_ms': durationMs,
    'fee': fee,
    'played_at': playedAt,
  };

  factory RecentPlay.fromMap(Map<String, dynamic> map) => RecentPlay(
    source: map['source'] as String,
    sourceId: map['source_id'] as String,
    name: map['name'] as String,
    artist: map['artist'] as String?,
    artistIds: map['artist_ids'] as String?,
    album: map['album'] as String?,
    coverUrl: map['cover_url'] as String?,
    durationMs: (map['duration_ms'] as int?) ?? 0,
    fee: (map['fee'] as int?) ?? 0,
    playedAt: map['played_at'] as int,
  );

  /// 转换为可播放的 [Song]（供列表点击播放）。
  Song toSong() => Song(
    source: source,
    id: int.tryParse(sourceId) ?? 0,
    name: name,
    artists: _parseArtists(artist, artistIds),
    albumName: album,
    coverUrl: coverUrl,
    durationMs: durationMs,
    fee: fee,
  );
}

/// 我喜欢的音乐条目（整曲快照，离线可渲染列表）。
class LikedSong {
  final String source;
  final String sourceId;
  final String name;
  final String? artist;
  final String? artistIds;
  final String? album;
  final String? coverUrl;
  final int durationMs;
  final int fee;
  final int likedAt;

  const LikedSong({
    required this.source,
    required this.sourceId,
    required this.name,
    this.artist,
    this.artistIds,
    this.album,
    this.coverUrl,
    this.durationMs = 0,
    this.fee = 0,
    required this.likedAt,
  });

  Map<String, dynamic> toMap() => {
    'source': source,
    'source_id': sourceId,
    'name': name,
    'artist': artist,
    'artist_ids': artistIds,
    'album': album,
    'cover_url': coverUrl,
    'duration_ms': durationMs,
    'fee': fee,
    'liked_at': likedAt,
  };

  factory LikedSong.fromMap(Map<String, dynamic> map) => LikedSong(
    source: map['source'] as String,
    sourceId: map['source_id'] as String,
    name: map['name'] as String,
    artist: map['artist'] as String?,
    artistIds: map['artist_ids'] as String?,
    album: map['album'] as String?,
    coverUrl: map['cover_url'] as String?,
    durationMs: (map['duration_ms'] as int?) ?? 0,
    fee: (map['fee'] as int?) ?? 0,
    likedAt: map['liked_at'] as int,
  );

  /// 转换为可播放的 [Song]（供列表点击播放）。
  Song toSong() => Song(
    source: source,
    id: int.tryParse(sourceId) ?? 0,
    name: name,
    artists: _parseArtists(artist, artistIds),
    albumName: album,
    coverUrl: coverUrl,
    durationMs: durationMs,
    fee: fee,
  );
}

/// 播放统计数据模型
class PlaybackStat {
  final String source;
  final String sourceId;
  final String name;
  final String? artist;
  final String? album;
  final String? coverUrl;
  final int durationMs;
  final int playCount;
  final int totalListenMs;
  final int firstPlayedAt;
  final int lastPlayedAt;

  const PlaybackStat({
    required this.source,
    required this.sourceId,
    required this.name,
    this.artist,
    this.album,
    this.coverUrl,
    this.durationMs = 0,
    this.playCount = 0,
    this.totalListenMs = 0,
    required this.firstPlayedAt,
    required this.lastPlayedAt,
  });

  Map<String, dynamic> toMap() => {
    'source': source,
    'source_id': sourceId,
    'name': name,
    'artist': artist,
    'album': album,
    'cover_url': coverUrl,
    'duration_ms': durationMs,
    'play_count': playCount,
    'total_listen_ms': totalListenMs,
    'first_played_at': firstPlayedAt,
    'last_played_at': lastPlayedAt,
  };

  factory PlaybackStat.fromMap(Map<String, dynamic> map) => PlaybackStat(
    source: map['source'] as String,
    sourceId: map['source_id'] as String,
    name: map['name'] as String,
    artist: map['artist'] as String?,
    album: map['album'] as String?,
    coverUrl: map['cover_url'] as String?,
    durationMs: (map['duration_ms'] as int?) ?? 0,
    playCount: (map['play_count'] as int?) ?? 0,
    totalListenMs: (map['total_listen_ms'] as int?) ?? 0,
    firstPlayedAt: map['first_played_at'] as int,
    lastPlayedAt: map['last_played_at'] as int,
  );
}

/// 按天分桶的播放统计
class PlaybackStatBucket {
  final int dayStart;
  final String source;
  final String sourceId;
  final int playCount;
  final int totalListenMs;
  final int firstPlayedAt;
  final int lastPlayedAt;

  const PlaybackStatBucket({
    required this.dayStart,
    required this.source,
    required this.sourceId,
    this.playCount = 0,
    this.totalListenMs = 0,
    required this.firstPlayedAt,
    required this.lastPlayedAt,
  });

  Map<String, dynamic> toMap() => {
    'day_start': dayStart,
    'source': source,
    'source_id': sourceId,
    'play_count': playCount,
    'total_listen_ms': totalListenMs,
    'first_played_at': firstPlayedAt,
    'last_played_at': lastPlayedAt,
  };

  factory PlaybackStatBucket.fromMap(Map<String, dynamic> map) =>
      PlaybackStatBucket(
        dayStart: map['day_start'] as int,
        source: map['source'] as String,
        sourceId: map['source_id'] as String,
        playCount: (map['play_count'] as int?) ?? 0,
        totalListenMs: (map['total_listen_ms'] as int?) ?? 0,
        firstPlayedAt: map['first_played_at'] as int,
        lastPlayedAt: map['last_played_at'] as int,
      );
}

/// 播放统计周期
enum StatsPeriod { day, week, month, year, total }

/// 日统计聚合结果
class DailyStat {
  final DateTime date;
  final int totalListenMs;
  final int songCount;
  final int playCount;

  const DailyStat({
    required this.date,
    required this.totalListenMs,
    required this.songCount,
    required this.playCount,
  });
}

/// 排行榜条目
class RankingItem {
  final String source;
  final String sourceId;
  final String name;
  final String? artist;
  final String? album;
  final String? coverUrl;
  final int durationMs;
  final int totalListenMs;
  final int playCount;
  final int firstPlayedAt;

  const RankingItem({
    required this.source,
    required this.sourceId,
    required this.name,
    this.artist,
    this.album,
    this.coverUrl,
    this.durationMs = 0,
    required this.totalListenMs,
    required this.playCount,
    required this.firstPlayedAt,
  });
}

/// 热力图数据点
class HeatmapEntry {
  final DateTime date;
  final int value; // 播放分钟数

  const HeatmapEntry({required this.date, required this.value});
}

/// 播放统计数据
class PlaybackStats {
  final int totalListenMs;
  final int uniqueSongs;
  final int playCount;
  final List<DailyStat> dailyBreakdown;
  final List<RankingItem> topSongs;
  final List<HeatmapEntry> heatmapData;

  const PlaybackStats({
    required this.totalListenMs,
    required this.uniqueSongs,
    required this.playCount,
    required this.dailyBreakdown,
    required this.topSongs,
    required this.heatmapData,
  });
}
