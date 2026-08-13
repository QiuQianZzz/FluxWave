import 'dart:async';
import 'dart:io';

import '../app_dirs.dart';

/// 应用运行日志级别。
///
/// 仅用作标记（error 附 stack、warn 异常、info 常规、debug 细粒度），
/// 默认**全量落盘**（不设最小级别开关）——本系统面向「用户使用后反馈排障」，
/// dev 环境直接在代码里 `print`，无需区分 release/debug 包体。
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warn(2, 'WARN'),
  error(3, 'ERROR');

  const LogLevel(this.severity, this.label);
  final int severity;
  final String label;
}

/// 滚动文件日志：追加写入 `logs/` 目录，**按日期分文件** + 按大小切片 + 按文件数/总量清理。
///
/// - 存储：`getApplicationSupportDirectory()/logs/`（可用时）。
/// - **按日期分文件**：每天一个主文件 `yyyy-MM-dd.log`。某天数据量大、
///   超过 [_maxFileBytes]（4MB）时切到该天的 `yyyy-MM-dd_<ts>.log`（主文件新建，
///   新旧内容仍同一天统计），跨天后自动开新日期文件。
/// - 清理：保留 ≤ [_maxFiles] 个文件、总量 ≤ [_maxTotalBytes]，回收最旧。
///   （单文件上限防「单文件巨大」，总量上限防「滚出一堆文件塞满盘」，双触发。）
///   运行时每 [_pruneEvery] 次写入兜底清理一次（不依赖重启/退出）。
/// - 防御 1【重入保护】：写入自身失败（磁盘满/权限异常）→ 永久进入 [broken]，
///   后续调用静默丢弃、绝不抛到调用方，避免错误处理器再写日志递归死循环。
/// - 防御 2【熔断】：单会话写条数 >[_maxFault] OR 待落队列 >[_maxPending]
///   之后直接丢弃并打印一次熔断标记，防止热循环刷屏写爆磁盘。
/// - 串行：所有写入进同一 Future 链，杜绝并发交错。
///
/// 埋点纪律（决定日志量，而非级别开关）：只打关键行为（网络/播放/鉴权/
/// 落盘成败），不打 UI 骨架/进度心跳/请求参数这类高频噪音。
class AppLog {
  AppLog._();

  /// 单文件最大字节。
  static int _maxFileBytes = 4 * 1024 * 1024; // 4MB

  /// 保留的最大日志文件数（含各日期文件，`_prune` 按此回收最旧）。
  static int _maxFiles = 10;

  /// 允许的最大总字节（旧文件会被回收）。
  static int _maxTotalBytes = 20 * 1024 * 1024; // ~20MB

  /// 单会话连续写条数熔断阈值。
  static int _maxFault = 50000;

  /// 待落盘队列长度熔断阈值（防写入速率跟不上时无界堆积）。
  static int _maxPending = 5000;

  /// 单条日志最多保留的堆栈行数（顶部 N 帧 + 省略标记）。
  ///
  /// Dart/Flutter 异步栈往往数百行（每 await 插一段中间帧 + provider 管道帧），
  /// 对高频的 WARN/ERROR 逐行落盘会迅速撑爆日志。根因线索都集中在栈顶部
  /// （#0 抛错点 + 调用链），尾部是重复噪音，故保留顶部 N 帧即可。崩溃日志
  /// AppCrash 保持全文（频率低、单文件一事件，需完整栈排障）。
  static int _maxStackLines = 40;

  /// 每隔多少次写入强制执行一次 [_prune]（运行时兜底，避免只靠启动清理）。
  static int _pruneEvery = 256;

  static bool _enabled = false;
  static bool _broken = false;
  static bool _tripped = false;
  static int _count = 0;
  static int _pending = 0;
  static int _writesSincePrune = 0;
  static Directory? _dir;

