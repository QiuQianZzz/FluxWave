import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fluxwave/core/audio_service/app_audio_handler.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/widgets/cover_image.dart';

/// 通知栏封面解析（AppAudioHandler.setMediaItem）回归：
/// - 断网/无缓存 → 占位图；
/// - 封面已缓存（内存/磁盘）→ 真实封面 file URI，且先占位图后封面；
/// - 断网→重连同一首歌再下发 → 封面 URI 与占位图不同，绕过占位图去重；
/// - 竞态：后请求覆盖先请求，旧封面不覆盖新歌。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('notification_artwork_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // 占位图经 rootBundle 从 assets 通道读取：mock 原始二进制通道，返回任意
    // 字节即可（测试只断言 URI，不校验图片内容）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (ByteData? message) async {
      return ByteData(8);
    });
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Song song(int id) => Song(
    id: id,
    name: '歌$id',
    artists: const ['甲'],
    coverUrl: null,
    durationMs: 200000,
    fee: 0,
  );

  /// 订阅媒体项事件流：BehaviorSubject.seeded(null) 的种子值会作为首事件
  /// 到达，用 skip(1) 丢弃；真实事件可能异步投递，用 [waitFor] 等待。
  List<MediaItem?> subscribe(AppAudioHandler handler) {
    final events = <MediaItem?>[];
    handler.mediaItem.skip(1).listen(events.add);
    return events;
  }

  Future<void> waitFor(List<MediaItem?> events, bool Function() cond,
      [String? what]) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('等待事件超时: ${what ?? cond.toString()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('断网且未缓存：仅下发占位图', () async {
    final handler = AppAudioHandler();
    final events = subscribe(handler);

    // 127.0.0.1:1 → 连接被拒/HTTP 400，fetchBytes 走失败路径返回 null。
    await handler.setMediaItem(
      song(1),
      coverUrl: 'https://127.0.0.1:1/offline.jpg',
    );

    await waitFor(events, () => events.isNotEmpty, '占位图事件');
    // 阶段 2 已随 await 完成（bytes == null，不会再有封面事件）。
    expect(events.length, 1);
    expect(events.single!.id, 'netease_1');
    expect(events.single!.artUri, isNotNull);
    expect(events.single!.artUri!.scheme, 'file');
    expect(events.single!.artUri!.path, endsWith('placeholder.png'));
  });

  test('封面已缓存：先占位图后封面，最终为封面 file URI', () async {
    final handler = AppAudioHandler();
    final events = subscribe(handler);

    const url = 'https://127.0.0.1:1/cached.jpg';
    CoverImageCache.instance.put(url, Uint8List.fromList([1, 2, 3]));
    await handler.setMediaItem(song(2), coverUrl: url);

    // 两阶段：立即占位图 → 解析出封面后重发。
    await waitFor(
      events,
      () => events.length >= 2 &&
          events.last!.artUri!.path.endsWith('cover_netease_2.jpg'),
      '封面事件',
    );
    expect(events.first!.artUri!.path, endsWith('placeholder.png'));
    expect(events.last!.artUri!.path, endsWith('cover_netease_2.jpg'));
  });

  test('断网→重连：同一首歌再下发时封面恢复（绕过占位图去重）', () async {
    final handler = AppAudioHandler();
    final events = subscribe(handler);

    const url = 'https://127.0.0.1:1/reconnect.jpg';
    // 第一遍：断网（未缓存）→ 占位图。
    await handler.setMediaItem(song(3), coverUrl: url);
    await waitFor(
      events,
      () => events.isNotEmpty && events.last!.artUri!.path.endsWith('placeholder.png'),
      '首遍占位图',
    );

    // 网络恢复（内存缓存可命中）→ 同歌再下发 → 封面 URI 与占位图不同 → 重新下发。
    CoverImageCache.instance.put(url, Uint8List.fromList([9, 9]));
    await handler.setMediaItem(song(3), coverUrl: url);

    await waitFor(
      events,
      () => events.last!.artUri!.path.endsWith('cover_netease_3.jpg'),
      '重连后封面恢复',
    );
    // 第二遍的占位图与首遍相同被去重：事件数应为 2（占位图 + 封面）。
    expect(events.length, 2);
    expect(events.last!.artUri, isNot(equals(events.first!.artUri)));
  });

  test('歌曲无封面：仅下发占位图', () async {
    final handler = AppAudioHandler();
    final events = subscribe(handler);

    await handler.setMediaItem(song(4));

    await waitFor(events, () => events.isNotEmpty, '占位图事件');
    expect(events.length, 1);
    expect(events.single!.artUri!.path, endsWith('placeholder.png'));
  });

  test('去重：同歌同封面重复下发不重复发事件', () async {
    final handler = AppAudioHandler();
    final events = subscribe(handler);

    const url = 'https://127.0.0.1:1/dedup.jpg';
    CoverImageCache.instance.put(url, Uint8List.fromList([1]));
    await handler.setMediaItem(song(5), coverUrl: url);
    await waitFor(
      events,
      () => events.length >= 2 && events.last!.artUri!.path.endsWith('cover_netease_5.jpg'),
      '首遍封面',
    );
    final count = events.length;

    await handler.setMediaItem(song(5), coverUrl: url);
    // 第二遍应全程不产生新事件：等一个宽限窗口确认（阶段 2 已在 await 内完成）。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events.length, count);
  });

  test('竞态：后请求覆盖先请求，旧封面不覆盖新歌', () async {
    final handler = AppAudioHandler();
    final events = subscribe(handler);

    const urlA = 'https://127.0.0.1:1/race_a.jpg';
    const urlB = 'https://127.0.0.1:1/race_b.jpg';
    CoverImageCache.instance.put(urlA, Uint8List.fromList([1]));
    CoverImageCache.instance.put(urlB, Uint8List.fromList([2]));

    // 不 await 先发起，模拟快速切歌：旧请求的解析结果必须被丢弃。
    final fA = handler.setMediaItem(song(6), coverUrl: urlA);
    final fB = handler.setMediaItem(song(7), coverUrl: urlB);
    await fA;
    await fB;

    await waitFor(
      events,
      () => events.last!.artUri!.path.endsWith('cover_netease_7.jpg'),
      'B 封面事件',
    );
    expect(events.last!.id, 'netease_7');
    expect(events.last!.artUri!.path, endsWith('cover_netease_7.jpg'));
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getTemporaryPath() async => tempDir;
}
