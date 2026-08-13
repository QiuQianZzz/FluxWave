import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/netease/netease_api.dart';
import '../../core/netease/netease_client.dart';
import '../../core/logging/app_log.dart';
import '../../core/playlist_detail_cache.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../providers/netease_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/page_scroll_view.dart';
import '../../widgets/song_tile.dart';

/// 歌单详情页（只读浏览；本期不做红心/订阅/加删曲写操作）。
///
/// 数据流：先 `/api/v6/playlist/detail` 拿元数据 +
/// 前 ~1000 曲；缺口曲目（trackIds 中未返回的）按 [songDetailByIds] 每批 500
/// 补齐。进入即自动拉取；「播放全部」用 [PlayerProvider.playAt]（整单即队列）。
///
/// 二次进入走本地缓存秒显（[PlaylistDetailCache]，每单一张、LRU 限 10 张）：
/// 有缓存先上屏不转圈，后台刷新比对；网络失败但已有缓存时离线兜底（不置
/// error）。无缓存才展示加载态/失败重试。
///
/// 独立路由（本页唯一挂载方式）：经 tab 嵌套 Navigator push（首页/雷达/我的），
/// AppBar 自动返回按钮 + 系统返回 pop，并由框架 PredictiveBackPageTransitionsBuilder
/// 提供 Android 预测性返回手势。
class PlaylistDetailPage extends StatefulWidget {
  final int playlistId;

  const PlaylistDetailPage({super.key, required this.playlistId});

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  Playlist? _meta;
  List<Song> _tracks = const [];
  bool _loading = true;
  Object? _error;

  /// 详情磁盘缓存（每单一张，LRU 限 10 张）。
  final PlaylistDetailCache _cache = PlaylistDetailCache();

  @override
  void initState() {
    super.initState();
    _load();
  }

  NeteaseApi get _api => context.read<NeteaseProvider>().api;

  /// 加载流程：先读本地缓存秒显（若命中）→ 后台刷新网络比对 → 有变化才整体替换。
  ///
  /// 「先发布缓存再刷新网络」：
  /// - 有缓存：立即上屏不转圈；网络拉到大同小异时复用缓存列表，避免整面板跳动。
  /// - 网络失败但已有缓存：保留缓存继续用（离线可用），不置 error。
  /// - 无缓存且网络失败：才落 error 展示重试。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = _api;
    final id = widget.playlistId;

    // 缓存秒显：有本地底稿先上屏，让二次进入免白屏等待。
    final snapshot = await _cache.read(id);
    if (snapshot != null) {
      if (!mounted) return;
      setState(() {
        _meta = snapshot.meta;
        _tracks = snapshot.tracks;
        _loading = false;
      });
    }

