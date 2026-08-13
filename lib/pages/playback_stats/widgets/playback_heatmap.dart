import 'dart:math' as math;

import 'package:contribution_heatmap/contribution_heatmap.dart';
import 'package:flutter/material.dart';

import '../../../core/playback_stats/playback_stats_models.dart';

/// 播放热力图（GitHub 贡献图风格，统一显示最近一年完整数据）
///
/// 周几标签固定显示在左侧，右侧网格横向滚动，进入页面自动定位到最右侧（今天）。
/// 右下角带色块图例。
class PlaybackHeatmap extends StatefulWidget {
  final List<HeatmapEntry> data;

  const PlaybackHeatmap({super.key, required this.data});

  @override
  State<PlaybackHeatmap> createState() => _PlaybackHeatmapState();
}

class _PlaybackHeatmapState extends State<PlaybackHeatmap> {
  static const double _cellSize = 12;
  static const double _cellSpacing = 3;
  static const int _startWeekday = DateTime.monday;

  // githubLike 显示的三行周几：周一、周三、周五（周一开头的网格中行号 0/2/4）
  static const List<int> _labelRows = [0, 2, 4];
  static const List<String> _labelTexts = ['一', '三', '五'];
  static const List<String> _monthNames = [
    '1月',
    '2月',
    '3月',
    '4月',
    '5月',
    '6月',
    '7月',
    '8月',
    '9月',
    '10月',
    '11月',
    '12月',
  ];

  late final ScrollController _scrollController;
  bool _autoScrolled = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 布局完成后自动滚动到最右（今天），仅执行一次。
  void _scrollToRight() {
    if (_autoScrolled) return;
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    _autoScrolled = true;
    _scrollController.jumpTo(max);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty) return const SizedBox.shrink();

    // 数据就绪后首次 build 完成时跳到最右（今天）
    if (!_autoScrolled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToRight());
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.localeOf(context);

    final monthStyle = TextStyle(fontSize: 10, color: cs.onSurfaceVariant);
    final weekdayStyle = TextStyle(fontSize: 10, color: cs.onSurfaceVariant);

    final entries = widget.data
        .map((e) => ContributionEntry(e.date, e.value))
        .toList();

    Color colorScale(int value) {
      if (value == 0) return cs.surfaceContainerHighest;
      if (value < 10) return cs.primary.withValues(alpha: 0.2);
      if (value < 30) return cs.primary.withValues(alpha: 0.4);
      if (value < 60) return cs.primary.withValues(alpha: 0.6);
      return cs.primary;
    }

    // 与 ContributionHeatmap 内部相同的月份标签高度计算（height: 1.0 + 6）
    final monthLabelHeight =
        _measureTextHeight(
          'MMM',
          monthStyle.copyWith(height: 1.0),
          textScaler,
          locale,
        ) +
        6;

    final gridHeight = 7 * _cellSize + 6 * _cellSpacing;
    final contentHeight = monthLabelHeight + gridHeight;

    // 计算网格列数与月份标签位置（包内 HeatmapLocalizations 不支持中文，自行绘制）
    final dates = widget.data.map(
      (e) => DateTime.utc(e.date.year, e.date.month, e.date.day),
    );
    final actualFirst = dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final actualLast = dates.reduce((a, b) => a.isAfter(b) ? a : b);
    final alignedStart = _alignToWeekStart(actualFirst);
    final alignedEnd = _alignToWeekEnd(actualLast);
    final totalDays = alignedEnd.difference(alignedStart).inDays + 1;
    final totalColumns = (totalDays / 7).ceil();
    final gridWidth =
        totalColumns * _cellSize + math.max(0, totalColumns - 1) * _cellSpacing;

    final monthLabelEntries = _computeMonthLabels(
      alignedStart,
      actualFirst,
      actualLast,
      totalColumns,
    );

