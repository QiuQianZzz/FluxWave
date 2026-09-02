import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/navigation/app_nav.dart';
import '../models/playlist.dart';
import '../providers/netease_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/liked_songs_provider.dart';
import '../widgets/collapsing_title.dart';
import '../widgets/cover_image.dart';
import '../widgets/page_scroll_view.dart';
import 'playback_stats/playback_stats_page.dart';
import 'playlist/playlist_detail_page.dart';
import 'liked_songs_page.dart';
import 'recent_plays_page.dart';

/// 我的 Tab：顶部两段式（本地 / 在线）+ 大标题塌缩效果。
///
/// - **本地**：账号无关侧——本机的喜欢歌单、播放记录等本地能力入口；
/// - **在线**：账号侧——用户信息 + 歌单平铺（我喜欢的音乐置首），与登录态绑定。
///
/// 标题与切换条为每个分区内的 SliverAppBar + 钉顶 SliverPersistentHeader，
/// 两个分区经 IndexedStack 常驻，切换不丢各自状态（歌单详情/滚动位置）。
///
/// 歌单「全部平铺到最外层」：不设中间的「我的歌单」列表页，首页即平铺全部
/// 歌单（我喜欢的音乐置顶）。点击歌单 push 到本 tab 的嵌套 Navigator（与首页
/// 一致，见 [_ProfilePageState._openPlaylist]）——tab 栏与迷你播放栏保持可见，
/// 且由框架页路由提供 Android 预测性返回手势。
///
/// 已移除：统计行（数据不可靠）、头像刷新按钮（移到设置-账号）、"已登录"状态
/// 文案（用户自知）。宽屏时内容居中约束到最大 640，避免行内元素超长/留白过多。
class ProfilePage extends StatefulWidget {
  final ValueChanged<bool>? onDetailChanged;

  const ProfilePage({super.key, this.onDetailChanged});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  /// 已对哪个 uid 发起过歌单预取（避免失败后每次 build 重试造成请求循环）。
  int? _prefetchedUid;

  /// 顶部分区：0 = 本地（账号无关侧），1 = 在线（账号侧）。
  int _section = 0;

  Future<void> _navigateToLogin(BuildContext context) async {
    // 登录是全屏页，走根 Navigator（盖住迷你播放栏是预期行为）。
    await AppNav.pushNamedGlobal(context, '/login/qr');
    // 登录返回后可能已是登录态：首次 build 时 _maybePrefetchPlaylists 因
    // uid==null 提前跳过，didChangeDependencies 也不会二次触发，这里补拉，
    // 否则平铺列表会一直停在「还没有歌单」。
    _maybePrefetchPlaylists();
  }

