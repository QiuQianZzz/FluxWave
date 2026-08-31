import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/netease/netease_api.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/song.dart';
import '../../providers/artist_provider.dart';
import '../../providers/netease_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/song_tile.dart';

/// 歌手详情页。
///
/// 进入即自动拉取歌手详情 + 热门歌曲 + 专辑（并发）。
/// 支持歌曲/专辑 Tab 切换、分页加载更多。
class ArtistDetailPage extends StatefulWidget {
  final int artistId;
  final String? artistName;

  const ArtistDetailPage({
    super.key,
    required this.artistId,
    this.artistName,
  });

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  late final ArtistProvider _provider;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() => setState(() {}));
    _provider = ArtistProvider();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider.loadArtist(_api, widget.artistId);
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _provider.dispose();
    super.dispose();
  }

  NeteaseApi get _api => context.read<NeteaseProvider>().api;

  void _playAt(List<Song> songs, int index) {
    context.read<PlayerProvider>().playAt(songs, index);
  }

  void _playNext(Song song) {
    context.read<PlayerProvider>().playNext(song);
  }

  void _addToQueue(Song song) {
    context.read<PlayerProvider>().addToQueue(song);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _provider,
      child: Scaffold(
        body: Consumer<ArtistProvider>(
          builder: (context, state, _) {
            if (state.loading && state.detail == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state.error != null && state.detail == null) {
              return _buildError(state);
            }
            return _buildContent(state);
          },
        ),
      ),
    );
  }

  Widget _buildError(ArtistProvider state) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 56, color: cs.outlineVariant),
          const SizedBox(height: 16),
          Text(
            '${state.error}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => state.retry(_api),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ArtistProvider state) {
    final detail = state.detail;
    return CustomScrollView(
      slivers: [
        _ArtistSliverAppBar(
          detail: detail,
          artistName: widget.artistName,
        ),
        SliverToBoxAdapter(
          child: _ArtistHeader(detail: detail, followerCount: state.followerCount),
        ),
        SliverToBoxAdapter(
          child: _ArtistTabs(
            tabCtrl: _tabCtrl,
            songsCount: state.songs.length,
            albumsCount: state.albums.length,
          ),
        ),
        SliverToBoxAdapter(child: const SizedBox(height: 4)),
        if (_tabCtrl.index == 0) ...[
          if (state.songs.isEmpty && !state.loading)
            const SliverToBoxAdapter(child: _EmptyHint(text: '暂无歌曲'))
          else
            SliverFixedExtentList(
              itemExtent: SongTile.kTileExtent,
              delegate: SliverChildBuilderDelegate(
                (context, i) => SongTile(
                  song: state.songs[i],
                  index: i,
                  onTap: () => _playAt(state.songs, i),
                  onPlayNext: () => _playNext(state.songs[i]),
                  onAddToQueue: () => _addToQueue(state.songs[i]),
                ),
                childCount: state.songs.length,
              ),
            ),
          if (state.songsHasMore)
            SliverToBoxAdapter(
              child: _LoadMoreButton(
                loading: state.songsLoadingMore,
                onTap: () => state.loadMoreSongs(_api),
              ),
            ),
        ] else ...[
          if (state.albums.isEmpty && !state.loading)
            const SliverToBoxAdapter(child: _EmptyHint(text: '暂无专辑'))
          else
            SliverList.builder(
              itemCount: state.albums.length,
              itemBuilder: (context, i) => _AlbumTile(album: state.albums[i]),
            ),
          if (state.albumsHasMore)
            SliverToBoxAdapter(
              child: _LoadMoreButton(
                loading: state.albumsLoadingMore,
                onTap: () => state.loadMoreAlbums(_api),
              ),
            ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}

// =============================================================================
// SliverAppBar：背景大图 + 渐变 + 返回按钮
// =============================================================================

class _ArtistSliverAppBar extends StatelessWidget {
  final ArtistDetail? detail;
  final String? artistName;

  const _ArtistSliverAppBar({required this.detail, this.artistName});

  @override
  Widget build(BuildContext context) {
    final coverUrl = detail?.coverSmall ?? detail?.avatarSmall;
    final name = detail?.name ?? artistName ?? '';

    return SliverAppBar(
      expandedHeight: 260,
      pinned: true,
      stretch: true,
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (coverUrl != null)
              CoverImage(url: coverUrl, fit: BoxFit.cover)
            else
              Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
            // 渐变遮罩
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            // 底部歌手名
            if (detail != null)
              Positioned(
                left: 20,
                right: 20,
                bottom: 16,
                child: Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 歌手信息头部：头像 + 别名 + 统计 + 简介
// =============================================================================

class _ArtistHeader extends StatelessWidget {
  final ArtistDetail? detail;
  final int followerCount;

  const _ArtistHeader({required this.detail, required this.followerCount});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final d = detail;
    if (d == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像 + 名字 + 别名
          Row(
            children: [
              _Avatar(url: d.avatarSmall ?? d.coverSmall),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (d.alias.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        d.alias,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 统计 chips
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _StatChip(
                icon: Icons.music_note_rounded,
                label: '${d.musicSize} 首歌',
              ),
              _StatChip(
                icon: Icons.album_rounded,
                label: '${d.albumSize} 张专辑',
              ),
              if (followerCount > 0)
                _StatChip(
                  icon: Icons.people_rounded,
                  label: '$followerCount 粉丝',
                ),
            ],
          ),
          // 简介
          if (d.briefDesc.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              d.briefDesc,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  const _Avatar({this.url});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cs.surfaceContainerHighest,
      ),
      clipBehavior: Clip.antiAlias,
      child: url != null
          ? CoverImage(url: url!, fit: BoxFit.cover)
          : Icon(Icons.person_rounded, size: 36, color: cs.onSurfaceVariant),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// TabBar：歌曲 / 专辑
// =============================================================================

class _ArtistTabs extends StatelessWidget {
  final TabController tabCtrl;
  final int songsCount;
  final int albumsCount;

  const _ArtistTabs({
    required this.tabCtrl,
    required this.songsCount,
    required this.albumsCount,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: tabCtrl,
        labelColor: cs.primary,
        unselectedLabelColor: cs.onSurfaceVariant,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorWeight: 3,
        dividerHeight: 0,
        tabs: [
          Tab(text: '歌曲 ($songsCount)'),
          Tab(text: '专辑 ($albumsCount)'),
        ],
      ),
    );
  }
}

// =============================================================================
// 专辑行
// =============================================================================

class _AlbumTile extends StatelessWidget {
  final AlbumSummary album;
  const _AlbumTile({required this.album});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 48,
          height: 48,
          child: album.coverSmall != null
              ? CoverImage(url: album.coverSmall!, fit: BoxFit.cover)
              : Container(
                  color: cs.surfaceContainerHighest,
                  child: Icon(Icons.album_rounded, color: cs.onSurfaceVariant),
                ),
        ),
      ),
      title: Text(
        album.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${album.size} 首歌',
        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: cs.outline),
    );
  }
}

// =============================================================================
// 通用组件
// =============================================================================

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _LoadMoreButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;
  const _LoadMoreButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: loading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.outline),
              )
            : TextButton(
                onPressed: onTap,
                child: const Text('加载更多'),
              ),
      ),
    );
  }
}
