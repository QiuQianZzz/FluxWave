import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/playback_stats/database_helper.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// 模拟 path_provider 平台（测试环境无需真实路径）
class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async {
    return '.';
  }
}

void main() {
  late DatabaseHelper db;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = MockPathProviderPlatform();
    DatabaseHelper.init();
  });

  setUp(() async {
    db = DatabaseHelper.instance;
    final database = await db.database;
    await database.delete('liked_song');
  });

  group('DatabaseHelper.liked_song', () {
    test('收藏一首歌后 isLiked 为 true，数量为 1', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: '1001',
        name: '歌曲甲',
        artist: '歌手甲',
        durationMs: 180000,
        fee: 0,
        likedAtMs: 1000,
      );
      expect(await db.isLikedSong(source: 'netease', sourceId: '1001'), true);
      expect(await db.isLikedSong(source: 'netease', sourceId: '9999'), false);
      expect(await db.countLikedSongs(), 1);
    });

    test('重复收藏同一首不产生重复行（UPSERT）', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: '1001',
        name: '歌曲甲',
        durationMs: 180000,
        fee: 0,
        likedAtMs: 1000,
      );
      await db.addLikedSong(
        source: 'netease',
        sourceId: '1001',
        name: '歌曲甲(改名)',
        durationMs: 180000,
        fee: 0,
        likedAtMs: 2000,
      );
      expect(await db.countLikedSongs(), 1);
      final all = await db.getLikedSongs();
      expect(all.length, 1);
      expect(all.first.name, '歌曲甲(改名)');
      expect(all.first.likedAt, 2000);
    });

    test('跨音源同 id 互不干扰', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: '42',
        name: 'A',
        durationMs: 100,
        fee: 0,
      );
      await db.addLikedSong(
        source: 'bilibili',
        sourceId: '42',
        name: 'B',
        durationMs: 100,
        fee: 0,
      );
      expect(await db.countLikedSongs(), 2);
      expect(
        await db.isLikedSong(source: 'netease', sourceId: '42'),
        true,
      );
      expect(
        await db.isLikedSong(source: 'bilibili', sourceId: '42'),
        true,
      );
      await db.removeLikedSong(source: 'netease', sourceId: '42');
      expect(
        await db.isLikedSong(source: 'netease', sourceId: '42'),
        false,
      );
      expect(
        await db.isLikedSong(source: 'bilibili', sourceId: '42'),
        true,
      );
    });

    test('排序：按收藏时间倒序（最新在前）', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: '1',
        name: '歌1',
        durationMs: 100,
        fee: 0,
        likedAtMs: 100,
      );
      await db.addLikedSong(
        source: 'netease',
        sourceId: '2',
        name: '歌2',
        durationMs: 100,
        fee: 0,
        likedAtMs: 300,
      );
      await db.addLikedSong(
        source: 'netease',
        sourceId: '3',
        name: '歌3',
        durationMs: 100,
        fee: 0,
        likedAtMs: 200,
      );
      final all = await db.getLikedSongs();
      expect(all.map((s) => s.sourceId).toList(), ['2', '3', '1']);
    });

    test('整曲快照字段还原可播放 Song', () async {
      await db.addLikedSong(
        source: 'netease',
        sourceId: '77',
        name: '夜曲',
        artist: '周杰伦',
        album: '十一月的萧邦',
        coverUrl: 'https://example.com/c.jpg',
        durationMs: 228000,
        fee: 0,
        likedAtMs: 100,
      );
      final all = await db.getLikedSongs();
      final song = all.first.toSong();
      expect(song.id, 77);
      expect(song.name, '夜曲');
      expect(song.artistsLabel, '周杰伦');
      expect(song.albumName, '十一月的萧邦');
      expect(song.coverUrl, 'https://example.com/c.jpg');
      expect(song.durationMs, 228000);
      expect(song.fee, 0);
    });
  });
}
