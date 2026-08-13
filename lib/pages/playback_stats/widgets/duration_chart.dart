import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/playback_stats/playback_stats_models.dart';

/// 时长分布柱状图（周7天/月30天/年12月）
class DurationChart extends StatelessWidget {
  final StatsPeriod period;
  final List<DailyStat> dailyBreakdown;

  const DurationChart({
    super.key,
    required this.period,
    required this.dailyBreakdown,
  });

  @override
  Widget build(BuildContext context) {
    if (dailyBreakdown.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final maxValueMs = dailyBreakdown
        .map((e) => e.totalListenMs)
        .fold<int>(0, (a, b) => a > b ? a : b);

    if (maxValueMs == 0) {
      return const SizedBox.shrink();
    }

    // 向上取整到整小时（分钟）：30min→60min, 90min→120min, 150min→180min
    final maxMinutes = maxValueMs / 60000.0;
    final roundedHours = (maxMinutes / 60).ceil();
    final maxYMinutes = (roundedHours * 60).toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxYMinutes,
                minY: 0,
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final stat = dailyBreakdown[group.x];
                      final minutes = stat.totalListenMs / 60000;
                      return BarTooltipItem(
                        '${stat.date.month}/${stat.date.day}\n'
                        '${minutes.toStringAsFixed(0)}分钟',
                        const TextStyle(color: Colors.white, fontSize: 12),
                      );
                    },
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) =>
                          _bottomTitle(value, meta, cs),
                      reservedSize: 28,
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      // 只显示最大刻度（顶部那一条）
                      interval: maxYMinutes,
                      reservedSize: 36,
                      getTitlesWidget: (value, meta) {
                        final hours = (value / 60).round();
                        return Text(
                          '${hours}h',
                          style: TextStyle(
                            fontSize: 10,
                            color: cs.onSurfaceVariant,
                          ),
                        );
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawHorizontalLine: true,
                  drawVerticalLine: false,
                  horizontalInterval: maxYMinutes,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: cs.outlineVariant.withValues(alpha: 0.3),
                    strokeWidth: 0.5,
                  ),
                ),
                barGroups: _buildBarGroups(cs),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _title {
    switch (period) {
      case StatsPeriod.week:
        return '本周播放时长分布';
      case StatsPeriod.month:
        return '本月播放时长分布';
      case StatsPeriod.year:
        return '本年播放时长分布';
      default:
        return '播放时长分布';
    }
  }

  List<BarChartGroupData> _buildBarGroups(ColorScheme cs) {
    return dailyBreakdown.asMap().entries.map((entry) {
      final index = entry.key;
      final stat = entry.value;
      final minutes = stat.totalListenMs / 60000;

      return BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: minutes,
            color: cs.primary.withValues(alpha: 0.7),
            width: _barWidth,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
        ],
      );
    }).toList();
  }

  double get _barWidth {
    switch (period) {
      case StatsPeriod.week:
        return 20;
      case StatsPeriod.month:
        return 6;
      case StatsPeriod.year:
        return 16;
      default:
        return 20;
    }
  }

  Widget _bottomTitle(double value, TitleMeta meta, ColorScheme cs) {
    final index = value.toInt();
    if (index < 0 || index >= dailyBreakdown.length) {
      return const SizedBox.shrink();
    }

    // 月视图只显示首/中/尾标签，避免 30+ 根柱子标签重叠
    if (period == StatsPeriod.month) {
      final last = dailyBreakdown.length - 1;
      final mid = last ~/ 2;
      if (index != 0 && index != mid && index != last) {
        return const SizedBox.shrink();
      }
    }

    final stat = dailyBreakdown[index];
    String text;

    switch (period) {
      case StatsPeriod.week:
        const days = ['一', '二', '三', '四', '五', '六', '日'];
        text = days[stat.date.weekday - 1];
        break;
      case StatsPeriod.month:
        text = '${stat.date.day}';
        break;
      case StatsPeriod.year:
        text = '${stat.date.month}月';
        break;
      default:
        text = '';
    }

    return SideTitleWidget(
      meta: meta,
      child: Text(
        text,
        style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
      ),
    );
  }
}
