import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/playback_stats/playback_stats_models.dart';
import '../../providers/playback_stats_provider.dart';
import '../../widgets/page_scroll_view.dart';
import 'widgets/date_navigator.dart';
import 'widgets/duration_chart.dart';
import 'widgets/play_ranking.dart';
import 'widgets/playback_heatmap.dart';
import 'widgets/period_selector.dart';
import 'widgets/stats_summary.dart';

/// 播放记录页面
///
/// 入口：我的 → 本地 → 播放记录
/// 支持日/周/月/年/总筛选，查看播放时长分布、热力图、播放排行。
class PlaybackStatsPage extends StatefulWidget {
  const PlaybackStatsPage({super.key});

  @override
  State<PlaybackStatsPage> createState() => _PlaybackStatsPageState();
}

class _PlaybackStatsPageState extends State<PlaybackStatsPage> {
  late final PlaybackStatsProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = PlaybackStatsProvider();
    // 延迟到下一帧加载，避免在 build 中执行异步操作
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider.initialize();
    });
  }

  @override
  void dispose() {
    _provider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _provider,
      child: Scaffold(
        appBar: AppBar(title: const Text('播放记录')),
        body: Consumer<PlaybackStatsProvider>(
          builder: (context, provider, _) {
            if (provider.loading && provider.stats == null) {
              return const Center(child: CircularProgressIndicator());
            }

            if (provider.error != null) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 16),
                    Text('加载失败：${provider.error}'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => provider.loadStats(),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              );
            }

            return _buildContent(provider);
          },
        ),
      ),
    );
  }

  Widget _buildContent(PlaybackStatsProvider provider) {
    final stats = provider.stats;
    if (stats == null) {
      return const Center(child: Text('暂无播放记录'));
    }

    final isTotal = provider.selectedPeriod == StatsPeriod.total;

    return PageScrollView(
      slivers: [
        // 周期选择器（过渡期显示目标周期，禁用防重复点击）
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: PeriodSelector(
              selected: provider.selectedPeriod,
              onChanged: provider.transitioning ? null : provider.setPeriod,
            ),
          ),
        ),
        // 日期导航器（总视图隐藏）
        if (!isTotal)
          SliverToBoxAdapter(
            child: DateNavigator(
              period: provider.selectedPeriod,
              currentDate: provider.currentDate,
              onDateChanged: provider.setDate,
              onForward: provider.goForward,
              onBackward: provider.goBackward,
            ),
          ),
        // 统计卡片
        SliverToBoxAdapter(child: StatsSummary(stats: stats)),
        // 时长分布图表（日和总不显示）
        if (provider.period != StatsPeriod.day &&
            provider.period != StatsPeriod.total &&
            stats.dailyBreakdown.isNotEmpty)
          SliverToBoxAdapter(
            child: DurationChart(
              period: provider.period,
              dailyBreakdown: stats.dailyBreakdown,
            ),
          ),
        // 热力图（始终显示最近一年完整数据，与选中周期无关）
        if (provider.heatmapData.isNotEmpty)
          SliverToBoxAdapter(
            child: PlaybackHeatmap(data: provider.heatmapData),
          ),
        // 播放时间排行
        if (stats.topSongs.isNotEmpty)
          SliverToBoxAdapter(child: PlayRanking(items: stats.topSongs)),
        // 底部间距
        const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
      ],
    );
  }
}
