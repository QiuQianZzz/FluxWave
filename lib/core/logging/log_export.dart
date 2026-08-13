import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform_utils.dart';
import 'app_log.dart';

/// 日志导出服务：把日志文件导出到用户可见位置（供收集排障信息）。
///
/// 策略：
/// - **单选**：直接复制原始 `.log` 文件（保持文本可读）。
/// - **多选**：打包成单个 `.zip` 压缩包。
/// - **桌面端**：先弹系统保存对话框由用户选择位置，再写入 `buildExportTo`。
/// - **Android**：生成到临时目录后交由调用方 `Share.shareXFiles` 弹系统分享，
///   把选择权交给用户（保存到微信/网盘等）。
class LogExportService {
  LogExportService._();

  /// 生成待分享的导出文件（Android 走临时目录，桌面落 Downloads）。
  ///
  /// - 单选：复制原 `.log`。
  /// - 多选：打包 `.zip`。
  /// 返回生成的文件路径。失败抛异常。
  static Future<String> buildExportFile(List<LogFileMetadata> files) async {
    if (files.isEmpty) throw StateError('没有可导出的日志文件');
    // Android 走临时目录（share_plus 需要 readable 路径）；桌面直接落 Downloads。
    final base = PlatformUtils.isAndroid ? Directory.systemTemp : await _downloadsDir();
    await base.create(recursive: true);
    final target = File(p.join(base.path, suggestedFileName(files)));
    await _writeTo(target, files);
    return target.path;
  }

  /// 导出到用户指定的完整路径（桌面端系统保存对话框选定）。
  ///
  /// [targetPath] 由对话框返回，单选时用户可改文件名；多选保持 `.zip`。
  static Future<String> buildExportTo(
    List<LogFileMetadata> files,
    String targetPath,
  ) async {
    if (files.isEmpty) throw StateError('没有可导出的日志文件');
    final target = File(targetPath);
    await _writeTo(target, files);
    return target.path;
  }

  /// 对话框默认文件名：单选为原文件名，多选为带时间戳的 ZIP 名。
  static String suggestedFileName(List<LogFileMetadata> files) {
    if (files.length == 1) return files.first.name;
    final ts = DateTime.now();
    return 'fluxwave_logs_${ts.year}'
        '${_two(ts.month)}${_two(ts.day)}_${_two(ts.hour)}'
        '${_two(ts.minute)}${_two(ts.second)}.zip';
  }

  static Future<void> _writeTo(File target, List<LogFileMetadata> files) async {
    if (files.length == 1) {
      final meta = files.first;
      await File(meta.path).copy(target.path);
      return;
    }
    await target.writeAsBytes(await _zipBytes(files));
  }

  static Future<List<int>> _zipBytes(List<LogFileMetadata> files) async {
    final archive = Archive();
    for (final f in files) {
      final src = File(f.path);
      if (!await src.exists()) continue;
      final data = await src.readAsBytes();
      archive.addFile(ArchiveFile(f.name, data.length, data));
    }
    if (archive.files.isEmpty) throw StateError('没有可导出的日志文件');
    final bytes = ZipEncoder().encode(archive);
    if (bytes == null) throw StateError('ZIP 编码失败');
    return bytes;
  }

  static Future<Directory> _downloadsDir() async {
    try {
      final d = await getDownloadsDirectory();
      if (d != null && await d.exists()) return d;
    } catch (_) {
      // 忽略，走回退
    }
    final doc = await getApplicationDocumentsDirectory();
    return doc;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