  /// 已登录且未预取过 → 静默预取一次歌单（供歌单数/喜欢数展示）。
  /// 交互纪律同搜索页：进页预取一次，失败沉默走空态/重试，不自动循环。
  void _maybePrefetchPlaylists() {
    final auth = context.read<NeteaseProvider>();
    final pp = context.read<PlaylistProvider>();
    final uid = auth.userId;
    if (uid == null || pp.loading || pp.loaded) return;
    if (_prefetchedUid == uid) return;
    _prefetchedUid = uid;
    pp.load(uid, auth.api);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // didChangeDependencies 在 build 阶段同步执行；load() 会立刻 notifyListeners，
    // 直接调会触发"setState during build"。延到首帧后再预取。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybePrefetchPlaylists();
    });
  }

  Future<void> _openPlaylist(int id) async {
    // 与首页一致：push 到本 tab 的嵌套 Navigator，预测性返回由框架
    // PredictiveBackPageTransitionsBuilder 提供（内嵌方案没有该手势）。
    // 详情在栈上期间禁用页面横滑（onDetailChanged(true)），返回后恢复。
    widget.onDetailChanged?.call(true);
    await AppNav.push(context, PlaylistDetailPage(playlistId: id));
    if (mounted) widget.onDetailChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // IndexedStack 常驻两个分区，切换不丢各自状态（滚动位置）。
        child: IndexedStack(
          index: _section,
          children: [
            _buildTabPage((context, wide) => _localSlivers(context)),
            _buildTabPage(
              (context, wide) => _myMusicSlivers(context, wide),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个分区页：大标题（塌缩钉顶）+ 钉顶的「本地/在线」切换条 + 内容 slivers。
  ///
  /// 标题效果对齐 Home/设置：SliverAppBar 折叠大标题，滚动后缩为小档常驻；
  /// 切换条用 SliverPersistentHeader 钉顶（内容在其下方滚动）。
  Widget _buildTabPage(
    List<Widget> Function(BuildContext context, bool wide) sliversBuilder,
  ) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 700;
        return PageScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              primary: false,
              automaticallyImplyLeading: false,
              backgroundColor: theme.colorScheme.surface,
              expandedHeight: 128,
              flexibleSpace: CollapsingPinnedTitle(
                text: '我的',
                expandedHeight: 128,
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _SectionSwitcherHeader(
                section: _section,
                onChanged: (v) => setState(() => _section = v),
              ),
            ),
            ...sliversBuilder(context, wide),
          ],
        );
      },
    );
  }

  /// 在线分区内容 slivers：用户信息 + 歌单平铺（喜欢的音乐置顶）。
  List<Widget> _myMusicSlivers(BuildContext context, bool wide) {
    final provider = context.watch<NeteaseProvider>();
    final playlists = context.watch<PlaylistProvider>();

    if (provider.loading) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: _UserInfo(
          provider: provider,
          onLogin: () => _navigateToLogin(context),
          wide: wide,
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: _SectionLabel(text: '我的歌单'),
        ),
      ),
      ..._playlistSlivers(wide, provider, playlists),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];
  }

  /// 本地分区内容 slivers：账号无关入口（本地的喜欢 / 播放记录）。
  List<Widget> _localSlivers(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final liked = context.watch<LikedSongsProvider>();
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        sliver: SliverToBoxAdapter(
          child: Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _LocalEntryTile(
                  icon: Icons.favorite_rounded,
                  iconColor: cs.error,
                  title: '我喜欢的音乐',
                  subtitle: '${liked.count} 首',
                  onTap: () => AppNav.push(context, const LikedSongsPage()),
                ),
                const _TileDivider(),
                _LocalEntryTile(
                  icon: Icons.history_rounded,
                  iconColor: cs.primary,
                  title: '播放记录',
                  onTap: () => AppNav.push(context, const PlaybackStatsPage()),
                ),
                const _TileDivider(),
                _LocalEntryTile(
                  icon: Icons.watch_later_rounded,
                  iconColor: cs.primary,
                  title: '最近播放',
                  onTap: () => AppNav.push(context, const RecentPlaysPage()),
                ),
              ],
            ),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];
  }

  /// 返回歌单区的 slivers：按 [wide] 区分窄屏单列平铺与宽屏卡片网格。
  List<Widget> _playlistSlivers(
    bool wide,
    NeteaseProvider auth,
    PlaylistProvider pp,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (!auth.isLoggedIn) {
      // 头部已有「登录」按钮，这里只保留提示文案，不重复放二维码入口。
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _EmptyCard(
              icon: Icons.lock_outline_rounded,
              message: '登录后查看你的歌单',
            ),
          ),
        ),
      ];
    }
    if (pp.loading && !pp.loaded) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (pp.error != null && !pp.loaded) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _EmptyCard(
              icon: Icons.cloud_off_rounded,
              message: '歌单加载失败',
              actionLabel: '重试',
              onAction: _kickLoad,
            ),
          ),
        ),
      ];
    }

    final liked = pp.likedPlaylist;
    final created = pp.created;
    final collected = pp.collected;

    if (liked == null && created.isEmpty && collected.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _EmptyCard(
              icon: Icons.queue_music_rounded,
              message: '还没有歌单',
              actionLabel: '刷新',
              onAction: () => _kickLoad(reload: true),
            ),
          ),
        ),
      ];
    }

    if (!wide) {
      // 窄屏：单列平铺，喜欢的音乐置顶。
      final tiles = <Widget>[
        if (liked != null) ...[
          _PlaylistTile(
            playlist: liked,
            isLiked: true,
            onTap: () => _openPlaylist(liked.id),
          ),
          if (created.isNotEmpty || collected.isNotEmpty) const _TileDivider(),
        ],
        for (var i = 0; i < created.length; i++) ...[
          _PlaylistTile(
            playlist: created[i],
            onTap: () => _openPlaylist(created[i].id),
          ),
          if (i < created.length - 1 || collected.isNotEmpty)
            const _TileDivider(),
        ],
        for (var i = 0; i < collected.length; i++)
          _PlaylistTile(
            playlist: collected[i],
            onTap: () => _openPlaylist(collected[i].id),
          ),
      ];
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(children: tiles),
            ),
          ),
        ),
      ];
    }

    // 宽屏：卡片网格（封面尺寸与首页推荐卡一致 maxCrossAxisExtent 180，
    // 随宽度增多列数但不放大单卡，避免卡片随屏加宽；喜欢的音乐也作卡片置顶，
    // 红心标区分）。
    final items = <Playlist>[?liked, ...created, ...collected];
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.82,
          ),
          delegate: SliverChildBuilderDelegate((context, i) {
            final p = items[i];
            final isLiked = liked != null && p.id == liked.id;
            return _PlaylistCard(
              playlist: p,
              isLiked: isLiked,
              onTap: () => _openPlaylist(p.id),
            );
          }, childCount: items.length),
        ),
      ),
    ];
  }

  void _kickLoad({bool reload = false}) {
    final auth = context.read<NeteaseProvider>();
    final uid = auth.userId;
    if (uid == null) return;
    context.read<PlaylistProvider>().load(uid, auth.api, reload: reload);
  }
}