    final heatmap = ContributionHeatmap(
      entries: entries,
      customColorScale: colorScale,
      cellSize: _cellSize,
      cellSpacing: _cellSpacing,
      cellRadius: 3,
      showMonthLabels: false,
      weekdayLabel: WeekdayLabel.none,
      padding: EdgeInsets.zero,
      startWeekday: _startWeekday,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '播放热力图',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: contentHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _WeekdayLabels(
                  labels: _labelTexts,
                  rowOffsets: _labelRows,
                  height: contentHeight,
                  gridTop: monthLabelHeight,
                  cellSize: _cellSize,
                  cellSpacing: _cellSpacing,
                  textStyle: weekdayStyle.copyWith(height: 1.0),
                  textScaler: textScaler,
                  locale: locale,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _MonthLabels(
                          entries: monthLabelEntries,
                          width: gridWidth,
                          height: monthLabelHeight,
                          style: monthStyle.copyWith(height: 1.0),
                        ),
                        heatmap,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 右下角色块图例：少 — 色块阶梯 — 多
          Align(alignment: Alignment.centerRight, child: _buildLegend(cs)),
        ],
      ),
    );
  }

  static double _measureTextHeight(
    String text,
    TextStyle style,
    TextScaler textScaler,
    Locale locale,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      locale: locale,
    )..layout();
    return painter.height;
  }

  static DateTime _alignToWeekStart(DateTime date) {
    int diff = date.weekday - _startWeekday;
    if (diff < 0) diff += 7;
    return DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).subtract(Duration(days: diff));
  }

  static DateTime _alignToWeekEnd(DateTime date) {
    return _alignToWeekStart(date).add(const Duration(days: 6));
  }

  /// 计算各月第一周列的位置，生成中文月份标签。
  List<(double x, String label)> _computeMonthLabels(
    DateTime alignedStart,
    DateTime actualFirst,
    DateTime actualLast,
    int totalColumns,
  ) {
    final labels = <(double, String)>[];
    int? lastMonth;

    for (int col = 0; col < totalColumns; col++) {
      DateTime? firstDateInColumn;
      for (int row = 0; row < 7; row++) {
        final date = alignedStart.add(Duration(days: col * 7 + row));
        if (!date.isBefore(actualFirst) && !date.isAfter(actualLast)) {
          firstDateInColumn = date;
          break;
        }
      }
      if (firstDateInColumn == null) continue;

      final month = firstDateInColumn.month;
      if (lastMonth != month && firstDateInColumn.day <= 7) {
        final x = col * (_cellSize + _cellSpacing);
        labels.add((x, _monthNames[month - 1]));
        lastMonth = month;
      }
    }

    return labels;
  }

  /// 热力图色块图例（少 → 色阶 → 多）
  Widget _buildLegend(ColorScheme cs) {
    final blocks = [
      cs.surfaceContainerHighest,
      cs.primary.withValues(alpha: 0.2),
      cs.primary.withValues(alpha: 0.4),
      cs.primary.withValues(alpha: 0.6),
      cs.primary,
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('少', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
        const SizedBox(width: 6),
        ...blocks.map(
          (c) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text('多', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
      ],
    );
  }
}

/// 固定的周几标签列，与热力图网格行按同一几何公式对齐。
class _WeekdayLabels extends StatelessWidget {
  final List<String> labels;
  final List<int> rowOffsets;
  final double height;
  final double gridTop;
  final double cellSize;
  final double cellSpacing;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final Locale locale;

  const _WeekdayLabels({
    required this.labels,
    required this.rowOffsets,
    required this.height,
    required this.gridTop,
    required this.cellSize,
    required this.cellSpacing,
    required this.textStyle,
    required this.textScaler,
    required this.locale,
  });

  @override
  Widget build(BuildContext context) {
    final painters = labels.map((label) {
      return TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        locale: locale,
      )..layout();
    }).toList();

    var width = 0.0;
    for (final p in painters) {
      width = math.max(width, p.width);
    }

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          for (int i = 0; i < labels.length; i++)
            Positioned(
              left: 0,
              top:
                  gridTop +
                  rowOffsets[i] * (cellSize + cellSpacing) +
                  (cellSize - painters[i].height) / 2,
              child: Text(labels[i], style: textStyle),
            ),
        ],
      ),
    );
  }
}

/// 中文月份标签行，宽度与热力图网格一致，随网格同步横向滚动。
class _MonthLabels extends StatelessWidget {
  final List<(double x, String label)> entries;
  final double width;
  final double height;
  final TextStyle style;

  const _MonthLabels({
    required this.entries,
    required this.width,
    required this.height,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          for (final (x, label) in entries)
            Positioned(
              left: x,
              top: 0,
              child: Text(label, style: style),
            ),
        ],
      ),
    );
  }
}
