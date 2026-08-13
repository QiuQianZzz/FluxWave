import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/logging/app_crash.dart';
import '../../../../core/logging/app_log.dart';
import '../../../../core/logging/log_export.dart';
import '../../../../core/platform_utils.dart';
import '../../../../widgets/app_toast.dart';
import '../../../../widgets/page_scroll_view.dart';
import 'log_detail_page.dart';

/// 设置页「关于」→「应用日志」：日志文件列表与批量管理。
///
/// [kind] 决定数据源：运行日志（[AppLog]）或崩溃日志（[AppCrash]）。
/// 两种共用同一套列表/详情/批量导出删除交互。
///
/// 交互：
/// - 单击查看文件内容；右侧「复制」复制当前文件全文；右侧「导出」导出当前文件。
/// - 顶栏「选择」按钮或长按进入批量模式：隐藏「查看/复制」，仅保留「导出/删除」
///   （多文件导出为 zip）。
/// - 顶部支持按文件名/日期过滤。
///
/// 滚动：桌面平台框架自带滚动条（不重复包）；Android/iOS 显式挂 [Scrollbar]。
/// 右下角「到顶/到底」悬浮按钮（批量选择条展开时隐藏，避免重叠）。
class LogListPage extends StatefulWidget {
  static const title = '应用日志';
  final LogSourceKind kind;
  const LogListPage({super.key, this.kind = LogSourceKind.runtime});

  @override
  State<LogListPage> createState() => _LogListPageState();
}

class _LogListPageState extends State<LogListPage> {
  List<LogFileMetadata> _files = const [];
  final Set<LogFileMetadata> _selected = {};
  bool _loading = true;
  bool _selectionMode = false;
  String _query = '';

