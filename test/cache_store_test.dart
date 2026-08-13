import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/audio_cache/cache_store.dart';
import 'package:fluxwave/models/song.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cache_store_test');
    AudioCacheStore.configureForTest(tempDir.path);
  });

  tearDown(() async {
    await AudioCacheStore.instance.flush();
    AudioCacheStore.resetForTest();
    for (var i = 0; i < 5 && tempDir.existsSync(); i++) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test('keyFor 组装 key（带音源命名空间）', () {
    expect(
      AudioCacheStore.keyFor(SongSource.netease, 123, 'exhigh', 'mp3'),
      'netease_123_exhigh_mp3',
    );
    expect(
      AudioCacheStore.keyFor(SongSource.netease, 1, '标准音质', 'mp3'),
      'netease_1______mp3',
    );
  });

  test('setBr：登记码率到条目，0 不写入不造空条目', () async {
    const key = 'br-key';
    // 未登记时默认 0。
    expect(AudioCacheStore.instance.entry(key), isNull);

    await AudioCacheStore.instance.setBr(key, 0);
    expect(
      AudioCacheStore.instance.entry(key),
      isNull,
      reason: '未知码率（br=0）不应为不存在的 key 造空条目',
    );

    await AudioCacheStore.instance.setBr(key, 320000);
    expect(AudioCacheStore.instance.entry(key)!.br, 320000);

    // 覆盖：同一 key 新码率直接替换。
    await AudioCacheStore.instance.setBr(key, 128000);
    expect(AudioCacheStore.instance.entry(key)!.br, 128000);
  });

  test('br 持久化：flush + 重启重载后仍在', () async {
    const key = 'br-persist';
    await AudioCacheStore.instance.setBr(key, 886676);
    await AudioCacheStore.instance.flush();

    AudioCacheStore.resetForTest();
    AudioCacheStore.configureForTest(tempDir.path);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(AudioCacheStore.instance.entry(key)!.br, 886676);
  });

  test('br 与写盘数据共存：同 key 写字节后码率不被覆盖', () async {
    const key = 'br-with-data';
    await AudioCacheStore.instance.setBr(key, 256000);
    await AudioCacheStore.instance.write(key, 0, List.filled(64, 9));
    expect(AudioCacheStore.instance.entry(key)!.br, 256000);
    expect(AudioCacheStore.instance.entry(key)!.sizeBytes, 64);
  });

  test('write 后可按区间读取，未写区间返回 null', () async {
    final key = AudioCacheStore.keyFor(SongSource.netease, 9, 'std', 'mp3');
    await AudioCacheStore.instance.write(key, 0, List.filled(100, 1));
    await AudioCacheStore.instance.write(key, 200, List.filled(100, 2));

    final a = await AudioCacheStore.instance.read(key, 10, 60);
    expect(a, isNotNull);
    expect(a!.first, 1);
    expect(a.length, 50);

    final b = await AudioCacheStore.instance.read(key, 230, 280);
    expect(b, isNotNull);
    expect(b!.first, 2);
    expect(b.length, 50);

    // 跨已写区间但中间 100..200 缺失 → 未全部命中返回 null。
    expect(await AudioCacheStore.instance.read(key, 50, 150), isNull);
  });

  test('相邻区间合并，偏移正确', () async {
    final key = 'k';
    await AudioCacheStore.instance.write(key, 0, List.filled(10, 1));
    await AudioCacheStore.instance.write(key, 10, List.filled(10, 2));
    final e = AudioCacheStore.instance.entry(key)!;
    expect(e.ranges.length, 1);
    expect(e.ranges.first.start, 0);
    expect(e.ranges.first.end, 20);
    expect(e.sizeBytes, 20);
  });

  test('持久化：重启后索引仍能离线读', () async {
    final key = 'persist';
    await AudioCacheStore.instance.write(key, 0, List.filled(64, 7));
    await AudioCacheStore.instance.flush();

    // 模拟重启：复位后用同一目录重新加载索引。
    AudioCacheStore.resetForTest();
    AudioCacheStore.configureForTest(tempDir.path);
    // configureForTest 不 await 加载，手动触发一次（保证毫秒后读到）。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(AudioCacheStore.instance.entry(key), isNotNull);
    final data = await AudioCacheStore.instance.read(key, 0, 64);
    expect(data, isNotNull);
    expect(data!.every((b) => b == 7), isTrue);
  });

  test('写入后节流自动落盘：不显式 flush 也能持久化（GAP-3）', () async {
    final key = 'auto-persist';
    await AudioCacheStore.instance.write(key, 0, List.filled(32, 3));
    // 不调用 flush()：等待节流 Timer（800ms）触发自动落盘。
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    AudioCacheStore.resetForTest();
    AudioCacheStore.configureForTest(tempDir.path);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(AudioCacheStore.instance.entry(key), isNotNull);
    expect(AudioCacheStore.instance.isCached(key, 0, 32), isTrue);
  });

  test('isComplete：完整缓存判定', () async {
    const key = 'complete';
    AudioCacheStore.instance.setTotalSize(key, 100);
    await AudioCacheStore.instance.write(key, 0, List.filled(100, 1));
    expect(AudioCacheStore.instance.isComplete(key), isTrue);

    // 留空洞 → 不完整。
    const key2 = 'gap';
    AudioCacheStore.instance.setTotalSize(key2, 200);
    await AudioCacheStore.instance.write(key2, 0, List.filled(100, 1));
    expect(AudioCacheStore.instance.isComplete(key2), isFalse);

    // 未知 totalSize → 不完整。
    const key3 = 'no-total';
    await AudioCacheStore.instance.write(key3, 0, List.filled(100, 1));
    expect(AudioCacheStore.instance.isComplete(key3), isFalse);
  });

  test('多曲写入各占独立条目、总量累计，lastAccess 被刷新', () async {
    await AudioCacheStore.instance.write('k1', 0, List.filled(60, 1));
    await AudioCacheStore.instance.write('k2', 0, List.filled(40, 1));
    expect(AudioCacheStore.instance.entryCount, 2);
    expect(AudioCacheStore.instance.totalBytes, 100);
    expect(AudioCacheStore.instance.entry('k1')!.lastAccess, greaterThan(0));
    expect(AudioCacheStore.defaultMaxBytes, 3 * 1024 * 1024 * 1024);
    expect(AudioCacheStore.instance.maxBytes, AudioCacheStore.defaultMaxBytes);
  });

  test('LRU 真实驱逐：超限后删除最久未访问的整首，新歌保留', () async {
    // 用 overrideMaxBytes 触发真实驱逐（默认 3GB 单测无法触达）。
    AudioCacheStore.instance.overrideMaxBytes = 150;

    // 三首歌各 60 字节，总量 180 > 上限 150。
    await AudioCacheStore.instance.write('a', 0, List.filled(60, 1));
    await AudioCacheStore.instance.write('b', 0, List.filled(60, 2));
    await AudioCacheStore.instance.write('c', 0, List.filled(60, 3));

    // 驱逐后剩两首，最旧 'a' 被移除。
    expect(AudioCacheStore.instance.entryCount, 2);
    expect(AudioCacheStore.instance.entry('a'), isNull);
    expect(AudioCacheStore.instance.entry('b'), isNotNull);
    expect(AudioCacheStore.instance.entry('c'), isNotNull);

    // 持续写入仍受上限约束。
    await AudioCacheStore.instance.write('d', 0, List.filled(60, 4));
    expect(AudioCacheStore.instance.entryCount, 2);
  });

  test('LRU 保守保护：只剩一首也不删（避免清空正在播的歌）', () async {
    AudioCacheStore.instance.overrideMaxBytes = 50;
    await AudioCacheStore.instance.write('solo', 0, List.filled(200, 1));
    // 超限但只有 1 首：按设计不驱逐（保留正在播的）。
    expect(AudioCacheStore.instance.entryCount, 1);
    expect(AudioCacheStore.instance.entry('solo'), isNotNull);
  });

  test('setMaxBytes：改小立即按新上限驱逐，改大仅放宽', () async {
    // 三首歌各 60 字节（180B），当前默认上限下不会驱逐。
    await AudioCacheStore.instance.write('a', 0, List.filled(60, 1));
    await AudioCacheStore.instance.write('b', 0, List.filled(60, 2));
    await AudioCacheStore.instance.write('c', 0, List.filled(60, 3));
    expect(AudioCacheStore.instance.entryCount, 3);

    // 改小到 120B → 立即驱逐到放下限（剩 2 首，最旧 'a' 被删）。
    AudioCacheStore.instance.setMaxBytes(120);
    expect(AudioCacheStore.instance.maxBytes, 120);
    expect(AudioCacheStore.instance.entryCount, 2);
    expect(AudioCacheStore.instance.entry('a'), isNull);

    // 改大到 1000B → 仅放宽，不再额外驱逐。
    AudioCacheStore.instance.setMaxBytes(1000);
    expect(AudioCacheStore.instance.entryCount, 2);
  });

  test('clearAll：清空条目/总量/歌曲数，保留会话直链', () async {
    AudioCacheStore.instance.remember('x1', 'http://cdn/x1.mp3');
    await AudioCacheStore.instance.write('x1', 0, List.filled(64, 1));
    await AudioCacheStore.instance.write('x2', 0, List.filled(32, 2));
    expect(AudioCacheStore.instance.totalBytes, 96);
    expect(AudioCacheStore.instance.sessionUrl('x1'), isNotNull);

    await AudioCacheStore.instance.clearAll();

    expect(AudioCacheStore.instance.entryCount, 0);
    expect(AudioCacheStore.instance.totalBytes, 0);
    expect(AudioCacheStore.instance.songCount, 0);
    // 磁盘清理不影响会话直链：播放中/之后 miss 仍能凭直链回源重缓存。
    expect(AudioCacheStore.instance.sessionUrl('x1'), isNotNull);
  });

  test('LRU 驱逐保留会话直链，避免被清的歌续读 404', () async {
    AudioCacheStore.instance.overrideMaxBytes = 150;
    // 驱逐前先登记直链：被驱逐后直链应仍保留。
    AudioCacheStore.instance.remember('a', 'http://cdn/a.mp3');
    await AudioCacheStore.instance.write('a', 0, List.filled(60, 1));
    await AudioCacheStore.instance.write('b', 0, List.filled(60, 2));
    await AudioCacheStore.instance.write('c', 0, List.filled(60, 3));
    expect(AudioCacheStore.instance.entry('a'), isNull, reason: 'a 应被 LRU 驱逐');

    // 驱逐只删磁盘字节，sessionUrl 仍保留（a 在驱逐前已登记）。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(AudioCacheStore.instance.sessionUrl('a'), isNotNull);
  });

  test('songCount：按「音源 + songId」去重，同歌多档只算 1 首', () async {
    // 同源同歌多档 → 算 1；同 id 不同源 → 各算 1。
    await AudioCacheStore.instance.write(
      'netease_9_std_mp3',
      0,
      List.filled(10, 1),
    );
    await AudioCacheStore.instance.write(
      'netease_9_exhigh_flac',
      0,
      List.filled(10, 2),
    );
    await AudioCacheStore.instance.write(
      'kugou_9_std_mp3',
      0,
      List.filled(10, 3),
    );
    await AudioCacheStore.instance.write(
      'netease_42_std_mp3',
      0,
      List.filled(10, 4),
    );

    expect(AudioCacheStore.instance.entryCount, 4);
    expect(AudioCacheStore.instance.songCount, 3);
  });

  test('会话直链上限：超出后淘汰最旧，重登记不丢当前歌', () async {
    final cap = AudioCacheStore.maxSessionUrls;
    final total = cap + 64;
    for (var i = 0; i < total; i++) {
      AudioCacheStore.instance.remember('k$i', 'url$i');
    }
    // 数量被硬约束在上限内。
    expect(AudioCacheStore.instance.sessionUrlCount, cap);
    // 最早登记的已被淘汰，最近登记的仍在。
    expect(AudioCacheStore.instance.sessionUrl('k0'), isNull);
    expect(
      AudioCacheStore.instance.sessionUrl('k${total - 1}'),
      'url${total - 1}',
    );

    // 重登记一个已被淘汰的 key：重新落尾并抢占一个最旧，不会被立即再扔。
    AudioCacheStore.instance.remember('k0', 'url0-new');
    expect(AudioCacheStore.instance.sessionUrlCount, cap);
    expect(AudioCacheStore.instance.sessionUrl('k0'), 'url0-new');
    expect(AudioCacheStore.instance.sessionUrl('k1'), isNull);
  });
}
