import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../netease_client.dart';
import '../request.dart';

/// 持久化的会话快照（从 shared_preferences 读出后返回给调用方）。
///
/// 字段：
/// - [deviceId]：稳定设备指纹（跨启动不变，解决"每次启动=新设备"风控）；
/// - [cookies]：MUSIC_U / MUSIC_A / __csrf / os 等，直接存 `Map<String,String>`；
/// - [anonToken]：`/api/register/anonimous` 返回的匿名令牌；
/// - [updatedAt]：最后一次写入时间，用于判断过期。
class NeteaseSessionSnapshot {
  final String? deviceId;
  final Map<String, String> cookies;
  final String? anonToken;
  final DateTime? updatedAt;

  const NeteaseSessionSnapshot({
    this.deviceId,
    this.cookies = const {},
    this.anonToken,
    this.updatedAt,
  });

  bool get isEmpty =>
      (deviceId == null || deviceId!.isEmpty) &&
      cookies.isEmpty &&
      (anonToken == null || anonToken!.isEmpty);
}

/// 用户资料缓存快照（`profile` + `lastRefreshAt` 持久化）。
class NeteaseProfileSnapshot {
  final String nickname;
  final String avatarUrl;
  final int userId;
  final DateTime cachedAt;

  const NeteaseProfileSnapshot({
    required this.nickname,
    required this.avatarUrl,
    required this.userId,
    required this.cachedAt,
  });
}

/// SharedPreferences 持久化层：保存/加载网易云会话
///
/// SESSION_MUTATING 集合：
/// - loginQrCheck 803（扫码成功）
/// - loginRefresh 200（续期）
/// - registerAnon 200（匿名注册）
/// - reset() / logout code=200（登出清空）
class NeteaseSessionStorage {
  static const String _kDeviceId = 'netease_session_device_id';
  static const String _kCookies = 'netease_session_cookies_v1';
  static const String _kAnonToken = 'netease_session_anon_token';
  static const String _kUpdatedAt = 'netease_session_updated_at_ms';

  // Profile 缓存键（`profile`, `lastRefreshAt`）
  static const String _kProfileNickname = 'netease_profile_nickname';
  static const String _kProfileAvatarUrl = 'netease_profile_avatar_url';
  static const String _kProfileUserId = 'netease_profile_user_id';
  static const String _kProfileCachedAt = 'netease_profile_cached_at_ms';
  static const String _kLastRefreshAt = 'netease_last_refresh_at_ms';
  static const String _kAnonRetryAfter = 'netease_anon_retry_after_ms';

  final SharedPreferences _prefs;

  NeteaseSessionStorage._(this._prefs);

  /// 同步初始化（shared_preferences 首次启动会走平台 channel，之后都是内存缓存）。
  static Future<NeteaseSessionStorage> init() async {
    final prefs = await SharedPreferences.getInstance();
    return NeteaseSessionStorage._(prefs);
  }