  /// 用户主开关：默认开启落盘。与 [_broken]/[_enabled] 语义独立——
  /// 关闭时只是「不再写盘」，不视为磁盘损坏。供设置页开关控制。
  static bool _userEnabled = true;

  /// 串行写队列：所有引擎排队执行，避免并发交错。
  static Future<void> _chain = Future.value();

  /// 是否已初始化可写。
  static bool get enabled => _enabled;

  /// 是否进入「写入已损坏」静默态（供测试/诊断查询）。任何监控或单测。
  static bool get broken => _broken;

  /// 用户主导的落盘总开关（默认开启）。关闭时日志不再写盘，但历史文件仍可查。
  static bool get userEnabled => _userEnabled;

  /// 设置用户落盘总开关。关闭 = 停止写盘；开启 = 恢复写盘。
  static void setUserEnabled(bool v) => _userEnabled = v;

  /// 日志所在目录（未初始化时为 null，供日志管理页读取文件列表）。
  static Directory? get logsDirectory => _dir;

  /// 初始化日志目录（`logs/`）。
  ///
  /// [directory] 指定时直接用该目录（测试/可注入场景）；缺省用平台
  /// application support 目录 + `/logs`。仅首次生效，幂等。
  static Future<void> init({String? directory}) async {
    if (_dir != null) return;
    var ok = false;
    try {
      if (directory != null) {
        _dir = Directory(directory);
      } else {
        _dir = await appSupportDir('logs');
      }
      await _dir!.create(recursive: true);
      _enabled = true;
      ok = true;
    } catch (_) {
      // 目录初始化失败：静默禁用，绝不影响主流程。
      _enabled = false;
      _broken = true;
    }
    // 仅在正式启用成功后才执行一次性清理；await 而非 unawaited，避免与后续
    // 首个 _write 并发操作目录的竞态（清理失败已被 _prune 内部吞掉）。
    if (ok) await _prune();
  }

  /// 供测试直接指定目录与（可选的）极限值，并启用。
  static void configureForTest(
    String directory, {
    int? maxFileBytes,
    int? maxFiles,
    int? maxTotalBytes,
    int? maxFault,
    int? maxPending,
    int? maxStackLines,
  }) {
    _dir = Directory(directory);
    _enabled = true;
    _broken = false;
    _count = 0;
    _pending = 0;
    _tripped = false;
    _chain = Future.value();
    if (maxFileBytes != null) _maxFileBytes = maxFileBytes;
    if (maxFiles != null) _maxFiles = maxFiles;
    if (maxTotalBytes != null) _maxTotalBytes = maxTotalBytes;
    if (maxFault != null) _maxFault = maxFault;
    if (maxPending != null) _maxPending = maxPending;
    if (maxStackLines != null) _maxStackLines = maxStackLines;
    unawaited(_prune());
  }

  /// 复位为未初始化状态（测试 tearDown 用）。
  static void resetForTest() {
    _dir = null;
    _enabled = false;
    _broken = false;
    _count = 0;
    _pending = 0;
    _tripped = false;
    _chain = Future.value();
    _maxFileBytes = 4 * 1024 * 1024;
    _maxFiles = 10;
    _maxTotalBytes = 20 * 1024 * 1024;
    _maxFault = 50000;
    _maxPending = 5000;
    _maxStackLines = 40;
    _pruneEvery = 256;
    _writesSincePrune = 0;
    _userEnabled = true;
  }

  /// 等待所有待落盘日志写入完成（测试/退出兜底使用）。
  static Future<void> flush() async {
    await _chain;
    await _prune();
  }

  static void _schedule(
    LogLevel level,
    String msg, {
    Object? error,
    StackTrace? stack,
  }) {
    if (!_enabled || _broken || !_userEnabled) return;

    // 熔断 1：单会话写条数上限。
    if (_count >= _maxFault) {
      _trip('[FROZE] log fault limit reached, further entries discarded');
      return;
    }
    _count++;
    if (_tripped) return;

    _enqueue(_format(level, msg, error: error, stack: stack));
  }

