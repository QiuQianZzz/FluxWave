import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/logging/app_log.dart';
import '../core/netease/netease_api.dart';
import '../core/netease/netease_client.dart';
import '../core/netease/storage/netease_session_storage.dart';

/// 全局网易云状态管理。
///
/// 职责：
/// 1. 持有唯一的 [NeteaseClient] / [NeteaseApi] 实例，所有页面共享；
/// 2. 管理登录态（isLoggedIn / nickname / avatarUrl）；
/// 3. 启动时从 SharedPreferences 恢复会话 + 缓存 profile 先上屏；
/// 4. 提供登录成功回调 + 登出方法 + 手动刷新。
class NeteaseProvider extends ChangeNotifier {
  NeteaseClient? _client;
  NeteaseApi? _api;
  NeteaseSessionStorage? _storage;

  /// 当前共享的 API 实例（未初始化时抛异常，调用方应先确保 [initialized]）。
  NeteaseApi get api {
    final a = _api;
    if (a == null) {
      throw StateError('NeteaseProvider 未初始化，请先调用 init()');
    }
    return a;
  }

  /// 当前共享的 Client 实例。
  NeteaseClient get client {
    final c = _client;
    if (c == null) {
      throw StateError('NeteaseProvider 未初始化，请先调用 init()');
    }
    return c;
  }

  bool _initialized = false;
  bool get initialized => _initialized;

  /// 初始化完成的 Completer：让依赖 Netease 已就绪的调用（如播放器恢复快照时
  /// 取歌地址）可以等待，避免「PlayerProvider.init → _loadCurrent → netease.api」
  /// 早于 NeteaseProvider 的 async init 完成而抛 StateError 的启动竞态。
  ///
  /// 总会完成（init 失败也完成，避免等待方永久挂起）：是否可安全调 API 由
  /// [apiReady] 在 await 之后再判——[initialized] 表示「流程跑完」，
  /// apiReady 表示「[_api] 确实可用」。
  final Completer<void> _initDone = Completer<void>();
  Future<void> get initializedFuture => _initDone.future;

  /// [api] 是否已就绪（区别于 [initialized] 的「流程跑完」：init 中途失败时
  /// [_api] 为 null，即使 [initialized]==true 也不能调 API）。
  bool get apiReady => _api != null;

  bool _isLoggedIn = false;
  bool get isLoggedIn => _isLoggedIn;

  String? _nickname;
  String? get nickname => _nickname;

  String? _avatarUrl;
  String? get avatarUrl => _avatarUrl;

  /// 当前登录用户 id（未登录为 null）。
  int? _userId;
  int? get userId => _userId;

  /// 首次初始化加载（无缓存 profile 时为 true，有缓存或未登录时为 false）。
  bool _loading = true;
  bool get loading => _loading;

  /// 手动刷新中（用于 UI 刷新按钮状态）。
  bool _refreshing = false;
  bool get refreshing => _refreshing;

  /// Cookie 续期间隔。
  static const _refreshInterval = Duration(hours: 24);

  /// 从 SharedPreferences 恢复会话 + 缓存 profile 先上屏，后台静默验证。
  Future<void> init() async {
    try {
      _storage = await NeteaseSessionStorage.init();
      final snapshot = _storage!.load();
      final ctx = createContextFromSnapshot(snapshot);
      _client = NeteaseClient(context: ctx, storage: _storage);
      _api = NeteaseApi(_client!);

      // 缓存优先：从 SP 读 profile，有则立即上屏（notifyListeners 统一由 finally 触发）
      final cached = _storage!.loadProfile();
      if (cached != null && ctx.musicU != null && ctx.musicU!.isNotEmpty) {
        _isLoggedIn = true;
        _nickname = cached.nickname;
        _avatarUrl = cached.avatarUrl;
        // 一并恢复 userId：播放器恢复 / 歌单列表缓存读取都依赖它，
        // 否则要等后台 _verifyAndRefresh() 网络返回才就绪（时序窗口）。
        _userId = cached.userId;
        // 后台静默验证 + 更新
        _verifyAndRefresh();
        AppLog.info('恢复缓存登录态：${cached.nickname}，后台验证中', tag: 'auth');
        return;
      }

      // 无缓存但有 MUSIC_U → 需要网络请求确认，保持 loading
      if (ctx.musicU != null && ctx.musicU!.isNotEmpty) {
        AppLog.info('有 MUSIC_U 无 profile 缓存，网络确认登录态', tag: 'auth');
        await _verifyAndRefresh();
      } else {
        AppLog.info('未登录：无有效会话，进入匿名态', tag: 'auth');
        _loading = false;
        _ensureAnonymousToken();
      }
    } catch (e, st) {
      // SharedPreferences 初始化失败 → 保持未登录态
      AppLog.error('会话恢复失败，保持未登录', tag: 'auth', error: e, stack: st);
    } finally {
      _initialized = true;
      _loading = false;
      if (!_initDone.isCompleted) _initDone.complete();
      notifyListeners();
    }
  }

