import 'dart:convert';
import 'dart:io';

import 'package:fluxwave/core/player/playback_migration.dart';
import 'package:fluxwave/core/player/playback_storage.dart';
import 'package:fluxwave/models/artist.dart';
import 'package:fluxwave/models/song.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `PlayerPlaybackStorage` 快照往返 + 历史迁移测试（纯本地，不联网）。
void main() {
  Song song(int id) => Song(
    id: id,
    name: 's$id',
    coverUrl: 'http://p1.music.126.net/$id.jpg',
    artists: const [ArtistSummary(id: 0, name: 'artist')],
    albumName: 'album',
    durationMs: 210000,
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('playback_storage_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<PlayerPlaybackStorage> makeStorage() =>
      PlayerPlaybackStorage.init(directory: tempDir);

  test('save → load 往返完整（队列/索引/进度/播放状态）', () async {
    final storage = await makeStorage();

    await storage.save(
      PlaybackSnapshot(
        queue: [song(1), song(2)],
        currentIndex: 1,
        positionMs: 45200,
        playing: true,
      ),
    );

    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.queue.map((s) => s.id), [1, 2]);
    expect(snap.queue[0].name, 's1');
    expect(snap.queue[1].coverUrl, 'http://p1.music.126.net/2.jpg');
    expect(snap.currentIndex, 1);
    expect(snap.positionMs, 45200);
    expect(snap.playing, isTrue);
  });

  test('无缓存时 load 返回 null', () async {
    final storage = await makeStorage();
    expect(await storage.load(), isNull);
  });

  test('损坏队列 JSON 时 load 返回 null，并删除坏文件', () async {
    final storage = await makeStorage();
    await File('${tempDir.path}/playback_queue.json').writeAsString('{oops');
    expect(await storage.load(), isNull);
    expect(
      await File('${tempDir.path}/playback_queue.json').exists(),
      isFalse,
      reason: '坏文件应被清除，避免每次启动重复解析',
    );
  });

  test('shuffleOrder 随队列往返保存', () async {
    final storage = await makeStorage();
    await storage.saveQueue(
      [song(1), song(2), song(3)],
      1,
      shuffleOrder: const [1, 2, 0],
    );
    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.shuffleOrder, [1, 2, 0]);
  });

  test('快照 save 往返携带 shuffleOrder', () async {
    final storage = await makeStorage();
    await storage.save(
      PlaybackSnapshot(
        queue: [song(1), song(2)],
        currentIndex: 0,
        positionMs: 100,
        playing: false,
        shuffleMode: true,
        shuffleOrder: const [0, 1],
      ),
    );
    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.shuffleOrder, [0, 1]);
  });

  test('旧格式队列文件无 shuffleOrder 字段 → 读为 null（恢复方重建）', () async {
    final storage = await makeStorage();
    await File('${tempDir.path}/playback_queue.json').writeAsString(
      jsonEncode({
        'v': 1,
        'queue': [song(1).toJson()],
        'currentIndex': 0,
      }),
    );
    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.shuffleOrder, isNull);
  });

  test('shuffleOrder 字段含非数字值 → 过滤后保留数字（合法性交给恢复方校验）', () async {
    final storage = await makeStorage();
    await File('${tempDir.path}/playback_queue.json').writeAsString(
      jsonEncode({
        'v': 1,
        'queue': [song(1).toJson(), song(2).toJson()],
        'currentIndex': 0,
        'shuffleOrder': [0, 'bad'],
      }),
    );
    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.shuffleOrder, [0]);
  });

  test('队列组与状态组分键写入：各自独立', () async {
    final storage = await makeStorage();

    await storage.saveQueue([
      Song(id: 1, name: 's1'),
      Song(id: 2, name: 's2'),
    ], 1);
    await storage.saveState(positionMs: 7000, playing: false);

    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.queue.map((s) => s.id), [1, 2]);
    expect(snap.currentIndex, 1);
    expect(snap.positionMs, 7000);
    expect(snap.playing, isFalse);

    // 再改状态组，队列不受影响
    await storage.saveState(positionMs: 15000, playing: true);
    final snap2 = await storage.load();
    expect(snap2!.queue.map((s) => s.id), [1, 2]);
    expect(snap2.currentIndex, 1);
    expect(snap2.positionMs, 15000);
    expect(snap2.playing, isTrue);
  });

  test('状态组缺失时走安全默认值（0 进度、暂停）', () async {
    final storage = await makeStorage();
    await storage.saveQueue([Song(id: 7, name: 's1')], 9);
    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.queue, hasLength(1));
    expect(snap.queue[0].id, 7);
    expect(snap.currentIndex, 9); // 来自队列组
    expect(snap.positionMs, 0); // 状态组缺失 → 0
    expect(snap.playing, isFalse); // 状态组缺失 → false
  });

  test('队列缺失/空 → load 返回 null（视为无状态）', () async {
    final storage = await makeStorage();
    await storage.saveState(positionMs: 8000, playing: true);
    expect(await storage.load(), isNull);
  });

  test('空队列快照 load 返回 null（视为无状态）', () async {
    final storage = await makeStorage();
    await storage.save(
      PlaybackSnapshot(
        queue: const [],
        currentIndex: null,
        positionMs: 0,
        playing: false,
      ),
    );
    expect(await storage.load(), isNull);
  });

  test('clear 后 load 返回 null', () async {
    final storage = await makeStorage();
    await storage.save(
      PlaybackSnapshot(
        queue: [song(1)],
        currentIndex: 0,
        positionMs: 1000,
        playing: true,
      ),
    );
    expect(await storage.load(), isNotNull);
    await storage.clear();
    expect(await storage.load(), isNull);
  });

  test('队列含非法字段类型（id 非数字）时整体回退 null，不抛错', () async {
    final storage = await makeStorage();
    await File(
      '${tempDir.path}/playback_queue.json',
    ).writeAsString('{"queue":[{"id":"bad","name":"s1"}],"currentIndex":9}');
    expect(await storage.load(), isNull);
  });

  test('saveQueue 成功后不留临时文件', () async {
    final storage = await makeStorage();
    await storage.saveQueue([song(1), song(2)], 0);
    final leftovers = tempDir.listSync().where((e) => e.path.endsWith('.tmp'));
    expect(leftovers, isEmpty, reason: '重命名成功后 tmp 已被消费，不得残留');
  });

  test('saveQueue 写临时文件失败时不破坏已落盘的旧队列', () async {
    final storage = await makeStorage();
    await storage.saveQueue([song(1)], 0);
    final target = File('${tempDir.path}/playback_queue.json');
    final oldContent = await target.readAsString();
    // 用同名目录占位 .tmp，迫使 writeAsString 失败。
    await Directory('${target.path}.tmp').create();
    await expectLater(
      storage.saveQueue([song(1), song(2), song(3)], 1),
      throwsA(isA<FileSystemException>()),
    );
    // 原子性：失败后旧队列原封未动（未被删/被截断）。
    expect(await target.readAsString(), oldContent);
    final snap = await storage.load();
    expect(snap!.queue, hasLength(1));
    expect(snap.queue[0].id, 1);
  });

  test('无 v 字段的旧格式队列文件仍可解析（视为 v1）', () async {
    final storage = await makeStorage();
    await File('${tempDir.path}/playback_queue.json').writeAsString(
      jsonEncode({
        'queue': [song(1).toJson()],
        'currentIndex': 0,
      }),
    );
    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.queue, hasLength(1));
    expect(snap.currentIndex, 0);
  });

  test('未知版本（v>1）的队列文件：返回 null 且不删除文件', () async {
    final storage = await makeStorage();
    await File('${tempDir.path}/playback_queue.json').writeAsString(
      jsonEncode({
        'v': 2,
        'queue': [song(9).toJson()],
        'currentIndex': 0,
      }),
    );
    expect(await storage.load(), isNull);
    expect(
      await File('${tempDir.path}/playback_queue.json').exists(),
      isTrue,
      reason: '未知版本文件应保留，交由未来版本处理',
    );
  });

  test('队列文件携带 v:1 格式版本字段', () async {
    final storage = await makeStorage();
    await storage.saveQueue([song(1)], 0);
    final raw = await File(
      '${tempDir.path}/playback_queue.json',
    ).readAsString();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded['v'], 1);
  });

  test('migrateLegacy：旧单键快照迁移到文件队列+SP状态，数据完整且旧键删除', () async {
    SharedPreferences.setMockInitialValues({
      'playback_snapshot_v1': jsonEncode({
        'queue': [song(1).toJson(), song(2).toJson()],
        'currentIndex': 1,
        'positionMs': 45200,
        'playing': true,
      }),
    });
    final storage = await makeStorage();
    expect(await storage.load(), isNull); // 迁移前读不到

    await migrateLegacy(storage);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('playback_snapshot_v1'), isNull); // 旧键删除

    final snap = await storage.load();
    expect(snap, isNotNull);
    expect(snap!.queue.map((s) => s.id), [1, 2]);
    expect(snap.currentIndex, 1);
    expect(snap.positionMs, 45200);
    expect(snap.playing, isTrue);
  });

  test('migrateLegacy：已有队列文件时不动旧键（幂等短路）', () async {
    SharedPreferences.setMockInitialValues({
      'playback_snapshot_v1': '{should not be touched}',
    });
    final storage = await makeStorage();
    await storage.saveQueue([song(5)], 0); // 已迁到文件
    await migrateLegacy(storage);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('playback_snapshot_v1'), '{should not be touched}');
    expect((await storage.load())!.queue.map((s) => s.id), [5]);
  });

  test('migrateLegacy：旧键损坏时清除旧键，不抛错', () async {
    SharedPreferences.setMockInitialValues({'playback_snapshot_v1': '{oops'});
    final storage = await makeStorage();
    await migrateLegacy(storage);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('playback_snapshot_v1'), isNull);
    expect(await storage.load(), isNull);
  });

  test('migrateLegacy：旧键队列为空时清除旧键，不写队列', () async {
    SharedPreferences.setMockInitialValues({
      'playback_snapshot_v1': '{"queue":[],"currentIndex":0}',
    });
    final storage = await makeStorage();
    await migrateLegacy(storage);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('playback_snapshot_v1'), isNull);
    expect(await storage.load(), isNull);
  });
}