  /// 滚动控制：Scrollbar + 到顶/到底悬浮按钮共用。
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _selected.clear();
    });
    final files = widget.kind == LogSourceKind.crash
        ? await AppCrash.listCrashLogFiles()
        : await AppLog.listLogFiles();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  bool get _isCrash => widget.kind == LogSourceKind.crash;

  Future<String?> _read(LogFileMetadata f) =>
      _isCrash ? AppCrash.readCrashLogFile(f) : AppLog.readLogFile(f);

  Future<bool> _deleteOne(LogFileMetadata f) =>
      _isCrash ? AppCrash.deleteCrashLogFile(f) : AppLog.deleteLogFile(f);

  List<LogFileMetadata> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _files;
    return _files
        .where((f) => f.name.toLowerCase().contains(q) || f.date.contains(q))
        .toList();
  }

  void _toggleSelection(LogFileMetadata f) {
    setState(() {
      if (!_selected.remove(f)) _selected.add(f);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  Future<void> _openDetail(LogFileMetadata f) async {
    if (_selectionMode) {
      _toggleSelection(f);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LogDetailPage(file: f, kind: widget.kind),
      ),
    );
    _reload(); // 详情页可能删除该文件，返回后刷新
  }

  Future<void> _copy(LogFileMetadata f) async {
    final content = await _read(f);
    if (content == null || content.isEmpty) {
      if (mounted) AppToast.show(context, '该日志为空或不可读');
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    AppToast.show(context, '已复制 ${f.name}');
  }

  /// 导出：桌面弹系统保存对话框由用户选择位置；Android 弹系统分享面板。
  Future<void> _export(List<LogFileMetadata> files) async {
    try {
      final String path;
      if (PlatformUtils.isAndroid) {
        path = await LogExportService.buildExportFile(files);
      } else {
        final location = await getSaveLocation(
          suggestedName: LogExportService.suggestedFileName(files),
          acceptedTypeGroups: [
            XTypeGroup(
              label: files.length == 1 ? '日志文件' : 'ZIP 压缩包',
              extensions: files.length == 1 ? ['log'] : ['zip'],
            ),
          ],
        );
        if (location == null) return; // 用户取消
        path = await LogExportService.buildExportTo(files, location.path);
      }
      if (!mounted) return;
      if (PlatformUtils.isAndroid) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(path)],
            subject: 'FluxWave 日志',
            text: 'FluxWave 应用日志',
          ),
        );
      } else {
        AppToast.show(
          context,
          '已导出到 ${path.split(Platform.pathSeparator).last}',
        );
      }
      if (_selectionMode) _exitSelection();
    } catch (e, st) {
      AppLog.error('日志导出失败', tag: 'log', error: e, stack: st);
      if (!mounted) return;
      debugPrint('日志导出失败: $e');
      AppToast.show(context, '导出失败');
    }
  }

  Future<void> _exportSelected() => _export(_selected.toList());

  Future<void> _deleteSelected() async {
    final list = _selected.isEmpty ? _files : _selected.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除日志'),
        content: Text('确定删除 ${list.length} 个日志文件？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    var failed = 0;
    for (final f in list) {
      if (!await _deleteOne(f)) failed++;
    }
    if (!mounted) return;
    AppToast.show(
      context,
      failed == 0 ? '已删除 ${list.length} 个文件' : '$failed 个文件删除失败',
    );
    _exitSelection();
    _reload();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定删除全部日志文件？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = _isCrash
        ? await AppCrash.clearAllCrashLogs()
        : await AppLog.clearAllLogs();
    if (!mounted) return;
    AppToast.show(context, '已清空 $n 个日志文件');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(theme),
            _buildSearch(theme),
            // 列表 + 右下角「到顶/到底」悬浮按钮；selection 模式底栏会占位，
            // 浮动按钮随之隐藏避免重叠。
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildBody(filtered)),
                  if (!_selectionMode) _buildFloatingActions(),
                ],
              ),
            ),
            if (_selectionMode) _buildSelectionBar(theme),
          ],
        ),
      ),
    );
  }

  void _jumpToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Widget _buildFloatingActions() {
    return Positioned(
      right: 12,
      bottom: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FloatToolButton(
            tooltip: '回到顶部',
            icon: Icons.vertical_align_top_rounded,
            onTap: _jumpToTop,
          ),
          const SizedBox(height: 8),
          _FloatToolButton(
            tooltip: '跳到底部',
            icon: Icons.vertical_align_bottom_rounded,
            onTap: _jumpToBottom,
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _isCrash ? '崩溃日志' : LogListPage.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (_selectionMode)
            TextButton(onPressed: _exitSelection, child: const Text('完成'))
          else ...[
            IconButton(
              tooltip: '选择',
              icon: const Icon(Icons.checklist_rounded),
              onPressed: _files.isEmpty
                  ? null
                  : () => setState(() => _selectionMode = true),
            ),
            IconButton(
              tooltip: '清空全部日志',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _files.isEmpty ? null : _clearAll,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSearch(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        decoration: const InputDecoration(
          hintText: '按文件名或日期过滤',
          prefixIcon: Icon(Icons.search_rounded),
          isDense: true,
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildBody(List<LogFileMetadata> filtered) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(_isCrash ? '暂无崩溃日志' : '暂无日志文件'),
          ],
        ),
      );
    }
    final list = ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.only(bottom: scrollBottomClearance(context)),
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final f = filtered[i];
        final selected = _selected.contains(f);
        return ListTile(
          leading: _selectionMode
              ? Checkbox(value: selected, onChanged: (v) => _toggleSelection(f))
              : null,
          title: Text(f.name),
          subtitle: Text(
            '${_fmtSize(f.sizeBytes)} · ${_fmtDate(f.modified)}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () => _openDetail(f),
          onLongPress: _selectionMode
              ? null
              : () => setState(() {
                  _selectionMode = true;
                  _selected.add(f);
                }),
          trailing: _selectionMode
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '复制内容',
                      icon: const Icon(Icons.copy_rounded, size: 20),
                      onPressed: () => _copy(f),
                    ),
                    IconButton(
                      tooltip: '导出',
                      icon: const Icon(Icons.ios_share_rounded, size: 20),
                      onPressed: () => _export([f]),
                    ),
                  ],
                ),
        );
      },
    );
    return PlatformUtils.isDesktop
        ? list
        : Scrollbar(controller: _scrollController, child: list);
  }

  Widget _buildSelectionBar(ThemeData theme) {
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Text('已选 ${_selected.length}'),
              const Spacer(),
              TextButton.icon(
                onPressed: _selected.isEmpty ? null : _exportSelected,
                icon: const Icon(Icons.save_alt_rounded),
                label: const Text('导出'),
              ),
              TextButton.icon(
                onPressed: _selected.isEmpty ? null : _deleteSelected,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('删除'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  static String _fmtDate(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} $h:$m';
  }
}

/// 悬浮工具栏里的单个圆形快捷按钮。
class _FloatToolButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  const _FloatToolButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.92),
      elevation: 3,
      shape: const CircleBorder(),
      child: IconButton(tooltip: tooltip, icon: Icon(icon), onPressed: onTap),
    );
  }
}
