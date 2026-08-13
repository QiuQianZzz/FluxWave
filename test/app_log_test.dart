import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/logging/app_log.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('applog_test');
  });

  tearDown(() {
    AppLog.resetForTest();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  int countLogFiles() => tempDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.log'))
      .length;

  String readAllLogs() {
    final files = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList();
    final sb = StringBuffer();
    for (final f in files) {
      sb.write(f.readAsStringSync());
    }
    return sb.toString();
  }

  test('info/error 落盘，格式含级别标签', () async {
    AppLog.configureForTest(tempDir.path);
    AppLog.info('queue restored: 3 songs');
    AppLog.error('failed url', error: StateError('boom'));
    await AppLog.flush();

    final content = readAllLogs();
    expect(content, contains('[INFO]'));
    expect(content, contains('queue restored: 3 songs'));
    expect(content, contains('[ERROR]'));
    expect(content, contains('Bad state: boom'));
  });

  test('长堆栈截断：只保留前 N 帧 + 省略标记；短堆栈不改动', () async {
    AppLog.configureForTest(tempDir.path, maxStackLines: 5);
    // 造一条 40 帧的长栈：Dart 区可写任意行，模拟真实几百帧异步栈
    final longStack = List.generate(
      40,
      (i) => '#$i  long.frame.${i}_x',
    ).join('\n');
    AppLog.warn(
      'long',
      error: StateError('deep'),
      stack: StackTrace.fromString(longStack),
    );
    await AppLog.flush();
    final content = readAllLogs();
    // 首帧（抛错点）保留
    expect(content, contains('#0  long.frame.0_x'));
    expect(content, contains('#4  long.frame.4_x'));
    // 前 5 帧之后的行被省略占位符替换
    expect(content, contains('... (35 帧已省略)'));
    expect(content, isNot(contains('#5  long.frame.5_x')));

    // 短栈（≤ 上限）原样保留，不带截断标记
    AppLog.configureForTest(tempDir.path, maxStackLines: 5);
    AppLog.error(
      'short stack',
      error: StateError('boom'),
      stack: StackTrace.fromString('#x\na\nb'),
    );
    await AppLog.flush();
    final after = readAllLogs();
    final shortSeg = after.substring(after.indexOf('short stack'));
    expect(shortSeg, contains('#x\na\nb'));
    expect(shortSeg, isNot(contains('已省略')));
  });

  test('超过单文件上限自动切分新文件', () async {
    AppLog.configureForTest(tempDir.path, maxFileBytes: 4000);
    for (var i = 0; i < 300; i++) {
      AppLog.info('padding line $i ${'x' * 100}');
    }
    await AppLog.flush();

    expect(
      countLogFiles(),
      greaterThan(1),
      reason: 'over single-file cap should roll',
    );
  });

  test('老文件按文件数上限回收', () async {
    AppLog.configureForTest(tempDir.path, maxFiles: 5);
    // 强制造出超过上限的文件数，并给予不同修改时间以便按新旧清理。
    final now = DateTime.now();
    for (var i = 0; i < 12; i++) {
      final f = File('${tempDir.path}${Platform.pathSeparator}app_$i.log');
      f.writeAsStringSync('old content here');
      f.setLastModifiedSync(now.subtract(Duration(minutes: i)));
    }
    // Windows 下文件删除偶发瞬时锁：多次 flush 触发重试，直到稳定。
    for (var attempt = 0; attempt < 10; attempt++) {
      await AppLog.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (countLogFiles() <= 5) break;
    }
    expect(countLogFiles(), lessThanOrEqualTo(5), reason: '数量超限应回收最旧');
  });

  test('未启用时不落盘', () async {
    AppLog.info('should not appear');
    await AppLog.flush();
    expect(countLogFiles(), 0, reason: '未启用时不应产生任何日志文件');
  });

  test('熔断：超条数上限后拒写并打印熔断标记', () async {
    AppLog.configureForTest(tempDir.path, maxFileBytes: 1 << 20, maxFault: 200);
    for (var i = 0; i < 300; i++) {
      AppLog.info('entry $i');
    }
    await AppLog.flush();
    final content = readAllLogs();
    expect(content, contains('[FROZE]'));
  });

  test('按总量上限回收：即使文件数未超限，也要删到总量达标', () async {
    // 单文件上限很小以便产生多个文件；总量上限设为 6000B。
    AppLog.configureForTest(
      tempDir.path,
      maxFileBytes: 2000,
      maxTotalBytes: 6000,
      maxFiles: 10,
    );
    for (var i = 0; i < 40; i++) {
      AppLog.info('padding line $i ${'y' * 200}');
    }
    await AppLog.flush();

    final files = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList();
    var total = 0;
    for (final f in files) {
      total += f.lengthSync();
    }
    // 写入自身会在 prune 前保持一个 ≤maxFileBytes 的当前文件，故允许少量余量。
    expect(total, lessThanOrEqualTo(6000 + 2000));
    expect(files.length, lessThanOrEqualTo(6));
  });
}
