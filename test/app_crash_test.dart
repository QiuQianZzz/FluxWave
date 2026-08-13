import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fluxwave/core/logging/app_crash.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String supportDir;
  _FakePathProvider(this.supportDir);

  @override
  Future<String?> getApplicationSupportPath() async => supportDir;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_crash_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    PackageInfo.setMockInitialValues(
      appName: 'FluxWave',
      packageName: 'com.example.fluxwave',
      version: '1.0.0',
      buildNumber: '42',
      buildSignature: 'test',
    );
  });

  tearDown(() {
    AppCrash.resetForTest();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('init 后崩溃目录为 support/crash', () async {
    await AppCrash.init();
    expect(AppCrash.initialized, isTrue);
    expect(AppCrash.crashDirectory, isNotNull);
    expect(
      AppCrash.crashDirectory!.path,
      '${tempDir.path}${Platform.pathSeparator}crash',
    );
    expect(AppCrash.crashDirectory!.existsSync(), isTrue);
  });

  test('未初始化时不写崩溃日志也不抛错', () async {
    AppCrash.reportZoneError(StateError('boom'), StackTrace.current);
    expect(tempDir.listSync(), isEmpty);
  });

  test('configureForTest 直接指定目录', () async {
    AppCrash.configureForTest(tempDir.path);
    expect(AppCrash.crashDirectory, isNotNull);
    expect(AppCrash.initialized, isTrue);
  });

  test('reportZoneError 写入含堆栈与设备信息的崩溃文件', () async {
    AppCrash.configureForTest(tempDir.path);
    AppCrash.reportZoneError(StateError('zone boom'), StackTrace.current);
    await AppCrash.flushCrashLogs();

    final files = tempDir.listSync().whereType<File>();
    expect(files, isNotEmpty);
    final content = files.first.readAsStringSync();
    expect(content, contains('=== Crash Report ==='));
    expect(content, contains('Source: Zone'));
    expect(content, contains('StateError'));
    expect(content, contains('zone boom'));
    expect(content, contains('Stack Trace:'));
    expect(content, contains('=== Device Info ==='));
    expect(content, contains('App: FluxWave 1.0.0+42'));
  });

  test('recordFlutterError 写入构建错误崩溃文件', () async {
    AppCrash.configureForTest(tempDir.path);
    AppCrash.recordFlutterError(
      FlutterErrorDetails(
        exception: Exception('layout fail'),
        stack: StackTrace.current,
        library: 'scheduler',
      ),
    );
    await AppCrash.flushCrashLogs();

    final files = tempDir.listSync().whereType<File>();
    expect(files, isNotEmpty);
    final content = files.first.readAsStringSync();
    expect(content, contains('Source: FlutterError'));
    expect(content, contains('layout fail'));
    expect(content, contains('scheduler'));
  });

  test('installHandlers 挂载后 FlutterError.onError 被调用', () async {
    AppCrash.configureForTest(tempDir.path);
    var prevCalled = false;
    FlutterError.onError = (details) => prevCalled = true;
    AppCrash.installHandlers();

    FlutterError.reportError(
      FlutterErrorDetails(exception: Exception('x'), library: 'l'),
    );
    await AppCrash.flushCrashLogs();

    // 保留原始 handler 行为
    expect(prevCalled, isTrue);
    final files = tempDir.listSync().whereType<File>();
    expect(files, isNotEmpty);
    expect(files.first.readAsStringSync(), contains('Source: FlutterError'));
    // 还原，避免污染后续测试
    FlutterError.onError = FlutterError.presentError;
  });
}