  /// 调 loginStatus 验证 cookie 有效性，成功时更新 profile 并按需续期。
  ///
  /// - 成功 → 更新 nickname/avatarUrl + 持久化 + 检查 24h 续期
  /// - profile 为空 → cookie 失效（过期/被踢/半登录态），清空登录态 + session
  ///   （避免失效 MUSIC_U 留在 ctx 导致后续接口异常 + 每次启动浪费请求）
  /// - 网络失败 → 保留缓存 profile 不变（离线可用性）
  Future<void> _verifyAndRefresh() async {
    final api = _api;
    final client = _client;
    final storage = _storage;
    if (api == null || client == null || storage == null) return;
    try {
      final profile = await api.profile();
      if (profile != null) {
        final nickname = profile['nickname']?.toString() ?? '';
        final avatarUrl = profile['avatarUrl']?.toString() ?? '';
        final userId = int.tryParse(profile['userId']?.toString() ?? '') ?? 0;
        _isLoggedIn = true;
        _nickname = nickname;
        _avatarUrl = avatarUrl;
        _userId = userId;
        await storage.saveProfile(nickname, avatarUrl, userId);
        // 24h 续期间隔检查
        final last = storage.getLastRefreshAt();
        if (last == null ||
            DateTime.now().difference(last) > _refreshInterval) {
          await _refreshLogin();
        }
      } else {
        // cookie 失效（code=301/401/403 或 code=200 但 profile 为空）
        // → 清空登录态 + 失效的 session（MUSIC_U / cookies / 持久化）
        _isLoggedIn = false;
        _nickname = null;
        _avatarUrl = null;
        _userId = null;
        client.ctx.musicU = null;
        client.ctx.anonToken = null;
        client.ctx.cookies.clear();
        await storage.clear();
        await storage.clearProfile();
        await storage.clearLastRefreshAt();
        AppLog.warn('登录态已失效（cookie 过期/被踢），已清空会话', tag: 'auth');
      }
    } catch (e, st) {
      // 网络失败保留缓存 profile，不强制登出
      AppLog.warn('登录态验证失败（网络异常），保留缓存', tag: 'auth', error: e, stack: st);
    }
    notifyListeners();
  }

  /// 调 loginRefresh 续期 cookie，失败静默忽略。
  Future<void> _refreshLogin() async {
    final api = _api;
    final storage = _storage;
    if (api == null || storage == null) return;
    try {
      await api.loginRefresh();
      await storage.saveLastRefreshAt(DateTime.now());
      AppLog.info('cookie 续期成功', tag: 'auth');
    } catch (e, st) {
      // 续期失败不影响当前 session
      AppLog.warn('cookie 续期失败，不影响当前会话', tag: 'auth', error: e, stack: st);
    }
  }

  /// 匿名注册失败重试冷却时长：实测服务端不再下发 token，注册必失败且快速连发
  /// 会触发限流(400)。加冷却避免每次启动都打 anti-crawler/register 接口的风控噪音。
  static const _anonRetryCooldown = Duration(hours: 6);

