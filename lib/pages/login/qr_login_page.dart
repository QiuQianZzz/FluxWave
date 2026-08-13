import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/netease/netease_auth.dart';
import '../../core/netease/netease_client.dart';
import '../../core/logging/app_log.dart';
import '../../core/platform_utils.dart';
import '../../providers/netease_provider.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/title_bar.dart';

/// 二维码登录页（简约 MD3）。
///
/// 状态：
/// - idle：刚进入，正在 newKey()；
/// - qrReady：二维码已展示，轮询中 (801/802)；
/// - success：803 成功（展示 nickname + avatar 预览）；
/// - error：异常/过期，展示重试按钮。
class QrLoginPage extends StatefulWidget {
  const QrLoginPage({super.key});

  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  NeteaseQrLogin? _qr;
  String? _qrUrl;
  int _lastCode = 801;
  String? _nickname;
  String? _avatarUrl;
  Object? _lastError;
  Timer? _timer;
  bool _loading = true;

  // 用于安全等待 Provider 初始化（dispose 时清理，防泄漏）
  Completer<void>? _initCompleter;
  void Function()? _initListener;
  NeteaseProvider? _waitingProvider;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final provider = context.read<NeteaseProvider>();
    if (!provider.initialized) {
      _initCompleter = Completer<void>();
      _waitingProvider = provider;
      _initListener = () {
        if (provider.initialized && !_initCompleter!.isCompleted) {
          provider.removeListener(_initListener!);
          _initCompleter!.complete();
        }
      };
      provider.addListener(_initListener!);
      await _initCompleter!.future;
    }
    if (!mounted) return;
    _qr = NeteaseQrLogin(provider.api);
    if (provider.isLoggedIn) {
      setState(() {
        _loading = false;
        _lastCode = 803;
        _nickname = provider.nickname;
        _avatarUrl = provider.avatarUrl;
      });
      return;
    }
    await _refreshKey();
  }

  Future<void> _refreshKey() async {
    final qr = _qr;
    if (qr == null) return;
    setState(() {
      _loading = true;
      _lastError = null;
    });
    _timer?.cancel();
    String k;
    try {
      k = await qr.newKey();
    } catch (e, st) {
      if (!mounted) return;
      AppLog.warn('二维码获取失败', tag: 'auth', error: e, stack: st);
      setState(() {
        _loading = false;
        _lastError = e;
      });
      return;
    }
    final url = qr.qrUrl(k);
    setState(() {
      _qrUrl = url;
      _lastCode = 801;
      _nickname = null;
      _avatarUrl = null;
      _loading = false;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final r = await qr.check(k);
        if (!mounted) return;
        setState(() {
          _lastCode = r.code;
          if (r.nickname != null) _nickname = r.nickname;
          if (r.avatarUrl != null) _avatarUrl = r.avatarUrl;
        });
        if (r.isExpired) {
          _timer?.cancel();
          setState(() {
            _lastError = NeteaseException('二维码已过期', code: 800);
          });
        } else if (r.isSuccess) {
          _timer?.cancel();
          final prof = await qr.profile();
          if (!mounted) return;
          setState(() {
            _nickname = prof?['nickname']?.toString() ?? _nickname;
            _avatarUrl = prof?['avatarUrl']?.toString() ?? _avatarUrl;
          });
          if (mounted) {
            context.read<NeteaseProvider>().onLoginSuccess(prof);
            AppToast.show(context, '登录成功：${_nickname ?? '用户'}');
            AppLog.info('二维码登录成功：${_nickname ?? '未知用户'}', tag: 'auth');
          }
        }
      } catch (e, st) {
        if (!mounted) return;
        AppLog.warn('二维码登录扫码轮询异常', tag: 'auth', error: e, stack: st);
        setState(() => _lastError = e);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_initListener != null && _waitingProvider != null) {
      _waitingProvider!.removeListener(_initListener!);
    }
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      _initCompleter!.complete();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDesktop = PlatformUtils.isDesktop && TitleBar.enabled;

    final scaffold = Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '扫码登录',
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '打开对应音乐 App → 侧边栏「扫一扫」',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    Center(child: _buildQrArea(theme, cs)),
                    const SizedBox(height: 24),
                    _buildStatus(theme, cs),
                    if (_lastError != null) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _refreshKey,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('重新获取二维码'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 桌面端：顶部加自定义标题栏用于窗口拖动和控制
    if (isDesktop) {
      return Column(
        children: [
          const TitleBar(),
          Expanded(child: scaffold),
        ],
      );
    }
    return scaffold;
  }

  Widget _buildQrArea(ThemeData theme, ColorScheme cs) {
    final isOk = _lastCode == 803;
    final isReady = !_loading && _qrUrl != null && !isOk;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 自适应：窄屏缩到可用宽，宽屏上限 280，避免固定 280 在窄屏横向溢出。
        final side = constraints.maxWidth.clamp(0.0, 280.0);
        final imageSide = side - 32; // 减去 Padding(16×2)
        return SizedBox(
          width: side,
          height: side,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: _loading
                ? Container(
                    color: cs.surfaceContainerHigh,
                    child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  )
                : isReady
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: QrImageView(
                      data: _qrUrl!,
                      version: QrVersions.auto,
                      size: imageSide,
                      gapless: true,
                      errorCorrectionLevel: QrErrorCorrectLevel.H,
                      eyeStyle: QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: cs.onSurface,
                      ),
                      dataModuleStyle: QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: cs.onSurface,
                      ),
                    ),
                  )
                : isOk
                ? _SuccessMark(avatarUrl: _avatarUrl)
                : const SizedBox.shrink(),
          ),
        );
      },
    );
  }

  String get _statusBadge => switch (_lastCode) {
    801 => '等待扫码',
    802 => '请在手机上确认',
    803 => '登录成功',
    800 => '已过期',
    _ => '状态 $_lastCode',
  };

  Widget _buildStatus(ThemeData theme, ColorScheme cs) {
    final tip = switch (_lastCode) {
      803 => '欢迎回来，${_nickname ?? '亲爱的用户'}',
      802 => _nickname == null ? '请在手机上点击「确认登录」' : '已识别账号：$_nickname，等待确认',
      800 => '二维码已过期，请点击下方按钮重新获取',
      _ => '请使用对应音乐 App 扫描上方二维码',
    };
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_statusIcon, size: 18, color: _statusColor(cs)),
            const SizedBox(width: 6),
            Text(
              _statusBadge,
              style: theme.textTheme.labelLarge?.copyWith(
                color: _statusColor(cs),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          tip,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  IconData get _statusIcon => switch (_lastCode) {
    801 => Icons.qr_code_scanner_rounded,
    802 => Icons.check_circle_outline_rounded,
    803 => Icons.verified_rounded,
    800 => Icons.refresh_rounded,
    _ => Icons.info_outline_rounded,
  };

  Color _statusColor(ColorScheme cs) => switch (_lastCode) {
    803 => cs.primary,
    802 => cs.tertiary,
    800 => cs.error,
    _ => cs.onSurfaceVariant,
  };
}

/// 803 成功页：头像 + 「登录成功」文案，简约无渐变。
class _SuccessMark extends StatelessWidget {
  final String? avatarUrl;
  const _SuccessMark({this.avatarUrl});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      color: cs.surfaceContainerHigh,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 44,
            backgroundColor: cs.primaryContainer,
            child: avatarUrl != null
                ? CircleAvatar(
                    radius: 40,
                    backgroundImage: NetworkImage(avatarUrl!),
                  )
                : Icon(
                    Icons.check_rounded,
                    color: cs.onPrimaryContainer,
                    size: 44,
                  ),
          ),
          const SizedBox(height: 16),
          Text('登录成功', style: theme.textTheme.titleLarge),
        ],
      ),
    );
  }
}