  /// 进入熔断态并写一行一次性标记（不再受熔断检查，避免递归）。
  static void _trip(String marker) {
    if (_tripped) return;
    _tripped = true;
    // 直接追加，不走 _schedule/_enqueue 的熔断检查。
    _pending++;
    _chain = _chain.then((_) async {
      await _write(marker);
      _pending--;
    });
  }

  static void _enqueue(String line) {
    // 熔断 2：待落队列过长（写入速率跟不上时）→ 丢弃，避免无界堆积。
    if (_pending >= _maxPending) {
      _trip('[DROPPED] pending limit reached, further entries discarded');
      return;
    }
    _pending++;
    _chain = _chain.then((_) async {
      await _write(line);
      _pending--;
    });
  }

  static String _format(
    LogLevel level,
    String msg, {
    Object? error,
    StackTrace? stack,
  }) {
    final now = DateTime.now();
    final ts =
        '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final sb = StringBuffer('$ts [${level.label}] $msg');
    if (error != null) {
      // 优先用真实 toString()（保留 StateError 的 "Bad state: ..." 等有效信息）；
      // 若极端情况下 toString() 自身抛错，回退为类型名，保证日志永不崩溃。
      sb.write(' | err=${_safeDescribe(error)}');
      if (stack != null) sb.write('\n${_truncateStack(stack)}');
    }
    return sb.toString();
  }

  /// 截断堆栈到 [_maxStackLines] 行（保留顶部，尾部附省略标记）。
  ///
  /// 0/负值 = 不截断（保留全文）。仅用于非崩溃高频日志（崩溃日志 AppCrash
  /// 全量保留，见类注释）。
  static String _truncateStack(StackTrace stack) {
    final text = stack.toString();
    if (_maxStackLines <= 0 || text.isEmpty) return text;
    final lines = text.split('\n');
    if (lines.length <= _maxStackLines) return text;
    final cut = lines.sublist(0, _maxStackLines);
    return '${cut.join('\n')}\n'
        '... (${lines.length - _maxStackLines} 帧已省略)';
  }

