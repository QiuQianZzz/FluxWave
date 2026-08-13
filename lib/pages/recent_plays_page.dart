import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/playback_stats/database_helper.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/page_scroll_view.dart';
import '../widgets/song_tile.dart';

/// 最近播放页：去重时间线（每首歌一行，最新在前），最多 500 条。
///
/// 记录来源见 [DatabaseHelper.recordRecentPlay]：播放真正启动即写入，
/// 无阈值。同一首重复播放会顶到最前；超过上限自动清理最旧。
class RecentPlaysPage extends StatefulWidget {
  const RecentPlaysPage({super.key});

  @override
  State<RecentPlaysPage> createState() => _RecentPlaysPageState();
}

class _RecentPlaysPageState extends State<RecentPlaysPage> {
  bool _loading = true;
  String? _error;
  List<Song> _songs = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final recent = await DatabaseHelper.instance.getRecentPlayed(
        limit: DatabaseHelper.maxRecentPlays,
      );
      if (!mounted) return;
      setState(() => _songs = recent.map((r) => r.toSong()).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _playAt(int index) {
    final player = context.read<PlayerProvider>();
    // 点击某首歌：整段最近播放作为队列，从点击项开始播放。
    player.playAt(_songs, index);
  }

  void _playAll() {
    if (_songs.isEmpty) return;
    context.read<PlayerProvider>().playAt(_songs, 0);
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
      appBar: AppBar(title: const Text('最近播放')),
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
    if (_songs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_off_rounded, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text('还没有播放记录', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(
              '播放过的歌曲会出现在这里',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return PageScrollView(
      slivers: [
        if (_songs.isNotEmpty)
          SliverToBoxAdapter(
            child: _Header(count: _songs.length, onPlayAll: _playAll),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          sliver: SliverList.builder(
            itemCount: _songs.length,
            itemBuilder: (context, i) {
              final song = _songs[i];
              return SongTile(
                song: song,
                index: i,
                onTap: () => _playAt(i),
                onPlayNext: () => _playNext(song),
                onAddToQueue: () => _addToQueue(song),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 头部：标题 + 播放全部按钮。
class _Header extends StatelessWidget {
  final int count;
  final VoidCallback onPlayAll;

  const _Header({required this.count, required this.onPlayAll});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Text(
            '共 $count 首',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          FilledButton.tonalIcon(
            onPressed: onPlayAll,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('播放全部'),
          ),
        ],
      ),
    );
  }
}