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

/// 日志详情页：查看单个日志文件内容。
///
/// 设计：**一次只读入当前文件到内存**（单文件 ≤4MB，约 8MB UTF-16），
/// 离开页面即释放（State 销毁），不做跨文件缓存。用 [ListView.builder]
/// 惰性构建行，无需虚拟滚动库。
///
/// 为保证长日志**丝滑滚动**（桌面滚动条拖底/跳底平滑、不“分段跳”），每行在
/// 构建时按当前屏宽拆成多个“恰好一行”的片段（窄/宽字符实测像素拆点，中文
/// 不会漏），列表行高统一并配 `itemExtent`。因此不做省略号，小屏也能看全。
///
/// 交互：顶栏筛选按钮按级别勾选（仅运行日志，默认全选）、复制全文、导出、删除。
/// 正文用 [SelectionArea] 包裹，支持鼠标/手指跨行选择文本：Android/iOS 触屏与
/// 滚动的冲突在 Flutter ≥3.24 已修复（#150897/#152423），当前版本可安全开启。
/// [kind] 决定数据源（运行 / 崩溃）；崩溃日志无级别标记，隐藏级别筛选。
///
/// 滚动：桌面平台交给框架默认滚动条（无需二次包，避免双条）；Android/iOS
/// 显式挂 [Scrollbar]（thumbVisibility 常驻显示）。右下角悬浮「到顶/到底」
/// 按钮，长日志快速跳转。
class LogDetailPage extends StatefulWidget {
  final LogFileMetadata file;
  final LogSourceKind kind;
  const LogDetailPage({
    super.key,
    required this.file,
    this.kind = LogSourceKind.runtime,
  });

  @override
  State<LogDetailPage> createState() => _LogDetailPageState();
}

class _LogDetailPageState extends State<LogDetailPage> {
  String? _content;
  bool _loading = true;

  /// 已勾选可见的日志级别（默认全选）。
  final Set<LogLevel> _enabledLevels = {
    LogLevel.debug,
    LogLevel.info,
    LogLevel.warn,
    LogLevel.error,
  };

  /// 级别筛选菜单控制器（点选子项不自动关闭，便于多次勾选）。
  final MenuController _filterMenu = MenuController();

  /// 当前文件解析出的行（惰性解析，一次性）。
  List<LogLine>? _lines;

  /// 内容/筛选版本号：变化时需重建“按屏宽拆出的单行片段”。
  int _dataVersion = 0;

  /// 拆行缓存：按屏宽把每个逻辑行拆成多个“恰好一行”的片段，
  /// 使列表行高统一（`itemExtent` 可精确滚动），同时不省略任何内容。
  List<_LogRow> _rows = const [];
  double _rowsWidth = -1;
  int _rowsVersion = -1;

  /// 窄（ASCII）与宽（CJK）字符的实测量宽，用于字符级拆行估算。
  double? _narrowCharWidth;
  double? _wideCharWidth;

