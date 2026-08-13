import 'package:flutter/foundation.dart';

import '../core/playback_stats/database_helper.dart';
import '../core/playback_stats/playback_stats_models.dart';

/// 播放记录状态管理
///
/// 管理当前选中的周期、日期、统计数据，提供加载和切换方法。
class PlaybackStatsProvider extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;

  StatsPeriod _period = StatsPeriod.day;
  StatsPeriod _selectedPeriod = StatsPeriod.day; // UI 显示的目标周期
  DateTime _currentDate = DateTime.now();
  PlaybackStats? _stats;
  StatsPeriod? _statsPeriod; // _stats 对应的周期
  bool _transitioning = false; // 切换周期中，禁用选择器
  List<RecentPlay> _recentPlayed = [];
  List<HeatmapEntry> _heatmapData = []; // 始终为最近一年，不随周期变化
  bool _loading = false;
  String? _error;

  StatsPeriod get period => _period;
  StatsPeriod get selectedPeriod => _selectedPeriod;
  DateTime get currentDate => _currentDate;
  PlaybackStats? get stats => _stats;
  StatsPeriod? get statsPeriod => _statsPeriod;
  bool get transitioning => _transitioning;
  List<RecentPlay> get recentPlayed => _recentPlayed;
  List<HeatmapEntry> get heatmapData => _heatmapData;
  bool get loading => _loading;
  String? get error => _error;

  /// 切换统计周期（延迟生效：_period 在数据加载完成后才更新）
  void setPeriod(StatsPeriod period) {
    if (_period == period || _transitioning) return;
    _selectedPeriod = period;
    _currentDate = DateTime.now();
    _transitioning = true;
    notifyListeners();
    loadStats();
  }

  /// 切换日期（前进/后退）
  void setDate(DateTime date) {
    _currentDate = date;
    notifyListeners();
    loadStats();
  }

  /// 前进一个周期
  void goForward() {
    switch (_selectedPeriod) {
      case StatsPeriod.day:
        _currentDate = _currentDate.add(const Duration(days: 1));
        break;
      case StatsPeriod.week:
        _currentDate = _currentDate.add(const Duration(days: 7));
        break;
      case StatsPeriod.month:
        _currentDate = DateTime(
          _currentDate.year,
          _currentDate.month + 1,
          _currentDate.day,
        );
        break;
      case StatsPeriod.year:
        _currentDate = DateTime(
          _currentDate.year + 1,
          _currentDate.month,
          _currentDate.day,
        );
        break;
      case StatsPeriod.total:
        break;
    }
    notifyListeners();
    loadStats();
  }

  /// 后退一个周期
  void goBackward() {
    switch (_selectedPeriod) {
      case StatsPeriod.day:
        _currentDate = _currentDate.subtract(const Duration(days: 1));
        break;
      case StatsPeriod.week:
        _currentDate = _currentDate.subtract(const Duration(days: 7));
        break;
      case StatsPeriod.month:
        _currentDate = DateTime(
          _currentDate.year,
          _currentDate.month - 1,
          _currentDate.day,
        );
        break;
      case StatsPeriod.year:
        _currentDate = DateTime(
          _currentDate.year - 1,
          _currentDate.month,
          _currentDate.day,
        );
        break;
      case StatsPeriod.total:
        break;
    }
    notifyListeners();
    loadStats();
  }

  /// 加载统计数据
  Future<void> loadStats() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      switch (_selectedPeriod) {
        case StatsPeriod.day:
          _stats = await _db.getStatsForDay(_currentDate);
          break;
        case StatsPeriod.week:
          _stats = await _db.getStatsForWeek(_currentDate);
          break;
        case StatsPeriod.month:
          _stats = await _db.getStatsForMonth(
            _currentDate.year,
            _currentDate.month,
          );
          break;
        case StatsPeriod.year:
          _stats = await _db.getStatsForYear(_currentDate.year);
          break;
        case StatsPeriod.total:
          _stats = await _db.getTotalStats();
          break;
      }
      _period = _selectedPeriod;
      _statsPeriod = _selectedPeriod;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      _transitioning = false;
      notifyListeners();
    }
  }

  /// 加载最近播放列表
  Future<void> loadRecentPlayed({int limit = 500}) async {
    try {
      _recentPlayed = await _db.getRecentPlayed(limit: limit);
      notifyListeners();
    } catch (e) {
      // 静默失败
    }
  }
  /// 初始化：加载总统计 + 最近播放 + 热力图（最近一年）
  Future<void> initialize() async {
    await Future.wait([loadStats(), loadRecentPlayed(), loadHeatmap()]);
  }

  /// 加载最近一年的热力图（始终完整，不随周期变化）
  Future<void> loadHeatmap() async {
    try {
      _heatmapData = await _db.getHeatmapForLastYear();
      notifyListeners();
    } catch (_) {
      // 静默失败
    }
  }
}
