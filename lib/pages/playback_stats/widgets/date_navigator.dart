import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/playback_stats/playback_stats_models.dart';

/// 日期导航器（左右切换日期/周/月/年）
class DateNavigator extends StatelessWidget {
  final StatsPeriod period;
  final DateTime currentDate;
  final ValueChanged<DateTime> onDateChanged;
  final VoidCallback onForward;
  final VoidCallback onBackward;

  const DateNavigator({
    super.key,
    required this.period,
    required this.currentDate,
    required this.onDateChanged,
    required this.onForward,
    required this.onBackward,
  });

  @override
  Widget build(BuildContext context) {
    if (period == StatsPeriod.total) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: onBackward,
            tooltip: '上一个$_periodLabel',
          ),
          Text(
            _displayText,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: onForward,
            tooltip: '下一个$_periodLabel',
          ),
        ],
      ),
    );
  }

  String get _periodLabel {
    switch (period) {
      case StatsPeriod.day:
        return '天';
      case StatsPeriod.week:
        return '周';
      case StatsPeriod.month:
        return '月';
      case StatsPeriod.year:
        return '年';
      case StatsPeriod.total:
        return '';
    }
  }

  String get _displayText {
    switch (period) {
      case StatsPeriod.day:
        return DateFormat('yyyy年M月d日').format(currentDate);
      case StatsPeriod.week:
        final weekStart = _startOfWeek(currentDate);
        final weekEnd = weekStart.add(const Duration(days: 6));
        return '${DateFormat('M月d日').format(weekStart)} - ${DateFormat('M月d日').format(weekEnd)}';
      case StatsPeriod.month:
        return DateFormat('yyyy年M月').format(currentDate);
      case StatsPeriod.year:
        return DateFormat('yyyy年').format(currentDate);
      case StatsPeriod.total:
        return '全部';
    }
  }

  DateTime _startOfWeek(DateTime date) {
    final weekday = date.weekday; // 1=Monday
    return date.subtract(Duration(days: weekday - 1));
  }
}
