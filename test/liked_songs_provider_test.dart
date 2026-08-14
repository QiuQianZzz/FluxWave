import 'package:flutter_test/flutter_test.dart';
import 'package:fluxwave/core/playback_stats/database_helper.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async {
    return '.';
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = MockPathProviderPlatform();
    await DatabaseHelper.initForTest();
  });

  tearDownAll(() async {
    await DatabaseHelper.resetForTest();
  });

  setUp(() async {
    final database = await DatabaseHelper.instance.database;
    await database.delete('liked_song');
  });

  Song song(int id) => Song(
    id: id,
    name: '歌$id',
    artists: const ['甲'],
    coverUrl: null,
    durationMs: 200000,
    fee: 0,
  );

  group('LikedSongsProvider', () {
    test('初始为空，load 后仍为空', () async {
      final p = LikedSongsProvider();
      await p.load();
      expect(p.loaded, true);
      expect(p.count, 0);
      expect(p.isLiked(song(1)), false);
    });

    test('toggle 收藏/取消，落盘并通知', () async {
      final p = LikedSongsProvider();
      await p.load();
      var notified = 0;
      p.addListener(() => notified++);

      expect(await p.toggle(song(1)), true);
      expect(p.count, 1);
      expect(p.isLiked(song(1)), true);
      expect(p.songs.first.name, '歌1');
      expect(notified, 1);

      expect(await p.toggle(song(1)), false);
      expect(p.count, 0);
      expect(p.isLiked(song(1)), false);
      expect(notified, 2);
    });

    test('跨音源同 id 区分', () async {
      final p = LikedSongsProvider();
      await p.load();
      final a = Song(
        source: 'netease',
        id: 9,
        name: 'A',
        artists: const ['x'],
      );
      final b = Song(
        source: 'bilibili',
        id: 9,
        name: 'B',
        artists: const ['y'],
      );
      await p.toggle(a);
      expect(p.isLiked(a), true);
      expect(p.isLiked(b), false);
      expect(p.isLikedId('netease', 9), true);
      expect(p.isLikedId('bilibili', 9), false);
    });

    test('收藏顺序：最新在前', () async {
      final p = LikedSongsProvider();
      await p.load();
      await p.toggle(song(1));
      await p.toggle(song(2));
      expect(p.songs.first.name, '歌2');
    });
  });
}
