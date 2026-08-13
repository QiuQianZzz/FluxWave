import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_dirs.dart';
import 'app_log.dart';

/// 崩溃捕获与独立崩溃日志。
///
/// 目标：
/// - 捕获 Flutter/Dart 三路未处理错误：`FlutterError.onError`（构建/布局异常）、
///   `PlatformDispatcher.instance.onError`（引擎/平台异常）、`runZonedGuarded`
///   （Zone 内未捕获异步异常），写入独立 `crash/` 目录。
/// - 与 [AppLog] 解耦：崩溃日志不受「记录日志」用户开关影响，也不参与熔断/
///   队列——任何时刻崩溃都必须能留痕。
/// - 报告内附设备/版本信息（OS/架构/版本号），提升排障信息量。
///
/// 不抛错：所有内部失败静默吞掉，绝不因「写崩溃日志」本身再崩。
class AppCrash {
  AppCrash._();

  static Directory? _dir;
  static bool _initAttempted = false;

  /// Flutter/Platform 错误钩子是否已挂载（防重复安装导致双写）。
  static bool _handlersInstalled = false;

  /// 串行写链：崩溃写入排队执行（低频，无并发交错），供 flush/测试等待。
  static Future<void> _chain = Future.value();

  /// 崩溃日志目录（`crash/`），未初始化时为 null。
  static Directory? get crashDirectory => _dir;

  /// 是否已初始化（供测试/诊断）。
  static bool get initialized => _initAttempted;

  /// 等待所有待写崩溃日志完成（测试/退出兜底）。
  static Future<void> flushCrashLogs() => _chain;

  /// 初始化崩溃日志目录。
  ///
  /// [directory] 指定时直接用该目录（测试/可注入场景）；缺省用平台
  /// application support 目录 + `/crash`。仅首次生效，幂等；失败静默禁用。
  static Future<void> init({String? directory}) async {
    if (_initAttempted) return;
    _initAttempted = true;
    try {
      if (directory != null) {
        _dir = Directory(directory);
      } else {
        _dir = await appSupportDir('crash');
      }
      await _dir!.create(recursive: true);
    } catch (_) {
      _dir = null;
    }
  }

  /// 供测试直接指定目录并复位状态。
  static void configureForTest(String directory) {
    _dir = Directory(directory);
    _initAttempted = true;
  }

  /// 复位为未初始化状态（测试 tearDown 用）。
  static void resetForTest() {
    _dir = null;
    _initAttempted = false;
    _handlersInstalled = false;
    _chain = Future.value();
  }

  /// 返回用于报告的版本号（失败时回退占位符，绝不抛）。
  ///
  /// 缓存首次结果：每次崩溃都写，反复 await PackageInfo 不必要；版本在会话内不变。
  static String? _cachedVersion;
  static Future<String> _appVersion() async {
    final cached = _cachedVersion;
    if (cached != null) return cached;
    try {
      final info = await PackageInfo.fromPlatform();
      final v = '${info.appName} ${info.version}+${info.buildNumber}';
      _cachedVersion = v;
      return v;
    } catch (_) {
      return 'unknown';
    }
  }

  /// 构建设备/版本信息段。
  ///
  /// - [version]：来自 [PackageInfo]（异步获取后传入），避免本方法自身 await。
  /// - 其余字段取自 dart:io [Platform]（OS 名 / OS 版本 / 架构 / 运行时描述）。
  static String _deviceInfo(String version) {
    final sb = StringBuffer();
    sb.writeln('=== Device Info ===');
    sb.writeln('App: $version');
    sb.writeln('OS: ${Platform.operatingSystem}');
    sb.writeln('OS Version: ${Platform.operatingSystemVersion}');
    sb.writeln('Architecture: ${_archName()}');
    sb.writeln('Dart VM: ${Platform.version}');
    return sb.toString();
  }

  static String _archName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android (${_hostArchName()})';
      case TargetPlatform.windows:
        return 'windows (${_hostArchName()})';
      case TargetPlatform.macOS:
        return 'macos (${_hostArchName()})';
      case TargetPlatform.linux:
        return 'linux (${_hostArchName()})';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  static String _hostArchName() {
    // Platform.version 末尾形如 ... on "windows_x64" / "macos_arm64" /
    // "android_arm64" / "ios_arm64"，引号内即宿主运行时「平台_架构」标识。
    final re = RegExp(r'on\s+"([^"]+)"');
    final matches = re.allMatches(Platform.version).toList();
    if (matches.isNotEmpty) return matches.last.group(1) ?? 'unknown';
    return 'unknown';
  }

  /// 组装并异步写入一份崩溃报告（独立于 [AppLog] 的开关/队列）。
  ///
  /// [source] 描述崩溃来源（Flutter/Platform/Zone/手动）；[error] 为异常或
  /// [FlutterErrorDetails]；[stack] 为可选堆栈。
  static Future<void> _writeCrash({
    required String source,
    required Object error,
    StackTrace? stack,
    String? context,
  }) {
    final dir = _dir;
    if (dir == null) return Future.value();
    _chain = _chain.then((_) => _doWrite(dir, source, error, stack, context));
    return _chain;
  }