  /// 滚动控制：Scrollbar + 到顶/到底悬浮按钮共用。
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final content = widget.kind == LogSourceKind.crash
        ? await AppCrash.readCrashLogFile(widget.file)
        : await AppLog.readLogFile(widget.file);
    if (!mounted) return;
    setState(() {
      _content = content ?? '';
      _lines = _parseLines(_content!);
      _loading = false;
      _dataVersion++;
    });
  }

  /// 把原始文本按行拆出（用于筛选后仍可引用原行号）。
  List<LogLine> _parseLines(String text) {
    final raw = text.split('\n');
    final out = <LogLine>[];
    for (var i = 0; i < raw.length; i++) {
      final line = raw[i];
      out.add(LogLine(line, _levelOf(line)));
    }
    return out;
  }

  static LogLevel? _levelOf(String line) {
    if (line.contains('[ERROR]')) return LogLevel.error;
    if (line.contains('[WARN]')) return LogLevel.warn;
    if (line.contains('[INFO]')) return LogLevel.info;
    if (line.contains('[DEBUG]')) return LogLevel.debug;
    return null;
  }

  List<LogLine> get _visibleLines {
    final all = _lines ?? const <LogLine>[];
    return all
        .where(
          (l) =>
              l.level == null || // 无级别行（堆栈续行等）始终可见
              _enabledLevels.contains(l.level),
        )
        .toList();
  }

  static final TextStyle _rowStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.4,
  );

  /// 用当前屏宽把可见行拆成“恰好一行”的片段列表（带缓存）。
  ///
  /// 每个片段单行排版 → 行高统一，`ListView.builder` 用 `itemExtent` 就能
  /// 精确计算滚动偏移（桌面滚动条拖底/跳底平滑，无“分段跳”）；内容以片段
  /// 连续显示，不做省略号、不漏字符（窄/宽字符按实测像素估算拆点）。
  List<_LogRow> _rowsFor(double width) {
    if (_rowsVersion == _dataVersion && _rowsWidth == width) return _rows;

    _ensureCharWidths();
    final textWidth = width - 32; // 左右 Padding 16×2
    final rows = <_LogRow>[];
    for (final line in _visibleLines) {
      if (line.text.isEmpty) {
        rows.add(_LogRow('', line.level));
        continue;
      }
      for (final part in _splitLogLine(line.text, textWidth)) {
        rows.add(_LogRow(part, line.level));
      }
    }
    _rows = rows;
    _rowsWidth = width;
    _rowsVersion = _dataVersion;
    return _rows;
  }

  void _ensureCharWidths() {
    if (_narrowCharWidth != null && _wideCharWidth != null) return;
    final narrow = TextPainter(
      text: TextSpan(text: '0', style: _rowStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final wide = TextPainter(
      text: TextSpan(text: '业', style: _rowStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    _narrowCharWidth = narrow.width;
    _wideCharWidth = wide.width;
  }

  /// 按可用宽度把一行拆成多个片段，全部字符保留。
  List<String> _splitLogLine(String line, double textWidth) {
    final nw = _narrowCharWidth ?? 12 * 0.6;
    final ww = _wideCharWidth ?? nw * 2;
    var width = 0.0;
    final buf = StringBuffer();
    final out = <String>[];
    for (final r in line.runes) {
      final cw = _isWideRune(r) ? ww : nw;
      if (buf.isNotEmpty && width + cw > textWidth) {
        out.add(buf.toString());
        buf.clear();
        width = 0;
      }
      buf.writeCharCode(r);
      width += cw;
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static bool _isWideRune(int r) {
    // Unicode East Asian Width = W/F 的主要字形码（宁宽勿窄、绝不漏字）：
    if (r < 0x1100) return false; // 拉丁/希腊/希伯来/阿拉伯/泰文等窄形字符
    if (r <= 0x115F) return true; // Hangul Jamo
    if (r >= 0x2E80 && r <= 0xA4CF) return true; // 部首→谚文，含 CJK 标点 3000-303F
    if (r >= 0xA960 && r <= 0xA97F) return true; // Hangul Jamo Extended-A
    if (r >= 0xAC00 && r <= 0xD7A3) return true; // Hangul 音节
    if (r >= 0xF900 && r <= 0xFAFF) return true; // CJK 兼容表意
    if (r >= 0xFE10 && r <= 0xFE6F) return true; // 竖排/兼容/小型标点形式
    if (r >= 0xFF00 && r <= 0xFF60) return true; // 全角形式（含全角空格）
    if (r >= 0xFFE0 && r <= 0xFFE6) return true; // 全角符号
    if (r >= 0x1F000 && r <= 0x1FBFF) return true; // emoji 等宽形符号
    if (r >= 0x20000 && r <= 0x3FFFF) return true; // CJK 扩展 B–G
    // 散在 General Punctuation 的宽形：—— / ‖ / ‾（EAW=W，中文排印常见）
    if (r == 0x2014 || r == 0x2016 || r == 0x203E) return true;
    return false;
  }

  void _toggleLevel(LogLevel level) {
    setState(() {
      if (!_enabledLevels.remove(level)) _enabledLevels.add(level);
      _dataVersion++;
    });
  }

  Future<void> _copyAll() async {
    final content = _content;
    if (content == null || content.isEmpty) {
      if (mounted) AppToast.show(context, '该日志为空或不可读');
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    AppToast.show(context, '已复制全文');
  }

  Future<void> _export() async {
    try {
      final String path;
      if (PlatformUtils.isAndroid) {
        path = await LogExportService.buildExportFile([widget.file]);
      } else {
        final location = await getSaveLocation(
          suggestedName: LogExportService.suggestedFileName([widget.file]),
          acceptedTypeGroups: const [
            XTypeGroup(label: '日志文件', extensions: ['log']),
          ],
        );
        if (location == null) return; // 用户取消
        path = await LogExportService.buildExportTo([
          widget.file,
        ], location.path);
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
        AppToast.show(context, '已导出 ${widget.file.name}');
      }
    } catch (e, st) {
      AppLog.error('日志导出失败', tag: 'log', error: e, stack: st);
      if (!mounted) return;
      debugPrint('日志导出失败: $e');
      AppToast.show(context, '导出失败');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除日志'),
        content: Text('确定删除 ${widget.file.name}？此操作不可恢复。'),
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
    final deleted = widget.kind == LogSourceKind.crash
        ? await AppCrash.deleteCrashLogFile(widget.file)
        : await AppLog.deleteLogFile(widget.file);
    if (!mounted) return;
    if (!deleted) {
      AppToast.show(context, '删除失败');
      return;
    }
    Navigator.of(context).pop();
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

  Color _colorFor(LogLevel? level, {Color? fallback}) {
    final cs = Theme.of(context).colorScheme;
    switch (level) {
      case LogLevel.error:
        return cs.error;
      case LogLevel.warn:
        return Colors.orange.shade700;
      case LogLevel.info:
        return cs.onSurfaceVariant;
      case LogLevel.debug:
        return cs.outline;
      default:
        return fallback ?? cs.onSurface;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.kind == LogSourceKind.runtime &&
              _content != null &&
              _content!.isNotEmpty)
            MenuAnchor(
              controller: _filterMenu,
              menuChildren: [
                for (final l in LogLevel.values)
                  CheckboxListTile(
                    value: _enabledLevels.contains(l),
                    onChanged: (_) => _toggleLevel(l),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text('${l.label} 级'),
                  ),
              ],
              builder: (context, controller, child) => IconButton(
                tooltip: '筛选级别',
                icon: const Icon(Icons.filter_list_rounded),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
          IconButton(
            tooltip: '复制全文',
            icon: const Icon(Icons.copy_rounded),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: '导出',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _export,
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _delete,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_content!.isEmpty
                  ? const Center(child: Text('日志内容为空'))
                  : Stack(
                      children: [
                        Positioned.fill(child: _buildLogList()),
                        _buildFloatingActions(),
                      ],
                    )),
      ),
    );
  }

  Widget _buildLogList() {
    /// 用 LayoutBuilder 拿到实际宽度后再拆行片段（小屏/大屏都能整行显示）。
    return LayoutBuilder(
      builder: (context, constraints) {
        final rows = _rowsFor(constraints.maxWidth);
        final listView = ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.only(bottom: scrollBottomClearance(context)),
          // 片段单行且行高统一 → itemExtent 后滚动偏移可精确计算，
          // 桌面滚动条拖底/「跳到底」平滑不“分段跳”（见 devtools#4175）。
          itemExtent: 20,
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final row = rows[i];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                height: 20,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    row.text,
                    // 片段按屏宽已拆到“恰好一行”，无需省略号；clip 兜底防溢出。
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: _rowStyle.copyWith(color: _colorFor(row.level)),
                  ),
                ),
              ),
            );
          },
        );
        // SelectionArea 在 Android/iOS 触屏下与滚动的冲突已被 Flutter 修复
        // （#150897 / #152423，本项目 3.44.2 已含），全平台开启文本选择；
        // Android 长按文本即可选择/复制。
        final list = SelectionArea(child: listView);
        return PlatformUtils.isDesktop
            ? list
            : Scrollbar(controller: _scrollController, child: list);
      },
    );
  }

  /// 右下角悬浮工具栏：一键到顶 / 一键到底（桌面与移动端都提供）。
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

/// 日志单行（文本 + 级别），供筛选复用。
class LogLine {
  final String text;
  final LogLevel? level;
  const LogLine(this.text, this.level);
}

/// 按屏宽拆出后可单行排版的片段行（行高统一，供 `itemExtent` 精确滚动）。
class _LogRow {
  final String text;
  final LogLevel? level;
  const _LogRow(this.text, this.level);
}