  /// 安全地把错误对象转成可读文本：优先真实 [toString]，异常则回退类型名。
  static String _safeDescribe(Object e) {
    try {
      return e.toString();
    } catch (_) {
      return "Instance of '${e.runtimeType}'";
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 生成 `yyyy-MM-dd` 前缀（用作日期文件主名）。
  static String _todayStr([DateTime? now]) {
    final d = now ?? DateTime.now();
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  /// 真正追加一行到「当天」文件（串行队列中的元素）。
  ///
  /// 主文件按日期命名 `yyyy-MM-dd.log`；某天单文件超 [_maxFileBytes]
  /// → rename 到 `yyyy-MM-dd_<ts>.log` 保留该天已写内容，新建空主文件续写。
  static Future<void> _write(String line) async {
    final dir = _dir!;
    final today = _todayStr();
    final file = File('${dir.path}${Platform.pathSeparator}$today.log');

    try {
      if (await file.exists()) {
        final len = await file.length();
        if (len + line.length > _maxFileBytes) {
          final ts = DateTime.now().millisecondsSinceEpoch;
          await file.rename(
            '${dir.path}${Platform.pathSeparator}${today}_$ts.log',
          );
        }
      }
      await file.writeAsString('$line\n', mode: FileMode.writeOnlyAppend);
      // 运行时兜底清理：定期（而非只靠启动/退出）触发，防磁盘无限膨胀。
      if (++_writesSincePrune >= _pruneEvery) {
        _writesSincePrune = 0;
        await _prune();
      }
    } catch (_) {
      // 重入保护：写入自身失败 → 静默。不再尝试、不再抛出。
      _broken = true;
      _enabled = false;
    }
  }

  /// 按「文件数上限 + 总字节上限」清理旧文件（保留最新 [_maxFiles] 个）。
  ///
  /// 两个上限**都要**执行：先按文件数删最旧，再（若仍超总量）继续删最旧。
  static Future<void> _prune() async {
    if (!_enabled || _broken) return;
    try {
      final dir = _dir;
      if (dir == null) return;
      final files = await dir
          .list()
          .where((e) => e is File && (e.path.endsWith('.log')))
          .toList();

      // 按最近修改时间倒序（最新在前）。
      final sorted = await Future.wait(
        files.map((f) async => (f as File, (await f.stat()).modified)),
      );
      sorted.sort((a, b) => b.$2.compareTo(a.$2));

      var total = 0;
      for (final (f, _) in sorted) {
        total += await f.length();
      }

      // 上限 1：文件数过多 → 删最旧，直到数量达标。
      while (sorted.length > _maxFiles) {
        final last = sorted.removeLast();
        final len = await last.$1.length();
        await last.$1.delete();
        total -= len;
      }

      // 上限 2：总量超限 → 仍从最旧删，直到总量达标。
      while (total > _maxTotalBytes && sorted.isNotEmpty) {
        final last = sorted.removeLast();
        final len = await last.$1.length();
        await last.$1.delete();
        total -= len;
      }
    } catch (_) {
      // 清理失败不致命，忽略。
    }
  }

  // ── 日志管理（列表/读取/删除，供「应用日志」页使用）────

  /// 单个日志文件的信息。
  static Future<List<LogFileMetadata>> listLogFiles() async {
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
          // `2026-08-07.log` / `2026-08-07_1234.log`：取文件名前 10 位为日期。
          final name = f.uri.pathSegments.last;
          metas.add(
            LogFileMetadata(
              name: name,
              path: f.path,
              sizeBytes: stat.size,
              modified: stat.modified,
              date: name.length >= 10 ? name.substring(0, 10) : '',
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

  /// 读取单个日志文件的完整内容（当前仅返回原始文本，供查看/复制）。
  /// 单文件上限 ~4MB，配合「仅当前文件进内存」策略，无累积占用。
  static Future<String?> readLogFile(LogFileMetadata file) async {
    try {
      final f = File(file.path);
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 删除单个日志文件。
  static Future<bool> deleteLogFile(LogFileMetadata file) async {
    try {
      final f = File(file.path);
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空所有日志文件（返回删除成功的数量）。
  static Future<int> clearAllLogs() async {
    final metas = await listLogFiles();
    var ok = 0;
    for (final m in metas) {
      if (await deleteLogFile(m)) ok++;
    }
    return ok;
  }

  // ── 对外门面 ────────────────────────────────

  static void debug(String msg, {String? tag}) =>
      _schedule(LogLevel.debug, tag != null ? '[$tag] $msg' : msg);

  static void info(String msg, {String? tag}) =>
      _schedule(LogLevel.info, tag != null ? '[$tag] $msg' : msg);

  static void warn(
    String msg, {
    String? tag,
    Object? error,
    StackTrace? stack,
  }) => _schedule(
    LogLevel.warn,
    tag != null ? '[$tag] $msg' : msg,
    error: error,
    stack: stack,
  );

  static void error(
    String msg, {
    String? tag,
    Object? error,
    StackTrace? stack,
  }) => _schedule(
    LogLevel.error,
    tag != null ? '[$tag] $msg' : msg,
    error: error,
    stack: stack,
  );
}

/// 日志文件元信息（供「应用日志」列表页展示与管理）。
class LogFileMetadata {
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modified;

  /// 文件名前 10 位日期（`2026-08-07`），用于按天分组展示。
  final String date;
  const LogFileMetadata({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    required this.date,
  });
}

/// 日志数据源类型：运行日志（AppLog）或崩溃日志（AppCrash）。
enum LogSourceKind {
  /// 普通运行日志（按日期分文件）。
  runtime,

  /// 崩溃日志（独立 crash/ 目录，含堆栈与设备信息）。
  crash,
}
