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
  late final ScrollController _scrollCtrl;
  final _heroKey = GlobalKey();

  /// 0.0 = 在顶部（透明），1.0 = 滚动到位（不透明）。
  double _scrollProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() => setState(() {}));
    _provider = ArtistProvider();
    _scrollCtrl = ScrollController();
    _scrollCtrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider.loadArtist(_api, widget.artistId);
    });
  }

  @override
  void dispose() {
    _scrollCtrl
      ..removeListener(_onScroll)
      ..dispose();
    _tabCtrl.dispose();
    _provider.dispose();
    super.dispose();
  }

  void _onScroll() {
    final ctx = _heroKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final heroTop = box.localToGlobal(Offset.zero).dy;
    // 背景图高度占 hero 卡片前 45%，滚出 app bar 底部时切换
    final bgHeight = box.size.height * 0.45;
    final done = heroTop + bgHeight <= 56;
    final p = done ? 1.0 : 0.0;
    if (p != _scrollProgress) {
      setState(() => _scrollProgress = p);
    }
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

    return Stack(
      children: [
        // ── 可滚动内容 ──
        CustomScrollView(
          controller: _scrollCtrl,
          slivers: [
            // hero 卡片从顶部开始，背景图延伸到透明 app bar 后方
            SliverToBoxAdapter(
              child: _ArtistHeroCard(
                key: _heroKey,
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
        // ── 浮动顶部栏（覆盖在内容上方） ──
        _ArtistFloatingAppBar(
          title: displayName,
          scrollProgress: _scrollProgress,
        ),
      ],
    );
  }
}

// =============================================================================
// 浮动顶部栏：透明覆盖在 hero 上方，滚动后渐变为不透明
// =============================================================================

class _ArtistFloatingAppBar extends StatelessWidget {
  final String title;
  final double scrollProgress;

  const _ArtistFloatingAppBar({
    required this.title,
    required this.scrollProgress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final solid = scrollProgress > 0;
    final bgColor = solid ? cs.surface : Colors.transparent;
    final fgColor = solid ? cs.onSurface : Colors.white;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: bgColor,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.arrow_back_rounded, color: fgColor),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: AnimatedOpacity(
                    opacity: solid ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fgColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
          ),
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
    super.key,
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

    final heroHeight = MediaQuery.sizeOf(context).width * 0.45;
    final clampedHeight = heroHeight.clamp(280.0, 400.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── 背景大图区域 ──
        SizedBox(
          height: clampedHeight,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 背景图（原图分辨率）
              if (coverUrl != null)
                CoverImage(url: coverUrl, fit: BoxFit.cover)
              else
                Container(color: cs.surfaceContainerHighest),
              // 渐变遮罩：顶部适度遮罩（返回按钮可读）→ 中间透明（展示图片）→ 底部深色（歌手名可读）
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black38,
                      Colors.transparent,
                      Colors.black26,
                      Colors.black87,
                    ],
                    stops: [0.0, 0.15, 0.6, 1.0],
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
                  SizedBox(
                    width: double.infinity,
                    child: _ExpandableText(text: d.briefDesc),
                  ),
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
  bool _needExpand = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void didUpdateWidget(covariant _ExpandableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _expanded = false;
      _needExpand = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    }
  }

  void _checkOverflow() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    const maxLinesHeight = 22.0 * 3 + 8;
    if (!mounted) return;
    setState(() => _needExpand = box.size.height > maxLinesHeight);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
        if (_needExpand) ...[
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
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
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
