import 'dart:async';

import '../../models/song.dart';
import '../player/song_url.dart';
import 'cache_store.dart';
import 'proxy_server.dart';

/// 音频缓存门面：启动/关闭 + 把「要播的 URL」改写成代理地址。
///
/// 规则：
/// - 仅**非试听**（完整授权）的歌曲走代理缓存；
/// - 试听片段/无可缓存条件 → 原样播 CDN，不进缓存；
/// - 代理/store 未就绪 → 原样播 CDN（优雅降级）。
class AudioCache {
  AudioCache._();

  static bool _initAttempted = false;

  /// 初始化缓存 store + 代理。幂等；失败静默（播放仍走 CDN）。
  static Future<void> init() async {
    if (_initAttempted) return;
    _initAttempted = true;
    await AudioCacheStore.init();
    await AudioCacheProxy.start();
  }

  /// 测试用：指定目录初始化。
  static Future<void> initForTest(String directory) async {
    AudioCacheStore.configureForTest(directory);
    await AudioCacheProxy.start();
  }

  /// 复位（测试 tearDown）。
  static Future<void> resetForTest() async {
    await AudioCacheProxy.stop();
    AudioCacheStore.resetForTest();
    _initAttempted = false;
  }

  /// 缓存可用（store 已初始化 + 代理已启动）。
  static bool get ready =>
      AudioCacheStore.instance.enabled && AudioCacheProxy.instance.port != null;

  /// 生成整曲的缓存键（缺省音质/编码用占位，保持一致）。
  static String keyFor(Song song, SongUrlResult result) =>
      AudioCacheStore.keyFor(
        song.source,
        song.id,
        result.level ?? 'std',
        result.type ?? 'mp3',
      );

  /// 把播放地址路由给 just_audio：可缓存 → 代理地址并登记 CDN 直链；
  /// 否则返回原 CDN URL。
  static Future<String> routeUrl(Song song, SongUrlResult result) async {
    if (result.isTrial || !ready) return result.url;
    final key = keyFor(song, result);
    AudioCacheStore.instance.remember(key, result.url);
    // 登记码率到缓存元数据：缓存字节本身不携带码率，只有在线解析期才有，
    // 离线命中时音质栏要靠它显示 kbps（br 未知时 setBr 本身 no-op）。
    // 后台登记不阻塞播放启动：setBr 已经 _writeChain 串行化，此处不必等待；
    // 它同步入队、先于同 key 后续代理写入，顺序保证不因不 await 而丢失。
    unawaited(AudioCacheStore.instance.setBr(key, result.br));
    return AudioCacheProxy.instance.urlFor(key);
  }

  /// 精确离线命中：仅当该歌**档位恰为 [level]**（如当前 qualityLevel）存在
  /// **完整缓存**时，返回可直接播的代理地址（完全离线、无需 CDN 直链/网络
  /// 解析）及缓存 key 解析出的实际档位/编码；任一不满足返回 null。
  ///
  /// 只匹配「档位精确一致」的完整 key（`<source>_<songId>_<level>_`），不在此
  /// 降档——降到其它档按设计交给**在线解析**处理，解析全链失败再由
  /// [bestUrlFor] 兜最高档，见 PlayerProvider._loadCurrentInternal。
  static ({String url, String? level, String? type, int br})? exactUrlFor(
    Song song, {
    required String? level,
  }) {
    if (!ready || level == null) return null;
    final prefix = AudioCacheStore.keyFor(song.source, song.id, level, '');
    for (final key in AudioCacheStore.instance.keys) {
      if (key.startsWith(prefix) && AudioCacheStore.instance.isComplete(key)) {
        return _resolvedHit(key);
      }
    }
    return null;
  }

  /// 离线兜底：取该歌**任意完整缓存中档位最高**的一档，返回代理地址/实际档位
  /// 编码；无任何完整缓存返回 null，或无法播时由调用方继续走跳过流程。
  ///
  /// [rank] 为音质档由低到高的顺序（如 SettingsProvider.qualityOptions），
  /// 下标越大档位越高。不在白名单的档位视为「未知档」（下标 -1）：仅当**没有任何
  /// 可识别档**（即唯一完整缓存就是未知档）时才被选中兜底，其余情况优先可识别档。
  /// 供在线解析全链失败后的保底（网没时也能把最高缓存播出来，避免卡死/误跳过）。
  static ({String url, String? level, String? type, int br})? bestUrlFor(
    Song song, {
    required List<String> rank,
  }) {
    if (!ready) return null;
    final prefix = AudioCacheStore.prefixFor(song.source, song.id);
    String? bestKey;
    var bestIdx = -1;
    for (final key in AudioCacheStore.instance.keys) {
      if (!key.startsWith(prefix) ||
          !AudioCacheStore.instance.isComplete(key)) {
        continue;
      }
      final idx = _rankOf(key, rank);
      if (bestKey == null || idx > bestIdx) {
        bestIdx = idx;
        bestKey = key;
      }
    }
    return bestKey == null ? null : _resolvedHit(bestKey);
  }

  /// key 的档位（以 `_` 分隔的第 3 段）在 [rank] 中的下标；不在白名单返回 -1。
  /// key 形如 `<source>_<songId>_<level>_<type>`。
  static int _rankOf(String key, List<String> rank) {
    final seg = key.split('_');
    return seg.length < 3 ? -1 : rank.indexOf(seg[2]);
  }

  /// 由缓存 key（`<source>_<songId>_<level>_<type>`，source/level/type 均已
  /// sanitize 为字母数字）解析出代理地址与实际档位/编码。解析失败返回 null 段，
  /// UI 不显示。 [br] 取条目登记的码率（在线解析期写入；0 = 未知，UI 不显示 kbps）。
  static ({String url, String? level, String? type, int br}) _resolvedHit(
    String key,
  ) {
    final seg = key.split('_');
    return (
      url: AudioCacheProxy.instance.urlFor(key),
      level: seg.length > 2 ? seg[2] : null,
      type: seg.length > 3 ? seg[3] : null,
      br: AudioCacheStore.instance.entry(key)?.br ?? 0,
    );
  }
}
