import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../providers/netease_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/search_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/page_scroll_view.dart';
import '../widgets/collapsing_title.dart';
import '../widgets/song_tile.dart';

/// 搜索 Tab：搜索栏 + 空状态/结果列表。
///
/// 交互策略（对齐风控纪律）：**仅显式提交触发请求**（回车/搜索键/右侧按钮），
/// 不做输入防抖自动搜索。同关键词重复提交直接复用上次结果，不重发。
///
/// 搜索状态（结果/加载/错误/关键词）全部托管在 [SearchProvider]，本页仅持有
/// 输入框 [TextEditingController]：页签切换/滑动时本页 dispose，但结果与关键词
/// 跨 Tab 存活，重新进入时由 initState 从 provider 回填输入框。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller;

  /// 结果列表滚动进度 → 搜索大标题塌缩进度（0 展开 / 1 收起钉顶）。
  final ValueNotifier<double> _collapseT = ValueNotifier<double>(0);

  /// 大标题从展开（128）完全钉顶（工具栏 56）所需滚动的像素距离：
  /// 128 - 56 = 72。与 [CollapsingPinnedTitle] 的 expanded/collapsed 参数一致。
  static const double _kTitleExpandDelta = 72;

  @override
  void initState() {
    super.initState();
    // 从 provider 回填上次输入，实现跨 Tab 保留。
    _controller = TextEditingController(
      text: context.read<SearchProvider>().keyword,
    );
    // 输入变化只同步 provider 草稿（刷新清空按钮显隐），不触发搜索。
    _controller.addListener(_syncKeyword);
  }

  void _syncKeyword() {
    context.read<SearchProvider>().setKeyword(_controller.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    _collapseT.dispose();
    super.dispose();
  }

  /// 滚动通知 → 标题塌缩进度。仅结果列表滚动时有通知；空态/加载中/错误态
  /// 无可滚动体，标题保持展开。
  bool _onScroll(ScrollNotification notification) {
    final next = (notification.metrics.pixels / _kTitleExpandDelta).clamp(
      0.0,
      1.0,
    );
    if (next != _collapseT.value) _collapseT.value = next;
    return false;
  }

  Future<void> _submit([String? raw]) {
    _collapseT.value = 0;
    final text = raw ?? _controller.text;
    return context.read<SearchProvider>().submit(
      text,
      context.read<NeteaseProvider>().api,
    );
  }

  void _clear() {
    _collapseT.value = 0;
    _controller.clear();
    context.read<SearchProvider>().clear();
  }

  void _onSongTap(Song song, int index) {
    final player = context.read<PlayerProvider>();
    final sp = context.read<SearchProvider>();
    // 点击搜索结果：全部结果作为队列覆盖，从点击项开始播放。
    // 跳过提示 & 试听提示由 MainScaffold 监听 PlayerProvider 自动处理，
    // 不依赖此 Future 的 then 回调（Future 完成时机受网络+重试影响不可靠）。
    player.playAt(sp.songs, index);
  }

  /// 长按/右键：下一首播放
  void _onPlayNext(Song song) {
    context.read<PlayerProvider>().playNext(song);
    AppToast.show(context, '已添加到下一首播放「${song.name}」');
  }

  /// 长按/右键：追加到队列末尾
  void _onAddToQueue(Song song) {
    context.read<PlayerProvider>().addToQueue(song);
    AppToast.show(context, '已添加到播放列表「${song.name}」');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 搜索大标题（常驻钉顶）──
            // 对齐 Home/设置的折叠观感：结果列表向下滚时，大字「搜索」随
            // 塌缩进度缩小并钉在搜索框上方（跨 Tab 主 Tab 页一致）。
            ValueListenableBuilder<double>(
              valueListenable: _collapseT,
              builder: (context, t, _) => CollapsingPinnedTitle(
                text: '搜索',
                expandedHeight: 128,
                progress: t,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: _buildSearchBar(theme, cs),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: _buildBody(theme, cs),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme, ColorScheme cs) {
    final hasText = context.watch<SearchProvider>().keyword.trim().isNotEmpty;
    return SearchBar(
      controller: _controller,
      hintText: '搜索歌曲、歌手、专辑',
      textInputAction: TextInputAction.search,
      onSubmitted: _submit,
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      leading: const Icon(Icons.search_rounded, size: 22),
      trailing: [
        if (hasText)
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '清空',
            onPressed: _clear,
          ),
        IconButton(
          icon: const Icon(Icons.arrow_forward_rounded, size: 20),
          tooltip: '搜索',
          onPressed: () => _submit(),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme cs) {
    final sp = context.watch<SearchProvider>();
    if (!sp.submitted) {
      return const _EmptyState(
        icon: Icons.music_note_rounded,
        message: '搜索歌曲、歌手、专辑\n输入关键词后按回车或点击搜索',
      );
    }
    if (sp.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (sp.error != null) {
      return _ErrorState(error: sp.error!, onRetry: _submit);
    }
    if (sp.songs.isEmpty) {
      return _EmptyState(
        icon: Icons.music_off_rounded,
        message: '未找到与「${sp.lastKeyword}」相关的歌曲',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 8, 12, scrollBottomClearance(context)),
      itemCount: sp.songs.length,
      itemBuilder: (context, i) {
        final song = sp.songs[i];
        return SongTile(
          song: song,
          onTap: () => _onSongTap(song, i),
          onPlayNext: () => _onPlayNext(song),
          onAddToQueue: () => _onAddToQueue(song),
        );
      },
    );
  }
}

/// 空状态：居中图标 + 提示。
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 错误态：提示 + 重试。
class _ErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text(
              '搜索失败：$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
