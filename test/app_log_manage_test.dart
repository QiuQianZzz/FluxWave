import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fluxwave/core/logging/app_log.dart';
import 'package:fluxwave/core/logging/log_export.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String downloadsDir;
  _FakePathProvider(this.downloadsDir);

  @override
  Future<String?> getDownloadsPath() async => downloadsDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => downloadsDir;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('applog_manage_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // 导出逻辑在桌面端走 Downloads，Android 走系统分享；这里固定桌面以便断言路径。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppLog.resetForTest();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  LogFileMetadata metaOfFile(File f) {
    final name = f.uri.pathSegments.last;
    return LogFileMetadata(
      name: name,
      path: f.path,
      sizeBytes: f.lengthSync(),
      modified: DateTime.now(),
      date: name.length >= 10 ? name.substring(0, 10) : '',
    );
  }

  test('listLogFiles 返回元信息并按修改时间倒序', () async {
    AppLog.configureForTest(tempDir.path);
    AppLog.info('alpha');
    AppLog.info('beta');
    await AppLog.flush();

    final metas = await AppLog.listLogFiles();
    expect(metas, isNotEmpty);
    expect(metas.first.name, endsWith('.log'));
    expect(metas.first.path, startsWith(tempDir.path));
    expect(metas.first.sizeBytes, greaterThan(0));
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(metas.first.date), isTrue);
  });

  test('readLogFile 读回日志内容', () async {
    AppLog.configureForTest(tempDir.path);
    AppLog.info('读回来检查你');
    await AppLog.flush();

    final metas = await AppLog.listLogFiles();
    final content = await AppLog.readLogFile(metas.first);
    expect(content, contains('读回来检查你'));
  });

  test('deleteLogFile 删除后 listLogFiles 不再包含该文件', () async {
    AppLog.configureForTest(tempDir.path);
    AppLog.info('to be deleted');
    await AppLog.flush();
    final metas = await AppLog.listLogFiles();
    expect(metas, isNotEmpty);

    final ok = await AppLog.deleteLogFile(metas.first);
    expect(ok, isTrue);
    final after = await AppLog.listLogFiles();
    expect(after.where((m) => m.name == metas.first.name), isEmpty);
  });

  test('clearAllLogs 清空并返回删除数量', () async {
    AppLog.configureForTest(tempDir.path);
    AppLog.info('entry one');
    await AppLog.flush();
    expect(await AppLog.listLogFiles(), hasLength(1));

    final cleared = await AppLog.clearAllLogs();
    expect(cleared, 1);
    expect(await AppLog.listLogFiles(), isEmpty);
  });

  test('userEnabled 关闭后不落盘，重新开启后恢复写', () async {
    AppLog.configureForTest(tempDir.path);
    AppLog.info('before');
    await AppLog.flush();
    expect(await AppLog.listLogFiles(), isNotEmpty);

    AppLog.setUserEnabled(false);
    expect(AppLog.userEnabled, isFalse);
    AppLog.info('during closed');
    await AppLog.flush();
    // 关闭期间不写盘：仍只有「before」所在的 1 个文件。
    expect(await AppLog.listLogFiles(), hasLength(1));

    AppLog.setUserEnabled(true);
    expect(AppLog.userEnabled, isTrue);
    AppLog.info('after reopen');
    await AppLog.flush();
    expect(await AppLog.listLogFiles(), isNotEmpty);
  });

  test('export：单选复制原始 .log 到下载目录', () async {
    final srcDir = Directory('${tempDir.path}${Platform.pathSeparator}src')
      ..createSync();
    final file = File('${srcDir.path}${Platform.pathSeparator}export_test.log')
      ..writeAsStringSync('line1\nline2\n');
    final meta = metaOfFile(file);

    final out = await LogExportService.buildExportFile([meta]);
    final exported = File(out);
    expect(File(meta.path).existsSync(), isTrue, reason: '原文件不应被改写');
    expect(exported.existsSync(), isTrue);
    expect(exported.readAsStringSync(), 'line1\nline2\n');
    // 导出落在假 Downloads 目录根下，且文件名与原始一致。
    expect(out, '${tempDir.path}${Platform.pathSeparator}export_test.log');
  });

  test('export：多选打包为包含全部日志的 zip', () async {
    final srcDir = Directory('${tempDir.path}${Platform.pathSeparator}src')
      ..createSync();
    final a = File('${srcDir.path}${Platform.pathSeparator}a.log')
      ..writeAsStringSync('aaa');
    final b = File('${srcDir.path}${Platform.pathSeparator}b.log')
      ..writeAsStringSync('bbb');

    final out = await LogExportService.buildExportFile([
      metaOfFile(a),
      metaOfFile(b),
    ]);
    expect(out, endsWith('.zip'));

    final bytes = File(out).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toList();
    expect(names, containsAll(['a.log', 'b.log']));
    for (final f in archive.files) {
      expect(
        String.fromCharCodes(f.content as List<int>) == 'aaa' ||
            String.fromCharCodes(f.content as List<int>) == 'bbb',
        isTrue,
      );
    }
  });

  test('buildExportTo：写入用户指定的路径', () async {
    final srcDir = Directory('${tempDir.path}${Platform.pathSeparator}src')
      ..createSync();
    final file = File('${srcDir.path}${Platform.pathSeparator}manual.log')
      ..writeAsStringSync('custom content');
    final target = '${tempDir.path}${Platform.pathSeparator}pick.log';

    final out = await LogExportService.buildExportTo([
      metaOfFile(file),
    ], target);
    expect(out, target);
    expect(File(target).readAsStringSync(), 'custom content');
    expect(File(file.path).existsSync(), isTrue, reason: '原文件不应被改写');
  });

  test('suggestedFileName：单选原文件名，多选带时间戳 zip', () {
    final single = metaOfFile(
      File('${tempDir.path}${Platform.pathSeparator}2026-08-07.log')
        ..writeAsStringSync('x'),
    );
    final multi = metaOfFile(
      File('${tempDir.path}${Platform.pathSeparator}b.log')
        ..writeAsStringSync('y'),
    );
    expect(LogExportService.suggestedFileName([single]), '2026-08-07.log');
    final zip = LogExportService.suggestedFileName([single, multi]);
    expect(zip, matches(RegExp(r'^fluxwave_logs_\d{8}_\d{6}\.zip$')));
  });
}
