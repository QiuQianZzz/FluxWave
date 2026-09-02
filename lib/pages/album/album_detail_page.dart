import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/navigation/artist_navigation.dart';
import '../../core/netease/netease_api.dart';
import '../../core/netease/netease_client.dart';
import '../../models/album.dart';
import '../../models/song.dart';
import '../../providers/netease_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/page_scroll_view.dart';
import '../../widgets/song_tile.dart';

/// 专辑详情页（只读浏览）。
///
/// 数据流：`/api/album/{id}` 一次拉取元数据 + 全部曲目，无需缺口补齐。
/// 复用 [PlaylistDetailPage] 的 Header + SongTile 列表模式。
class AlbumDetailPage extends StatefulWidget {
  final int albumId;
  final String? albumName;

  const AlbumDetailPage({super.key, required this.albumId, this.albumName});

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  AlbumDetail? _meta;
  List<Song> _tracks = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  NeteaseApi get _api => context.read<NeteaseProvider>().api;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final m = await _api.albumDetail(widget.albumId);
      final code = m['code'];
      AppLog.info(
        'albumDetail: code=$code, keys=${m.keys.toList()}, '
        'album=${m['album'] is Map ? (m['album'] as Map).keys.toList() : 'null'}, '
        'songs=${m['songs'] is List ? (m['songs'] as List).length : 'null'}',
        tag: 'album',
      );
      if (code != null && code != 200) {
        throw NeteaseException.non200(code as int, message: '专辑加载失败');
      }
      final rawAlbum = m['album'];
      final meta = rawAlbum is Map
          ? AlbumDetail.fromJson(Map<String, dynamic>.from(rawAlbum))
          : null;
      final tracks = <Song>[];
      // /api/v1/album/ 返回 songs 在顶层
      final rawSongs = m['songs'];
      if (rawSongs is List) {
        for (final s in rawSongs) {
          if (s is Map) {
            tracks.add(Song.fromSearch(Map<String, dynamic>.from(s)));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _tracks = List.unmodifiable(tracks);
        _loading = false;
      });
    } catch (e, st) {
      AppLog.warn('专辑详情加载失败 id=${widget.albumId}',
          tag: 'album', error: e, stack: st);
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _playAll() {
    if (_tracks.isEmpty) return;
    context.read<PlayerProvider>().playAt(_tracks, 0);
  }

  void _playAt(int index) {
    if (_tracks.isEmpty) return;
    context.read<PlayerProvider>().playAt(_tracks, index);
  }

  void _playNext(Song song) {
    context.read<PlayerProvider>().playNext(song);
    AppToast.show(context, '已添加到下一首播放「${song.name}」');
  }

  void _addToQueue(Song song) {
    context.read<PlayerProvider>().addToQueue(song);
    AppToast.show(context, '已添加到播放列表「${song.name}」');
  }

  void _navigateToArtist(int id, String name) {
    ArtistNavigation.onNavigateToArtist?.call(id, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.albumName ?? '专辑详情')),
      body: SafeArea(child: _buildBody(theme, cs)),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text(
              '加载失败：$_error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.album_rounded, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text('专辑里还没有歌曲', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }
    return PageScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _AlbumHeader(
            meta: _meta,
            trackCount: _tracks.length,
            onPlayAll: _playAll,
            onArtistTap: _navigateToArtist,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: SliverFixedExtentList(
            itemExtent: SongTile.kTileExtent,
            delegate: SliverChildBuilderDelegate(
              (context, i) => SongTile(
                song: _tracks[i],
                index: i,
                onTap: () => _playAt(i),
                onPlayNext: () => _playNext(_tracks[i]),
                onAddToQueue: () => _addToQueue(_tracks[i]),
              ),
              childCount: _tracks.length,
            ),
          ),
        ),
      ],
    );
  }
}

/// 专辑头部：封面 + 专辑名 + 歌手 + 发行时间 + 播放全部。
class _AlbumHeader extends StatelessWidget {
  final AlbumDetail? meta;
  final int trackCount;
  final VoidCallback onPlayAll;
  final void Function(int, String) onArtistTap;

  const _AlbumHeader({
    required this.meta,
    required this.trackCount,
    required this.onPlayAll,
    required this.onArtistTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final url = meta?.coverMedium;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 96,
              height: 96,
              child: (url != null && url.isNotEmpty)
                  ? CoverImage(url: url, placeholder: _coverFallback(cs))
                  : _coverFallback(cs),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta?.name ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                if (meta?.artistName != null)
                  GestureDetector(
                    onTap: meta?.artistId != null
                        ? () => onArtistTap(meta!.artistId!, meta!.artistName!)
                        : null,
                    child: Text(
                      meta!.artistName!,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: meta?.artistId != null
                            ? cs.primary
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  _buildSubtitle(meta, trackCount),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: trackCount == 0 ? null : onPlayAll,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('播放全部'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _buildSubtitle(AlbumDetail? meta, int trackCount) {
    final parts = <String>['$trackCount 首'];
    if (meta?.publishTime != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(meta!.publishTime!);
      parts.add('${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}');
    }
    final company = meta?.company;
    if (company != null && company.isNotEmpty) {
      parts.add(company);
    }
    return parts.join(' · ');
  }

  Widget _coverFallback(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHigh,
      child: Icon(Icons.album_rounded, size: 40, color: cs.onSurfaceVariant),
    );
  }
}
