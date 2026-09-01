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

  /// 歌手名是否已滚出可视区域（用于 SliverAppBar 标题显隐）。
  bool _nameScrolledOff = false;

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

  /// 滚动监听：检测歌手名是否已滚出顶部。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification && notification.depth == 0) {
      // 歌手名区域高度约 100px（头像68 + padding），超过此距离即视为已滚出。
      final off = notification.metrics.pixels > 100;
      if (off != _nameScrolledOff) {
        setState(() => _nameScrolledOff = off);
      }
    }
    return false;
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
            return _buildBody(state);
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

  Widget _buildBody(ArtistProvider state) {
    final detail = state.detail;
    final displayName = detail?.name ?? widget.artistName ?? '';

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: CustomScrollView(
        slivers: [
          _ArtistAppBar(
            title: displayName,
            showTitle: _nameScrolledOff,
          ),
          SliverToBoxAdapter(
            child: _ArtistHeroCard(
              detail: detail,
              artistName: widget.artistName,
              followerCount: state.followerCount,
            ),
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
      ),
    );
  }
}

// =============================================================================
// SliverAppBar：常驻返回按钮 + 条件显示歌手名
// =============================================================================

class _ArtistAppBar extends StatelessWidget {
  final String title;
  final bool showTitle;

  const _ArtistAppBar({
    required this.title,
    required this.showTitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      // 透明背景，滚动后变为 surface 色
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: AnimatedOpacity(
        opacity: showTitle ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

// =============================================================================
// Hero Card：背景大图 + 渐变 + 头像 + 名字 + 统计 + 简介
// =============================================================================

class _ArtistHeroCard extends StatelessWidget {
  final ArtistDetail? detail;
  final String? artistName;
  final int followerCount;

  const _ArtistHeroCard({
    required this.detail,
    this.artistName,
    required this.followerCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final d = detail;
    final name = d?.name ?? artistName ?? '';
    final coverUrl = d?.coverFull ?? d?.avatarFull;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── 背景大图区域 ──
        SizedBox(
          height: 280,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 背景图（原图分辨率）
              if (coverUrl != null)
                CoverImage(url: coverUrl, fit: BoxFit.cover)
              else
                Container(color: cs.surfaceContainerHighest),
              // 渐变遮罩
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black26,
                      Colors.black87,
                    ],
                    stops: [0.0, 0.35, 0.7, 1.0],
                  ),
                ),
              ),
              // 底部：头像 + 名字 + 别名
              if (d != null)
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 20,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _Avatar(url: d.avatarFull ?? d.coverFull),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                height: 1.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (d.alias.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                d.alias,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 13,
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
                ),
            ],
          ),
        ),
        // ── 信息区域 ──
        if (d != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                if (d.briefDesc.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _ExpandableText(text: d.briefDesc),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// 圆形头像
// =============================================================================

class _Avatar extends StatelessWidget {
  final String? url;
  const _Avatar({this.url});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cs.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: url != null
          ? CoverImage(url: url!, fit: BoxFit.cover)
          : Icon(Icons.person_rounded, size: 36, color: cs.onSurfaceVariant),
    );
  }
}

// =============================================================================
// 统计 Chip
// =============================================================================

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
// 可展开文本
// =============================================================================

class _ExpandableText extends StatefulWidget {
  final String text;
  const _ExpandableText({required this.text});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.5,
          ),
          maxLines: _expanded ? null : 3,
          overflow: _expanded ? null : TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            _expanded ? '收起' : '展开',
            style: theme.textTheme.labelMedium?.copyWith(
              color: cs.primary,
            ),
          ),
        ),
      ],
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
