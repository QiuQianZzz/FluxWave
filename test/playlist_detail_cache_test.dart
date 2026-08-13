import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/playlist_detail_cache.dart';
import 'package:fluxwave/models/playlist.dart';
import 'package:fluxwave/models/song.dart';

Playlist _playlist(int id, String name) => Playlist(
  id: id,
  name: name,
  coverUrl: 'https://p.music.163.com/cover/$id',
  trackCount: 3,
);

List<Song> _tracks(int playlistId) => [
  Song(id: playlistId * 10 + 1, name: '歌1', artists: ['A']),
  Song(id: playlistId * 10 + 2, name: '歌2', artists: ['B']),
  Song(id: playlistId * 10 + 3, name: '歌3'),
];

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('playlist_detail_cache_test');
  });

  tearDown(() async {
    for (var i = 0; i < 5 && tempDir.existsSync(); i++) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test('写读回环：meta 与 tracks 完整还原', () async {
    final cache = PlaylistDetailCache(directory: tempDir);
    await cache.write(42, _playlist(42, '我的歌单'), _tracks(42));

    final snap = await cache.read(42);
    expect(snap, isNotNull);
    expect(snap!.meta.id, 42);
    expect(snap.meta.name, '我的歌单');
    expect(snap.meta.coverUrl, 'https://p.music.163.com/cover/42');
    expect(snap.tracks, hasLength(3));
    expect(snap.tracks.first.id, 421);
    expect(snap.tracks.first.name, '歌1');
  });

  test('未写入的歌单返回 null，不抛错', () async {
    final cache = PlaylistDetailCache(directory: tempDir);
    expect(await cache.read(999), isNull);
  });

  test('同 id 重复写覆盖旧缓存（读回最新）', () async {
    final cache = PlaylistDetailCache(directory: tempDir);
    await cache.write(7, _playlist(7, '旧名'), _tracks(7));
    await cache.write(7, _playlist(7, '新名'), [
      ..._tracks(7),
      Song(id: 9, name: '新增'),
    ]);

    final snap = await cache.read(7);
    expect(snap!.meta.name, '新名');
    expect(snap.tracks, hasLength(4));
    expect(await cache.count(), 1, reason: '同 id 覆盖不应增加文件数');
  });

  test('跨音源同 id 隔离：source 取自 meta.source，读取按源分流', () async {
    final cache = PlaylistDetailCache(directory: tempDir);
    final kugou = Playlist(id: 42, name: '酷狗歌单', source: 'kugou');
    await cache.write(42, _playlist(42, '网易云歌单'), _tracks(42));
    await cache.write(42, kugou, _tracks(42));

    expect(await cache.count(), 2, reason: '跨源同 id 应各自落盘');
    expect((await cache.read(42))?.meta.name, '网易云歌单');
    expect((await cache.read(42, source: 'kugou'))?.meta.name, '酷狗歌单');
  });

  test('损坏 JSON：读回 null，不抛到调用方', () async {
    final cache = PlaylistDetailCache(directory: tempDir);
    // 直接写一个非法 JSON 文件
    File(
      '${tempDir.path}${Platform.pathSeparator}playlist_5.json',
    ).writeAsStringSync('{破损');
    expect(await cache.read(5), isNull);
  });

  test('LRU：超过 maxFiles 时驱逐最旧的歌单文件', () async {
    final cache = PlaylistDetailCache(directory: tempDir);
    final total = PlaylistDetailCache.maxFiles + 2;
    for (var i = 1; i <= total; i++) {
      await cache.write(i, _playlist(i, '歌单$i'), _tracks(i));
    }

    // 不变量 1：总数被裁剪到上限
    expect(
      await cache.count(),
      PlaylistDetailCache.maxFiles,
      reason: '超出上限应驱逐到 maxFiles 张',
    );

    // 不变量 2：最新的几张一定在（最后写入的 maxFiles 张）
    for (var i = total - PlaylistDetailCache.maxFiles + 1; i <= total; i++) {
      expect(await cache.read(i), isNotNull, reason: '较新的歌单 $i 应保留');
    }

    // 不变量 3：最旧的两张一定被驱逐（LinkedHashMap 插入序，确定性驱逐）
    expect(await cache.read(1), isNull, reason: '最旧的歌单 1 应被驱逐');
    expect(await cache.read(2), isNull, reason: '次旧的歌单 2 应被驱逐');
  });
}