  /// 未登录且无 MUSIC_A 时，后台注册匿名态：
  /// 让未登录场景的 eapi/weapi 请求也携带匿名 token，贴近参考项目"始终带 MUSIC_A"
  /// 的行为，减少接口被拒 / 触发风控。成功由 registerAnon 内部落盘。
  ///
  /// 失败进入冷却（见 [saveAnonRetryAfter]），冷却期内不再重试，避免每启动重复打接口。
  void _ensureAnonymousToken() {
    final client = _client;
    if (client == null) return;
    final cookies = client.ctx.cookies;
    final hasAnon =
        (client.ctx.anonToken?.isNotEmpty ?? false) ||
        (cookies['MUSIC_A']?.isNotEmpty ?? false);
    if (hasAnon) return;
    final storage = _storage;
    final retryAfter = storage?.getAnonRetryAfter();
    if (!shouldAttemptAnon(now: DateTime.now(), retryAfter: retryAfter)) return;
    unawaited(_attemptAnonRegister(client, storage));
  }

  Future<void> _attemptAnonRegister(
    NeteaseClient client,
    NeteaseSessionStorage? storage,
  ) async {
    var ok = false;
    try {
      ok = await client.registerAnon();
    } catch (e, st) {
      ok = false;
      AppLog.warn(
        '匿名注册失败，进入冷却 ${_anonRetryCooldown.inHours}h',
        tag: 'netease',
        error: e,
        stack: st,
      );
    }
    if (ok) return; // 成功后 hasAnon=true，下次启动直接跳过
    if (storage != null) {
      await storage.saveAnonRetryAfter(DateTime.now().add(_anonRetryCooldown));
    }
  }

  /// 手动刷新用户资料（ProfilePage 刷新按钮调用）。
  ///
  /// 强制调 loginStatus 更新，有明确 UI 反馈。
  Future<void> refreshUser() async {
    if (!_isLoggedIn) return;
    _refreshing = true;
    notifyListeners();
    try {
      await _verifyAndRefresh();
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  /// QR 登录成功后调用：更新登录态 + 持久化 profile。
  ///
  /// [profile] 由 QrLoginPage 的 qr.profile() 传入，避免重复调 loginStatus()。
  /// 若 profile 为空（网络异常），仍标记为已登录（MUSIC_U 已在 client.ctx 里）。
  Future<void> onLoginSuccess([Map<String, dynamic>? profile]) async {
    _isLoggedIn = true;
    if (profile != null) {
      _nickname = profile['nickname']?.toString();
      _avatarUrl = profile['avatarUrl']?.toString();
      _userId = int.tryParse(profile['userId']?.toString() ?? '');
    }
    notifyListeners();
    // 后台持久化，不阻塞 UI
    final storage = _storage;
    if (storage == null) return;
    if (profile != null) {
      final userId = int.tryParse(profile['userId']?.toString() ?? '') ?? 0;
      await storage.saveProfile(_nickname ?? '', _avatarUrl ?? '', userId);
    }
    // QR 登录成功即代表 cookie 新鲜，无论 profile 是否拿到都记录续期时间，
    // 避免下次 _verifyAndRefresh 因 lastRefreshAt 为空立即触发续期。
    await storage.saveLastRefreshAt(DateTime.now());
  }

  /// 登出：通知服务端 + 清空本地会话 + 清空 profile 缓存（deviceId 保留）。
  ///
  /// 无论服务端 logout 成功失败，最后都强制清本地。
  Future<void> logout() async {
    final api = _api;
    final client = _client;
    final storage = _storage;
    try {
      if (api != null) await api.logout();
      AppLog.info('登出成功（服务端已通知）', tag: 'auth');
    } catch (e, st) {
      // 服务端失败不阻塞本地清理
      AppLog.warn('服务端登出失败，已本地清理', tag: 'auth', error: e, stack: st);
    } finally {
      await storage?.clear();
      await storage?.clearProfile();
      await storage?.clearLastRefreshAt();
      if (client != null) {
        client.ctx.musicU = null;
        client.ctx.anonToken = null;
        client.ctx.cookies.clear();
      }
      _isLoggedIn = false;
      _nickname = null;
      _avatarUrl = null;
      _userId = null;
      notifyListeners();
    }
  }
}

/// 匿名注册是否应当重试：已有匿名态或有未过期冷却 → 不尝试。
///
/// 纯函数便于离线单测（避免每启动重复打 anti-crawler/register 接口触发风控）。
bool shouldAttemptAnon({
  bool hasAnon = false,
  DateTime? retryAfter,
  DateTime? now,
}) {
  if (hasAnon) return false;
  final t = now ?? DateTime.now();
  if (retryAfter != null && t.isBefore(retryAfter)) return false;
  return true;
}