    try {
      final fetched = await _fetchDetail(api, id);
      final changed =
          snapshot == null || !_sameTrackIds(snapshot.tracks, fetched.tracks);
      if (!mounted) return;
      setState(() {
        _meta = fetched.meta;
        if (changed) _tracks = fetched.tracks;
        _loading = false;
      });
      // 缓存是整张底稿：每次成功刷新都重写，保证最新曲目与 LRU mtime。
      final meta = fetched.meta;
      if (meta != null) {
        unawaited(_cache.write(id, meta, fetched.tracks));
      }
    } catch (e, st) {
      AppLog.warn('歌单详情加载失败 id=$id', tag: 'playlist', error: e, stack: st);
      if (!mounted) return;
      setState(() {
        // 有缓存 → 保留已上屏的离线数据，不置 error（对齐 PlaylistProvider）。
        if (snapshot == null) _error = e;
        _loading = false;
      });
    }
  }

  /// 拉取歌单详情（元数据 + 前段曲目 + 缺口补齐）并整成最终曲目列表。
  Future<({Playlist? meta, List<Song> tracks})> _fetchDetail(
    NeteaseApi api,
    int id,
  ) async {
    final m = await api.playlistDetail(id);
    final code = m['code'];
    if (code != null && code != 200) {
      throw NeteaseException.non200(code as int, message: '歌单加载失败');
    }
    final raw = m['playlist'];
    final meta = raw is Map
        ? Playlist.fromJson(Map<String, dynamic>.from(raw))
        : null;

    // 前 ~1000 曲（detail.tracks）
    final first = <Song>[];
    final firstIds = <int>{};
    final rawTracks = raw is Map ? raw['tracks'] : null;
    if (rawTracks is List) {
      for (final t in rawTracks) {
        if (t is Map) {
          final s = Song.fromSearch(Map<String, dynamic>.from(t));
          first.add(s);
          firstIds.add(s.id);
        }
      }
    }

    // 缺口曲目按 trackIds 补齐
    final missingIds = <int>[];
    final rawIds = raw is Map ? raw['trackIds'] : null;
    if (rawIds is List) {
      for (final t in rawIds) {
        if (t is Map) {
          final id = (t['id'] as num?)?.toInt();
          if (id != null && !firstIds.contains(id)) missingIds.add(id);
        }
      }
    }
    final rest = missingIds.isEmpty
        ? <Song>[]
        : await api.songDetailByIds(missingIds);

    return (meta: meta, tracks: List<Song>.unmodifiable([...first, ...rest]));
  }

  /// 两张曲目表是否同序同 id（决定网络结果是否值得替换缓存）。
  static bool _sameTrackIds(List<Song> a, List<Song> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _playAll() {
    if (_tracks.isEmpty) return;
    context.read<PlayerProvider>().playAt(_tracks, 0);
  }

  /// 随机播放全部：随机起点 + 进入随机模式。
  void _playShuffled() {
    if (_tracks.isEmpty) return;
    context.read<PlayerProvider>().playShuffled(_tracks);
  }

  /// 「我喜欢的音乐」等特殊歌单识别（对齐 [isLikedPlaylist]：specialType==5
  /// 或名称含「我喜欢的音乐」）。其 coverImgUrl 经常为空/无效，直接红心占位。
  static bool _isLikedPlaylist(Playlist p) =>
      p.specialType == 5 || p.name.contains('我喜欢的音乐');

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        // 名称已由头部（封面旁 [_PlaylistHeader]）展示，标题栏不再重复。
        title: const Text('歌单详情'),
      ),
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
            Icon(Icons.music_off_rounded, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text('歌单里还没有歌曲', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }
    final meta = _meta;
    // 歌单可能很大（接口一次可取 ~10 万首），改 lazy 构建：header 随列表
    // 滚动（SliverToBoxAdapter），歌曲主体用 SliverList.builder 惰性建房。
    return PageScrollView(
      slivers: [
        if (meta != null)
          SliverToBoxAdapter(
            child: _PlaylistHeader(
              meta: meta,
              trackCount: _tracks.length,
              isLiked: _isLikedPlaylist(meta),
              onPlayAll: _playAll,
              onShufflePlay: _playShuffled,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: SliverFixedExtentList(
            // 行高恒定 → 滚动偏移精确；首帧只构建可视区 + cacheExtent。
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

/// 歌单头部：封面 + 名称 + 统计 + 播放全部 / 随机播放全部。
class _PlaylistHeader extends StatelessWidget {
  final Playlist meta;
  final int trackCount;
  final bool isLiked;
  final VoidCallback onPlayAll;
  final VoidCallback onShufflePlay;
  const _PlaylistHeader({
    required this.meta,
    required this.trackCount,
    required this.isLiked,
    required this.onPlayAll,
    required this.onShufflePlay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final url = meta.coverFor(300);
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
                  meta.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$trackCount 首',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                if (meta.description != null && meta.description!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      meta.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: trackCount == 0 ? null : onPlayAll,
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: const Text('播放全部'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: trackCount == 0 ? null : onShufflePlay,
                      icon: const Icon(Icons.shuffle_rounded, size: 20),
                      label: const Text('随机播放全部'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverFallback(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHigh,
      child: Icon(
        Icons.queue_music_rounded,
        size: 40,
        color: cs.onSurfaceVariant,
      ),
    );
  }
}
