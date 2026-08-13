import 'package:flutter/material.dart';

import '../../../core/playback_stats/playback_stats_models.dart';

/// 周期选择器（日/周/月/年/总）
class PeriodSelector extends StatelessWidget {
  final StatsPeriod selected;
  final ValueChanged<StatsPeriod>? onChanged;

  const PeriodSelector({
    super.key,
    required this.selected,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<StatsPeriod>(
      segments: const [
        ButtonSegment(
          value: StatsPeriod.day,
          label: Text('日'),
        ),
        ButtonSegment(
          value: StatsPeriod.week,
          label: Text('周'),
        ),
        ButtonSegment(
          value: StatsPeriod.month,
          label: Text('月'),
        ),
        ButtonSegment(
          value: StatsPeriod.year,
          label: Text('年'),
        ),
        ButtonSegment(
          value: StatsPeriod.total,
          label: Text('总'),
        ),
      ],
      selected: {selected},
      onSelectionChanged: onChanged != null ? (v) => onChanged!(v.first) : null,
      showSelectedIcon: false,
    );
  }
}