  /// 从 SP 加载会话快照。
  NeteaseSessionSnapshot load() {
    final deviceId = _prefs.getString(_kDeviceId);
    final anonToken = _prefs.getString(_kAnonToken);
    final rawCookies = _prefs.getString(_kCookies);
    final updatedAtMs = _prefs.getInt(_kUpdatedAt);

    Map<String, String> cookies = const {};
    if (rawCookies != null && rawCookies.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCookies);
        if (decoded is Map<String, dynamic>) {
          cookies = decoded.map(
            (k, v) => MapEntry(k, v == null ? '' : v.toString()),
          );
        }
      } catch (_) {
        // JSON 损坏直接丢弃，不要用旧数据污染新会话
      }
    }

    return NeteaseSessionSnapshot(
      deviceId: deviceId,
      cookies: cookies,
      anonToken: anonToken,
      updatedAt: updatedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
    );
  }

  /// 保存 [NeteaseRequestContext] 当前状态到 SP。
  Future<void> save(NeteaseRequestContext ctx) async {
    if (ctx.deviceId.isNotEmpty) {
      await _prefs.setString(_kDeviceId, ctx.deviceId);
    }
    if (ctx.cookies.isNotEmpty) {
      await _prefs.setString(_kCookies, jsonEncode(ctx.cookies));
    }
    final at = ctx.anonToken;
    if (at != null && at.isNotEmpty) {
      await _prefs.setString(_kAnonToken, at);
    }
    await _prefs.setInt(_kUpdatedAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// 清空账号级会话（登出 / 重置场景）。
  ///
  /// ⚠️ **只清 cookies / anonToken / updatedAt，不动 deviceId**。
  /// deviceId 是"安装级设备指纹"（跟 App 绑定，不跟账号绑定），
  /// 登出换账号不换设备，清掉反而会导致下次启动重新 generate → 对网易云当新设备触发风控。
  Future<void> clear() async {
    await Future.wait([
      _prefs.remove(_kCookies),
      _prefs.remove(_kAnonToken),
      _prefs.remove(_kUpdatedAt),
    ]);
  }

  // ── Profile 缓存 ──

  /// 保存用户资料到 SP。
  Future<void> saveProfile(
    String nickname,
    String avatarUrl,
    int userId,
  ) async {
    await Future.wait([
      _prefs.setString(_kProfileNickname, nickname),
      _prefs.setString(_kProfileAvatarUrl, avatarUrl),
      _prefs.setInt(_kProfileUserId, userId),
      _prefs.setInt(_kProfileCachedAt, DateTime.now().millisecondsSinceEpoch),
    ]);
  }

  /// 从 SP 加载缓存的用户资料，无缓存时返回 null。
  NeteaseProfileSnapshot? loadProfile() {
    final nickname = _prefs.getString(_kProfileNickname);
    final avatarUrl = _prefs.getString(_kProfileAvatarUrl);
    final userId = _prefs.getInt(_kProfileUserId);
    final cachedAtMs = _prefs.getInt(_kProfileCachedAt);
    if (nickname == null || avatarUrl == null || userId == null) return null;
    return NeteaseProfileSnapshot(
      nickname: nickname,
      avatarUrl: avatarUrl,
      userId: userId,
      cachedAt: cachedAtMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(cachedAtMs),
    );
  }

  /// 清空用户资料缓存（登出时调用）。
  Future<void> clearProfile() async {
    await Future.wait([
      _prefs.remove(_kProfileNickname),
      _prefs.remove(_kProfileAvatarUrl),
      _prefs.remove(_kProfileUserId),
      _prefs.remove(_kProfileCachedAt),
    ]);
  }

  // ── Cookie 续期时间戳 ──

  /// 上次 cookie 续期（loginRefresh）的时间，无记录时返回 null。
  DateTime? getLastRefreshAt() {
    final ms = _prefs.getInt(_kLastRefreshAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 记录 cookie 续期时间。
  Future<void> saveLastRefreshAt(DateTime time) async {
    await _prefs.setInt(_kLastRefreshAt, time.millisecondsSinceEpoch);
  }

  /// 清空续期时间戳（登出时调用）。
  Future<void> clearLastRefreshAt() async {
    await _prefs.remove(_kLastRefreshAt);
  }

  /// 匿名注册失败后的重试冷却截止时间；无记录或已过期返回 null。
  DateTime? getAnonRetryAfter() {
    final ms = _prefs.getInt(_kAnonRetryAfter);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 记录匿名注册重试冷却截止时间（注册失败后调用）。
  ///
  /// 服务端不再下发匿名 token 时，避免每次启动都反复打 anti-crawler/register
  /// 接口触发限流(400)或风控噪音（"失败静默 + 退避"思路）。
  Future<void> saveAnonRetryAfter(DateTime at) async {
    await _prefs.setInt(_kAnonRetryAfter, at.millisecondsSinceEpoch);
  }
}

/// 把 [snapshot] 应用到新构造的 [NeteaseRequestContext]。
///
/// - 若 snapshot.deviceId 非空 → 用之（解决"每次启动=新设备"风控）；否则自动 generateDeviceId；
/// - 若 snapshot.cookies 非空 → 作为初始 cookies 注入；
/// - 若 snapshot.anonToken 非空 → 同时写 ctx.anonToken 和 cookies['MUSIC_A']（和 registerAnon 行为一致）。
NeteaseRequestContext createContextFromSnapshot(
  NeteaseSessionSnapshot snapshot,
) {
  final ctx = NeteaseRequestContext(
    deviceId: snapshot.deviceId,
    cookies: snapshot.cookies.isEmpty
        ? null
        : Map<String, String>.from(snapshot.cookies),
    anonToken: snapshot.anonToken,
    musicU: snapshot.cookies['MUSIC_U'],
  );
  return ctx;
}

/// Helper：在 [NeteaseClient.request] 上层应用 SESSION_MUTATING save。
Future<void> persistIfMutating(
  NeteaseClient client,
  NeteaseSessionStorage? storage,
  String path,
  Map<String, dynamic> body,
) async {
  if (storage == null) return;
  const mutating = {
    '/api/login/qrcode/client/login',
    '/api/login/token/refresh',
    '/api/register/anonimous',
  };
  if (!mutating.contains(path)) return;
  final code = (body['code'] as int?) ?? -1;
  // QR 登录成功返回 803（不是 200），此时 set-cookie 已下发 MUSIC_U，需落盘。
  if (code != 200 && code != 803) return;
  await storage.save(client.ctx);
}