  static Future<void> _doWrite(
    Directory dir,
    String source,
    Object error,
    StackTrace? stack,
    String? context,
  ) async {
    try {
      final now = DateTime.now();
      final ts =
          '${now.year}${_two(now.month)}${_two(now.day)}_'
          '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}'
          '${now.millisecond.toString().padLeft(3, '0')}';
      final file = File('${dir.path}${Platform.pathSeparator}crash_$ts.log');
      final version = await _appVersion();
      final sb = StringBuffer();
      sb.writeln('=== Crash Report ===');
      sb.writeln('Time: $now');
      sb.writeln('Source: $source');
      if (context != null) sb.writeln('Context: $context');
      sb.writeln('Type: ${error.runtimeType}');
      sb.writeln('Error: ${_safeDescribe(error)}');
      sb.writeln('Stack Trace:');
      sb.writeln(stack?.toString() ?? '(no stack)');
      sb.writeln();
      sb.write(_deviceInfo(version));
      await file.writeAsString(sb.toString());
    } catch (_) {
      // 崩溃日志自身失败不致命，静默。
    }
  }

  static String _safeDescribe(Object e) {
    try {
      return e.toString();
    } catch (_) {
      return "Instance of '${e.runtimeType}'";
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 挂载 Flutter/Platform 未处理错误钩子（追加落盘，不改变框架默认行为）。
  ///
  /// 幂等：本会话只挂一次，重复调用直接返回，避免包装已包装的 handler 造成
  /// 同一崩溃重复落盘。测试里可直接调用以验证写入。
  static void installHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;
    // Flutter 层（构建/布局/断言）。保留默认行为，先落盘再委托原 handler：
    // 用局部记录原始回调并于调用时转发，避免覆盖框架逻辑。
    _installFlutterErrorHook();
    // PlatformDispatcher 层（引擎/平台线程异常）。与 FlutterError 类似原理。
    _installPlatformHook();
  }

  static void _installFlutterErrorHook() {
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      recordFlutterError(details);
      // 委托旧 handler（保留默认红字/抛错行为）；若为空则用框架默认。
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
  }

  static void _installPlatformHook() {
    final previous = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _writeCrash(source: 'PlatformDispatcher', error: error, stack: stack);
      // 返回原 handler 结果；若原本未设置，返回 false（让框架走默认路径）。
      return previous?.call(error, stack) ?? false;
    };
  }

  static void recordFlutterError(FlutterErrorDetails details) {
    // 统一路径：String 异常（断言/手动 reportError）与异常对象一样带 stack，
    // 不再分叉成两种写入格式。
    _writeCrash(
      source: 'FlutterError',
      error: details.exception,
      stack: details.stack,
      context: '${details.library ?? ''} ${details.context ?? ''}'.trim(),
    );
  }

  /// 在 main() 中包装 [runApp] 的外层 Zone，捕获未处理的异步异常。
  static void reportZoneError(Object error, StackTrace stack) {
    _writeCrash(source: 'Zone', error: error, stack: stack);
  }

  // ── 崩溃日志管理（供「崩溃日志」页展示/manage）────

  /// 列出崩溃目录中的所有崩溃日志，按修改时间倒序。
  static Future<List<LogFileMetadata>> listCrashLogFiles() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return const [];
    try {
      final files = await dir
          .list()
          .where((e) => e is File && (e.path.endsWith('.log')))
          .toList();
      final metas = <LogFileMetadata>[];
      for (final f in files.cast<File>()) {
        try {
          final stat = await f.stat();
          metas.add(
            LogFileMetadata(
              name: f.uri.pathSegments.last,
              path: f.path,
              sizeBytes: stat.size,
              modified: stat.modified,
              // 崩溃日志文件名以时间戳而非日期开头，不参与按天分组。
              date: '',
            ),
          );
        } catch (_) {
          // 单文件 stat 失败跳过。
        }
      }
      metas.sort((a, b) => b.modified.compareTo(a.modified));
      return metas;
    } catch (_) {
      return const [];
    }
  }

  /// 读取单个崩溃日志的完整内容。
  static Future<String?> readCrashLogFile(LogFileMetadata file) async {
    try {
      final f = File(file.path);
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 删除单个崩溃日志。
  static Future<bool> deleteCrashLogFile(LogFileMetadata file) async {
    try {
      final f = File(file.path);
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空所有崩溃日志（返回删除成功的数量）。
  static Future<int> clearAllCrashLogs() async {
    final metas = await listCrashLogFiles();
    var ok = 0;
    for (final m in metas) {
      if (await deleteCrashLogFile(m)) ok++;
    }
    return ok;
  }
}
