import 'config.dart';
import 'cookie.dart';
import 'netease_client.dart';
import 'request.dart';
import 'storage/netease_session_storage.dart';
import '../../models/song.dart';

/// 高层公开接口(未登录即可用的网易云接口)。
/// 仅作端到端验证加密链路；后续登录/播放接口在此扩展。
class NeteaseApi {
  final NeteaseClient client;
  NeteaseApi(this.client);

  NeteaseSessionStorage? get storage => client.storage;

  // ---------------------------------------------------------------------------
  // 歌手相关接口
  // ---------------------------------------------------------------------------

  /// 歌手详情（api 模式；端点 `/api/artist/head/info/get`）。
  ///
  /// 返回 `{data: ArtistDetail}`，包含 cover/avatar/alias/briefDesc/musicSize/albumSize/followed。
  Future<Map<String, dynamic>> artistDetail(int id) async {
    final r = await client.request(
      '/api/artist/head/info/get',
      <String, Object>{'id': id},
      NeteaseMode.api,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 歌手动态（api 模式；端点 `/api/artist/detail/dynamic`）。
  ///
  /// 返回粉丝数等动态信息。
  Future<Map<String, dynamic>> artistDynamic(int id) async {
    final r = await client.request(
      '/api/artist/detail/dynamic',
      <String, Object>{'id': id},
      NeteaseMode.api,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 歌手歌曲列表（api 模式；端点 `/api/v1/artist/songs`）。
  ///
  /// [order]: `hot`（热度）/ `time`（发布时间）。
  /// 返回 `{songs: [...], more: bool}`。
  Future<Map<String, dynamic>> artistSongs(
    int id, {
    String order = 'hot',
    int offset = 0,
    int limit = 50,
  }) async {
    final r = await client.request(
      '/api/v1/artist/songs',
      <String, Object>{
        'id': id,
        'private_cloud': 'true',
        'work_type': '1',
        'order': order,
        'offset': offset,
        'limit': limit,
      },
      NeteaseMode.api,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 歌手专辑列表（api 模式；端点 `/api/artist/albums/{id}`）。
  ///
  /// 返回 `{hotAlbums: [...], more: bool}`。
  Future<Map<String, dynamic>> artistAlbums(
    int id, {
    int offset = 0,
    int limit = 30,
  }) async {
    final r = await client.request(
      '/api/artist/albums/$id',
      <String, Object>{
        'limit': limit,
        'offset': offset,
        'total': 'true',
      },
      NeteaseMode.api,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  // ---------------------------------------------------------------------------
  // 推荐 / 每日
  // ---------------------------------------------------------------------------

  /// 推荐歌单（weapi；端点 `/api/personalized/playlist`）。
  ///
  /// 无需登录即可调用；响应 `{code, result: [...]}`，result 项含
  /// coverImgUrl/name/id/playCount/trackCount，结构兼容 [Playlist.fromJson]。
  /// `total:true` + `n:1000`（n 为排除项，改返回整体推荐）。
  Future<Map<String, dynamic>> recommendPlaylists({int limit = 30}) async {
    final r = await client.request(
      '/api/personalized/playlist',
      <String, Object>{'limit': limit, 'total': true, 'n': 1000},
      NeteaseMode.weapi,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 每日推荐歌曲（weapi；端点 `/api/v3/discovery/recommend/songs`）。
  ///
  /// **需登录**（snapshot 校验 `MUSIC_U`）；响应 `{code, data: { dailySongs, recommendReasons }}`，
  /// `dailySongs[]` 为完整歌曲对象（ar/al/dt/fee 命名兼容 [Song.fromSearch]）。
  /// 每日 30 首，weapi 加密。
  Future<Map<String, dynamic>> dailySongs() async {
    final r = await client.request(
      '/api/v3/discovery/recommend/songs',
      <String, Object>{},
      NeteaseMode.weapi,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 搜索（eapi，响应明文 JSON，端点 `/api/cloudsearch/pc`）。
  /// 注意：若走 weapi 会在 "iOS App 指纹"会话里混入浏览器 weapi 请求，构成反爬识别特征。
  Future<Map<String, dynamic>> search(
    String keywords, {
    int limit = 20,
    int offset = 0,
    int type = 1,
  }) async {
    final r = await client.request('/api/cloudsearch/pc', <String, Object>{
      's': keywords,
      'type': type,
      'limit': limit,
      'offset': offset,
      'total': true,
    }, NeteaseMode.eapi);
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 用户歌单列表（weapi；端点 `/api/user/playlist`）。
  ///
  /// 一次拉全用 `limit=1000`，
  /// 分页走 `offset`。`includeVideo=true`。
  Future<Map<String, dynamic>> userPlaylists(
    int uid, {
    int limit = 1000,
    int offset = 0,
  }) async {
    final r = await client.request('/api/user/playlist', <String, Object>{
      'uid': uid,
      'limit': limit,
      'offset': offset,
      'includeVideo': true,
    }, NeteaseMode.weapi);
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 歌单详情（eapi；端点 `/api/v6/playlist/detail`）。
  ///
  /// `n:100000` 一次拿全 trackIds 元数据 + 前 ~1000 曲；`s:8` 为推荐相似歌单数。
  /// 缺曲由 [songDetailByIds] 分批补齐。注意响应是明文 JSON（非 useER 加密）。
  Future<Map<String, dynamic>> playlistDetail(int id, {int subs = 8}) async {
    final r = await client.request('/api/v6/playlist/detail', <String, Object>{
      'id': id,
      'n': 100000,
      's': subs,
    }, NeteaseMode.eapi);
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 按 id 批量补拉曲目详情（eapi；端点 `/api/v3/song/detail`）。
  ///
  /// `c` 构造为 `[{"id":..},{"id":..}]` 拼接串；每批 ≤500。
  /// 顺序保持传入 [ids] 的顺序，逐批拼接返回。
  Future<List<Song>> songDetailByIds(List<int> ids) async {
    final out = <Song>[];
    const batch = 500;
    for (var start = 0; start < ids.length; start += batch) {
      final end = start + batch > ids.length ? ids.length : start + batch;
      final chunk = ids.sublist(start, end);
      final body = chunk.map((e) => '{"id":$e}').join(',');
      final r = await client.request('/api/v3/song/detail', <String, Object>{
        'c': '[$body]',
      }, NeteaseMode.eapi);
      final m = (r is Map) ? Map<String, dynamic>.from(r) : {};
      final list = m['songs'];
      if (list is List) {
        for (final e in list) {
          if (e is Map) out.add(Song.fromSearch(Map<String, dynamic>.from(e)));
        }
      }
    }
    return out;
  }

  /// 获取歌曲播放地址(eapi，响应默认明文；useER=true 时服务端加密、本地 AES 解密)。
  /// 未登录时受版权/试听限制。
  Future<Map<String, dynamic>> songUrl(
    List<num> ids, {
    String level = 'standard',
    bool useER = kEncryptResponse,
  }) async {
    final r = await client.request(
      '/api/song/enhance/player/url/v1',
      <String, Object>{
        'ids': '[${ids.join(',')}]',
        'level': level,
        'encodeType': 'flac',
      },
      NeteaseMode.eapi,
      useER: useER,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 是否已登录(存在 MUSIC_U)。
  bool get isLoggedIn =>
      (client.ctx.musicU?.isNotEmpty ?? false) ||
      (client.ctx.cookies['MUSIC_U']?.isNotEmpty ?? false);

  /// 获取歌词（新版接口，eapi）。
  ///
  /// 端点：`/api/song/lyric/v1`，参数全传 0 = 返回最新版本。
  /// 响应包含：lrc/tlyric/romalrc（行级）+ yrc/ytlrc/yromalrc（逐字）。
  /// 字段提取优先级：
  /// - 主歌词：yrc > lrc
  /// - 翻译：ytlrc > tlyric
  /// - 罗马音：yromalrc > romalrc
  Future<Map<String, dynamic>> lyric(int songId) async {
    final r = await client.request('/api/song/lyric/v1', <String, Object>{
      'id': songId.toString(),
      'cp': false,
      'tv': 0,
      'lv': 0,
      'rv': 0,
      'yv': 0,
      'ytv': 0,
      'yrv': 0,
    }, NeteaseMode.eapi);
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 获取二维码登录 unikey(eapi)。成功时 body 含 `{code:200, unikey, qrimg}`。
  Future<Map<String, dynamic>> loginQrKey() async {
    final r = await client.request('/api/login/qrcode/unikey', <String, Object>{
      'type': 3,
    }, NeteaseMode.eapi);
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 由 unikey 生成扫码 URL(本地拼装)。
  String loginQrUrl(String key) => 'https://music.163.com/login?codekey=$key';

  /// 轮询二维码状态(eapi)。
  /// code: 800 已过期 / 801 等待扫码 / 802 待确认 / 803 已确认。
  /// 成功(803)时消费响应 Set-Cookie 中的 MUSIC_U 写入 [client.ctx]。
  Future<Map<String, dynamic>> loginQrCheck(String key) async {
    final r = await client.request(
      '/api/login/qrcode/client/login',
      <String, Object>{'key': key, 'type': 3},
      NeteaseMode.eapi,
    );
    final Map<String, dynamic> m = (r is Map)
        ? Map<String, dynamic>.from(r)
        : <String, dynamic>{};
    // 优先使用已通过 set-cookie 合并进 ctx.cookies 的 MUSIC_U；
    // 若服务端把登录凭证塞在 body.cookie（形如 'k1=v1; k2=v2' 拼接串）中，
    // 则用 cookieToJson 解析后再取 MUSIC_U 子字段，避免整串污染 token。
    final mu =
        client.ctx.cookies['MUSIC_U'] ??
        (m['cookie'] != null
            ? cookieToJson(m['cookie']!.toString())['MUSIC_U']
            : null);
    if (m['code'] == 803 && mu != null && mu.isNotEmpty) {
      client.ctx.musicU = mu;
    }
    return m;
  }

  /// 登录状态(当前账号信息，weapi)。
  Future<Map<String, dynamic>> loginStatus() async {
    final r = await client.request(
      '/api/w/nuser/account/get',
      const <String, Object>{},
      NeteaseMode.weapi,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 校验登录态并返回用户 profile（含 userId），未登录返回 null。
  ///
  /// userId 取法三层兜底：
  /// `profile.userId ?? data.account.id ?? account.id`，三者皆空视为未登录
  /// （即便 code=200 且 profile 非空，游客/匿名/半登录态也会缺 userId）。
  Future<Map<String, dynamic>?> profile() async {
    final m = await loginStatus();
    if ((m['code'] as int?) != 200) return null;
    final raw =
        m['profile'] ??
        (m['data'] is Map ? (m['data'] as Map)['profile'] : null);
    if (raw is! Map || raw.isEmpty) return null;

    Object? accountId(String keyInData, String keyInRoot) {
      Object? fromData;
      if (m['data'] is Map) {
        final data = m['data'] as Map;
        if (data[keyInData] is Map) {
          fromData = (data[keyInData] as Map)[keyInRoot];
        }
      }
      if (fromData != null) return fromData;
      if (m[keyInData] is Map) {
        return (m[keyInData] as Map)[keyInRoot];
      }
      return null;
    }

    final userId = (raw['userId'] ?? accountId('account', 'id'))?.toString();
    if (userId == null || userId.isEmpty) return null;

    final merged = Map<String, dynamic>.from(raw);
    merged['userId'] = userId;
    return merged;
  }

  /// 刷新登录态(延长 MUSIC_U 有效期，eapi)。
  Future<Map<String, dynamic>> loginRefresh() async {
    final r = await client.request(
      '/api/login/token/refresh',
      const <String, Object>{},
      NeteaseMode.eapi,
    );
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 服务端登出(仅打断服务端 session，随后会调用 [reset] 全量清理本地会话)。
  ///
  /// 不传 crypto，走 createRequest 默认 eapi（非 weapi）。
  Future<Map<String, dynamic>> logout() async {
    final r = await client.request(
      '/api/logout',
      const <String, Object>{},
      NeteaseMode.eapi,
    );
    if ((r is Map) && (r['code'] as int?) == 200) {
      await reset();
    }
    return (r is Map) ? Map<String, dynamic>.from(r) : {};
  }

  /// 全量重置本地会话：
  /// - 清空 cookies；
  /// - 置空 musicU / anonToken / realIp；
  /// - 若注入 [storage]，同步清空 SP 持久化。
  ///
  /// ⚠️ **不重新生成 deviceId**（deviceId 是独立于会话的持久设备指纹）。
  /// 若业务层确需换设备指纹，可再显式调用 `client.ctx.deviceId = regenerateDeviceId()`。
  /// 注意：`registerAnon` 同样复用现有 deviceId（实测同 deviceId 二次注册幂等，详见 netease_client）。
  Future<void> reset() async {
    client.ctx.cookies.clear();
    client.ctx.musicU = null;
    client.ctx.anonToken = null;
    client.ctx.realIp = null;
    final s = storage;
    if (s != null) await s.clear();
  }
}
