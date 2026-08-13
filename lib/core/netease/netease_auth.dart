import 'netease_api.dart';
import 'netease_client.dart';

/// 二维码登录状态码（800/801/802/803）。
class QrCheckResult {
  /// 800=已过期 / 801=等待扫码 / 802=待确认 / 803=已确认。
  final int code;
  final String? nickname;
  final String? avatarUrl;

  /// 803 成功时写入的 MUSIC_U(会话已持久化在 [client.ctx]，此字段便于业务读走)。
  final String? musicU;

  /// 本次请求合并后的完整 cookie 快照（业务层要整串落库/跨端同步时使用）。
  final Map<String, String>? cookies;

  const QrCheckResult({
    required this.code,
    this.nickname,
    this.avatarUrl,
    this.musicU,
    this.cookies,
  });

  bool get isExpired => code == 800;
  bool get isWaitingScan => code == 801;
  bool get isWaitingConfirm => code == 802;
  bool get isSuccess => code == 803;

  bool get _hasNick => nickname != null && nickname!.isNotEmpty;
  String? get _musicUPreview => musicU == null || musicU!.isEmpty
      ? null
      : (musicU!.length <= 8
            ? '***'
            : '${musicU!.substring(0, 4)}...${musicU!.substring(musicU!.length - 4)}'
                  '(${musicU!.length})');

  @override
  String toString() =>
      'QrCheckResult(code=$code, nickname=$nickname, avatar=$avatarUrl'
      ', musicU=$_musicUPreview, cookieKeys=${cookies?.keys.toList()}'
      '${_hasNick ? ', hasNick=true' : ''})';
}

/// 二维码登录**服务层**：薄封装，非阻塞。
///
/// 仅提供单次交互；**轮询由调用方自行用 Timer 驱动**：
/// 主进程只给原语，renderer `useIntervalFn` 控制节奏与生命周期。
class NeteaseQrLogin {
  final NeteaseApi api;
  NeteaseQrLogin(this.api);

  bool get isLoggedIn => api.isLoggedIn;

  /// 获取一个新的二维码 unikey（并拼好扫码 URL）。
  ///
  /// 异常分类：
  /// - code != 200 → `NeteaseException.non200`（含服务端 msg 字段）；
  /// - code = 200 但 unikey 为空 → 独立异常（提示接口格式漂移）；
  /// - 网络层异常 → 直接 rethrow（由 [NeteaseClient] 以 `NeteaseException.network` 抛出）。
  Future<String> newKey() async {
    const path = '/api/login/qrcode/unikey';
    final r = await api.loginQrKey();
    final c = (r['code'] as int?) ?? -1;
    if (c != 200) {
      throw NeteaseException.non200(
        c,
        message: '获取二维码 unikey 失败：服务端返回非 200',
        requestPath: path,
        rawBody: r,
      );
    }
    final k = r['unikey'] as String?;
    if (k == null || k.isEmpty) {
      throw NeteaseException(
        '获取二维码 unikey 失败：服务端 code=200 但 unikey 缺失（接口格式可能变更）',
        code: c,
        requestPath: path,
      );
    }
    return k;
  }

  /// 扫码 URL（渲�成二维码）。
  String qrUrl(String key) => api.loginQrUrl(key);

  /// 单次查询扫码状态；成功(803)时 `MUSIC_U` 已由 [NeteaseApi.loginQrCheck] 写回会话。
  Future<QrCheckResult> check(String key) async {
    final m = await api.loginQrCheck(key);
    final code = (m['code'] is int) ? m['code'] as int : 801;
    return QrCheckResult(
      code: code,
      nickname: m['nickname']?.toString(),
      avatarUrl: m['avatarUrl']?.toString(),
      musicU: api.client.ctx.musicU,
      cookies: Map<String, String>.unmodifiable(api.client.ctx.cookies),
    );
  }

  /// 校验登录态；已登录返回 profile（含 userId），否则返回 null。
  ///
  /// 代理 [NeteaseApi.profile]，解析逻辑统一收口在 API 层（
  /// fetchLoginStatus 三层兜底：`profile.userId ?? data.account.id ?? account.id`，
  /// 三者皆空视为未登录）。
  Future<Map<String, dynamic>?> profile() => api.profile();

  /// 续期登录态。
  Future<void> refresh() async {
    await api.loginRefresh();
  }

  /// 登出：通知服务端失效会话，并清理本地 ctx 的登录凭证(MUSIC_U / MUSIC_A / __csrf)。
  Future<void> logout() async {
    await api.logout();
  }

  /// 全量重置本地会话（不调用服务端）：
  /// 清空 cookies / musicU / anonToken / realIp；若注入 storage 则同步清空 SP。
  /// ⚠️ 不重新生成 deviceId（deviceId 是持久设备指纹）。
  ///
  /// 用于「服务端 logout 失败仍想清本地」「强制切换账号」等场景。
  Future<void> reset() async {
    await api.reset();
  }
}
