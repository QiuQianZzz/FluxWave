import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/models/song.dart';
import 'package:fluxwave/providers/liked_songs_provider.dart';
import 'package:fluxwave/providers/netease_provider.dart';
import 'package:fluxwave/providers/player_provider.dart';
import 'package:fluxwave/providers/settings_provider.dart';

/// 网络瞬时故障回归：DNS/断网等 socket 错误不再被误判为「歌曲不可播」→
/// 自动跳过链/累计连续失败，而是原地退避重试，重试耗尽后保留当前曲等待自愈。
///
/// 模拟测试环境一贯的网络屏蔽（SocketException），但本项目现在将其分类为
/// isNetwork 瞬时故障，行为应与「无版权（NoPlayableUrl）」严格区分。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Song song(int id) => Song(
    id: id,
    name: '歌$id',
    artists: const ['甲'],
    coverUrl: null,
    durationMs: 200000,
    fee: 0,
  );

  testWidgets('DNS 解析失败（errno=7）：原地重试、不跳过、保留当前曲', (tester) async {
    final api = _FakeApi(
      songUrlImpl: () async {
        throw NeteaseException.network(
          SocketException(
            'Failed host lookup',
            osError: const OSError('No address associated with hostname', 7),
          ),
          requestPath: '/api/song/enhance/player/url/v1',
        );
      },
    );
    final settings = SettingsProvider();
    await settings.init();
    final player = PlayerProvider(
      netease: _FakeNeteaseProvider(api),
      settings: settings,
      liked: LikedSongsProvider(),
      networkRetryAttempts: 2,
      // 稍大的基础延迟，确保短退避（2×base/3×base）期间自愈定时器
      // （baseDelay×1）尚未触发，避免 _error 被新一轮重试重置而断言不稳。
      networkRetryBaseDelay: const Duration(milliseconds: 50),
    );
    player.init();

    // runAsync 走真实异步 + 真实 Timer，允许退避真正发生。
    // 断言必须紧跟 playAt 返回之后：此刻短退避已耗尽、_error 已置位，
    // 而首轮自愈定时器（baseDelay×1）尚未触发（触发会重置 _error 开始新重试）。
    await tester.runAsync(() async {
      await player.playAt([song(1)], 0);
      // 至少触发过重试（初始 1 轮 + 重试轮次，各档位都会调用 songUrl）。
      expect(api.songUrlCalls, greaterThan(1));
      // 网络故障不进入跳过链：跳过列表为空、无停止原因、不累计（不切歌）。
      expect(player.skipCount, 0);
      expect(player.skipStopReason, isNull);
      // 当前曲保持不变（未被自动跳过到下一首）。
      expect(player.currentSong?.id, 1);
      // 网络失败期间不误报「播放中」：底层旧曲已暂停/停止，UI 不应显示播放态。
      expect(player.playing, isFalse);
      // 保留错误态供 UI 提示，而非误报无版权。
      expect(player.error, isNotNull);
      expect(player.error, isA<NeteaseException>());
      // 让串行化守卫挂起的补偿加载/防抖落盘在托管时间内完成，
      // 避免其 _loadCurrent 在测试结束后的 dispose 上报「used after disposed」。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  });

  testWidgets('无版权（接口正常但 url=null）：仍按原逻辑跳过', (tester) async {
    final api = _FakeApi(
      songUrlImpl: () async => {
        'code': 200,
        'data': [
          {
            'id': 1,
            'url': null,
            'br': 0,
            'level': 'standard',
            'type': 'mp3',
            'fee': 1,
          },
        ],
      },
    );
    final settings = SettingsProvider();
    await settings.init();
    final player = PlayerProvider(
      netease: _FakeNeteaseProvider(api),
      settings: settings,
      liked: LikedSongsProvider(),
      networkRetryAttempts: 2,
      networkRetryBaseDelay: const Duration(milliseconds: 1),
    );
    player.init();

    await tester.runAsync(() async {
      await player.playAt([song(1), song(2)], 0);
      // 同「不 dispose」惯例：让补偿加载与防抖落盘跑完。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // 无版权（非网络故障）仍走跳过链：有跳过记录（skipCount 上升）。
    // 两首都无版权 → 默认 list 循环下反复跳过，连续失败累计超限 → overLimit
    // 停止原因置位，与「网络自愈保留当前曲」（stopReason 保持 null）严格区分。
    expect(player.skipCount, greaterThanOrEqualTo(1));
    expect(player.skipStopReason, 'overLimit');
  });

  testWidgets('流中断错误分类：网络/IO 类可恢复，解析/解码类不可恢复', (tester) async {
    // Media3 PlaybackException.errorCode（Android 上 just_audio
    // PlayerException.code 映射此值）。
    const networkCodes = [
      2000000, // ERROR_CODE_IO_UNSPECIFIED
      2000001, // ERROR_CODE_IO_NETWORK_CONNECTION_FAILED
      2000002, // ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
      2000003, // ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE
      2000004, // ERROR_CODE_IO_BAD_HTTP_STATUS
      2000005, // ERROR_CODE_IO_FILE_NOT_FOUND
      2000008, // ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE
    ];
    for (final code in networkCodes) {
      expect(
        isRecoverableStreamErrorCode(code),
        isTrue,
        reason: 'code=$code 应为可恢复网络/IO 错误',
      );
    }
    // 解析/解码/DRM/未知：不可恢复。
    const nonRecoverable = [
      3000001, // ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED
      3000003, // ERROR_CODE_PARSING_CONTAINER_MALFORMED
      4000003, // ERROR_CODE_DECODING_FAILED
      5000001, // ERROR_CODE_AUDIO_TRACK_INIT_FAILED
      6000001, // ERROR_CODE_DRM_SCHEME_UNSUPPORTED
      0, // 未定义/未知
      -1,
    ];
    for (final code in nonRecoverable) {
      expect(
        isRecoverableStreamErrorCode(code),
        isFalse,
        reason: 'code=$code 不应视为可恢复网络/IO 错误',
      );
    }
  });
}

/// 可注入 songUrl 实现的假 NeteaseApi。
class _FakeApi extends NeteaseApi {
  _FakeApi({Future<Map<String, dynamic>> Function()? songUrlImpl})
    : _impl = songUrlImpl,
      super(NeteaseClient());

  final Future<Map<String, dynamic>> Function()? _impl;
  int songUrlCalls = 0;

  @override
  Future<Map<String, dynamic>> songUrl(
    List<num> ids, {
    String level = 'standard',
    bool useER = false,
  }) async {
    songUrlCalls++;
    final impl = _impl;
    if (impl != null) return impl();
    return super.songUrl(ids, level: level, useER: useER);
  }
}

/// 返回假 api 的 NeteaseProvider（跳过真实 init/网络）。
class _FakeNeteaseProvider extends NeteaseProvider {
  _FakeNeteaseProvider(this._mockApi);

  final _FakeApi _mockApi;

  @override
  NeteaseApi get api => _mockApi;

  @override
  bool get initialized => true;

  @override
  bool get apiReady => true;

  @override
  Future<void> get initializedFuture => Future<void>.value();
}