/// 歌单行：封面 + 名称 + 曲数；喜欢的音乐置顶并用红心封面。
class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final bool isLiked;
  final VoidCallback onTap;
  const _PlaylistTile({
    required this.playlist,
    this.isLiked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _PlaylistCover(playlist: playlist, isLiked: isLiked),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isLiked)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.favorite_rounded,
                              size: 16,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        Flexible(
                          child: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${playlist.trackCount ?? 0} 首',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: cs.onSurfaceVariant,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 歌单封面 56x56：喜欢音乐用真实封面 + 半透明蒙层 + 中央红心；
/// 其余用缩略图，加载失败兜底为带图标色块。
class _PlaylistCover extends StatelessWidget {
  final Playlist playlist;
  final bool isLiked;
  const _PlaylistCover({required this.playlist, this.isLiked = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final url = playlist.coverSmall;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 56,
        height: 56,
        child: (url != null && url.isNotEmpty)
            ? CoverImage(url: url, placeholder: _fallback(cs))
            : _fallback(cs),
      ),
    );
  }

  Widget _fallback(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHigh,
      child: Icon(
        Icons.queue_music_rounded,
        size: 28,
        color: cs.onSurfaceVariant,
      ),
    );
  }
}

/// 宽屏网格歌单卡片：样式对齐首页推荐卡（方形封面在上、名称/曲数在下），
/// maxCrossAxisExtent 180 保证不随屏宽放大；喜欢的音乐带红心标。
class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final bool isLiked;
  final VoidCallback onTap;
  const _PlaylistCard({
    required this.playlist,
    this.isLiked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final url = playlist.coverSmall;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox.square(
                dimension: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: (url != null && url.isNotEmpty)
                      ? CoverImage(
                          url: url,
                          placeholder: const CoverPlaceholder(icon: Icons.queue_music_rounded),
                        )
                      : const CoverPlaceholder(icon: Icons.queue_music_rounded),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (isLiked) ...[
                  Icon(Icons.favorite_rounded, size: 14, color: cs.error),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            if (playlist.trackCount != null)
              Text(
                '${playlist.trackCount}首',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

}

/// 行间细分隔线（喜欢的置顶行与其余行之间均使用）。
class _TileDivider extends StatelessWidget {
  const _TileDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.5,
      indent: 14,
      endIndent: 14,
      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}

/// 空/错误/未登录态卡片：居左图标 + 文案 +（可选）操作按钮。
class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _EmptyCard({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final actionLabel = this.actionLabel;
    final onAction = this.onAction;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: cs.outlineVariant),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// 用户信息区：头像 + 昵称 + 登录按钮（简约，无渐变）。
///
/// 布局响应式：窄屏登录按钮放在头像栏下方（避免长昵称被截断/按钮挤占）；
/// 宽屏放右侧。退出登录已移到设置-账号，本页不展示。
class _UserInfo extends StatelessWidget {
  final NeteaseProvider provider;
  final VoidCallback onLogin;
  final bool wide;
  const _UserInfo({
    required this.provider,
    required this.onLogin,
    required this.wide,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final avatar = provider.isLoggedIn && provider.avatarUrl != null
        ? CircleAvatar(
            backgroundImage: NetworkImage(provider.avatarUrl!),
            radius: 32,
          )
        : CircleAvatar(
            radius: 32,
            backgroundColor: cs.surfaceContainerHighest,
            child: Icon(
              Icons.person_rounded,
              size: 36,
              color: cs.onSurfaceVariant,
            ),
          );
    final name = Text(
      provider.isLoggedIn ? (provider.nickname ?? '用户') : '未登录',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    );
    final loginButton = FilledButton.icon(
      onPressed: onLogin,
      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
      label: const Text('登录'),
    );

    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: 16),
            Expanded(child: name),
            if (!provider.isLoggedIn) loginButton,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              avatar,
              const SizedBox(width: 16),
              Expanded(child: name),
            ],
          ),
          if (!provider.isLoggedIn) ...[
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: loginButton),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 我的页顶部分区切换：在线（账号侧）/ 本地（账号无关侧）。
///
/// 样式对齐设置页主题切换的 SegmentedButton（紧凑 + 无选中对勾），两个短标签
/// 在窄屏也不换行。
class _SectionSwitcher extends StatelessWidget {
  final int section;
  final ValueChanged<int> onChanged;
  const _SectionSwitcher({required this.section, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(
          value: 0,
          label: Text('本地'),
          icon: Icon(Icons.storage_rounded, size: 18),
        ),
        ButtonSegment(
          value: 1,
          label: Text('在线'),
          icon: Icon(Icons.cloud_outlined, size: 18),
        ),
      ],
      selected: {section},
      onSelectionChanged: (v) => onChanged(v.first),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity(horizontal: -1, vertical: -1),
      ),
    );
  }
}

/// 钉顶的切换条：内容滚动时切换条固定在标题下方（SliverPersistentHeader）。
class _SectionSwitcherHeader extends SliverPersistentHeaderDelegate {
  final int section;
  final ValueChanged<int> onChanged;
  _SectionSwitcherHeader({required this.section, required this.onChanged});

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: _SectionSwitcher(section: section, onChanged: onChanged),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SectionSwitcherHeader oldDelegate) =>
      oldDelegate.section != section;
}

/// 本地方向入口行：图标块 + 标题 +（可选计数/副标题）+ 右箭头（对齐歌单行视觉）。
class _LocalEntryTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  const _LocalEntryTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final subtitle = this.subtitle;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: cs.onSurfaceVariant,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
