import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/audio_cache/cache_store.dart';
import '../../../core/audio_service/app_audio_handler.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/page_scroll_view.dart';

/// 存储设置 section：音频缓存上限滑块 + 用量/歌曲数查看 + 清理。
///
/// 缓存随播放写盘，总量实时变化；这里用低频定时器（500ms）在页面可见时
/// 刷新用量展示，避免给纯 IO 的 [AudioCacheStore] 强加 ChangeNotifier。
class StorageSection extends StatefulWidget {
  const StorageSection({super.key});

  static Widget builder(BuildContext context) => const StorageSection();

  @override
  State<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<StorageSection> {
  static const _refreshInterval = Duration(milliseconds: 500);

  /// 封面缓存总大小刷新节流：大小只在播放新歌时变化，无需 500ms 高频
  /// 遍历目录（逐文件 stat），放宽到 3s 一次。
  static const _coverRefreshInterval = Duration(seconds: 3);

  Timer? _timer;

  /// 最近一次读取的缓存用量快照（用于 build 时不依赖外部通知）。
  int _totalBytes = 0;
  int _entryCount = 0;
  int _songCount = 0;

  /// 通知栏封面临时目录总大小（字节）；异步读取，节流 + 防并发叠加。
  int _coverBytes = 0;
  bool _fetchCoverBytesInFlight = false;
  int _lastCoverRefreshAt = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshCoverBytes();
    _timer = Timer.periodic(_refreshInterval, (_) {
      _refresh();
      _refreshCoverBytes();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    // dispose 后（页面返回、组件被销毁）不得 setState；定时器路径已有 dispose
    // 兜底，_clearCache 的 await 后也可能走到这里，故统一守卫。
    if (!mounted) return;
    final store = AudioCacheStore.instance;
    final total = store.totalBytes;
    final entries = store.entryCount;
    final songs = store.songCount;
    if (total == _totalBytes && entries == _entryCount && songs == _songCount) {
      return;
    }
    setState(() {
      _totalBytes = total;
      _entryCount = entries;
      _songCount = songs;
    });
  }

  Future<void> _refreshCoverBytes() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 节流：距上次读取不足 3s 则跳过（封面大小变化很低频）。
    if (now - _lastCoverRefreshAt < _coverRefreshInterval.inMilliseconds) {
      return;
    }
    if (_fetchCoverBytesInFlight) return;
    _lastCoverRefreshAt = now;
    _fetchCoverBytesInFlight = true;
    try {
      final bytes = await AppAudioHandler.artworkCacheBytes();
      if (mounted && bytes != _coverBytes) {
        setState(() => _coverBytes = bytes);
      }
    } finally {
      _fetchCoverBytesInFlight = false;
    }
  }

  Future<void> _clearCache() async {
    // 删除所有歌曲目录（音频 + 封面 + 歌词），并清空音频索引。
    await AudioCacheStore.instance.clearAll();
    // 删除所有歌曲目录
    final root = AudioCacheStore.instance.rootDirectory;
    if (root != null) {
      try {
        await for (final entity in root.list()) {
          if (entity is Directory) {
            await entity.delete(recursive: true);
          }
        }
      } catch (_) {}
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<SettingsProvider>();
    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          icon: Icons.cached_rounded,
          title: '缓存',
          children: [
            Text(
              '播放过的歌曲会自动缓存到本地，离线可重复播放；'
              '调整上限会即时回收或放宽空间。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            // 缓存上限滑块（样式对齐播放页音量滑块）。
            Row(
              children: [
                const Icon(Icons.storage_rounded, size: 18),
                Expanded(
                  child: Slider(
                    // Flutter 3.44 中 Slider.year2023 已弃用但默认仍为 true
                    // （2023 外观）。置 false 启用 Material3 2024 滑块样式；
                    // 未来版本该旗标默认翻转后，可连同此参数一并删除。
                    // ignore: deprecated_member_use
                    year2023: false,
                    value: settings.cacheMaxMB.toDouble(),
                    min: SettingsProvider.cacheMaxMBMin.toDouble(),
                    max: SettingsProvider.cacheMaxMBMax.toDouble(),
                    divisions:
                        (SettingsProvider.cacheMaxMBMax -
                            SettingsProvider.cacheMaxMBMin) ~/
                        128,
                    label: _fmtBytes(settings.cacheMaxMB * 1024 * 1024),
                    onChanged: (v) {
                      settings.setCacheMaxMB(v.round());
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    _fmtBytes(settings.cacheMaxMB * 1024 * 1024),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _Row(title: '已用缓存', value: _fmtBytes(_totalBytes)),
            const SizedBox(height: 8),
            _Row(title: '已缓存歌曲', value: '$_songCount 首'),
            const SizedBox(height: 8),
            _Row(title: '缓存文件', value: '$_entryCount 个'),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _clearCache,
                icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                label: const Text('清理缓存'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SectionCard(
          icon: Icons.image_outlined,
          title: '封面缓存',
          children: [
            Text(
              '通知栏封面临时文件：播放封面时写入应用缓存目录，供系统通知栏读取。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _Row(title: '已用空间', value: _fmtBytes(_coverBytes)),
            const SizedBox(height: 8),
            Text(
              '应用启动时自动清理，无需手动删除；位于系统可清理的应用缓存目录内，'
              '手机管家等系统清理工具清理缓存时也会一并清除。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SectionCard(
          icon: Icons.download_rounded,
          title: '下载',
          children: [
            Text(
              '下载歌曲的存储位置，即将支持自定义路径。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _Row(title: '下载位置', value: '默认（应用沙盒）'),
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  /// 字节数格式化：<1KB 显示 B，<1MB 显示 KB，<1GB 显示 MB，否则 GB（1 位小数）。
  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String value;
  const _Row({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(title, style: theme.textTheme.bodyLarge)),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
