import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
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
      songUrlImpl: (ids) async {
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

  testWidgets('网络故障进入退避重试：首轮立即暂停旧曲，而非让旧歌继续播', (tester) async {
    // 离线切未缓存歌的实测现象：UI 已切新歌/加载中，底层仍在播旧歌。
    // 回归 Fix 1：重试前先 pause 旧曲。区分性断言 pauseCount==1——
    // 修复前 pause 根本不会被调用（pauseCount==0）。
    final fake = _FakeAudioPlayer();
    final api = _FakeApi(
      songUrlImpl: (ids) async {
        if (ids.contains(1)) {
          return {
            'code': 200,
            'data': [
              {
                'id': 1,
                'url': 'https://example.com/1.mp3',
                'br': 320000,
                'level': 'standard',
                'type': 'mp3',
                'fee': 0,
              },
            ],
          };
        }
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
      networkRetryBaseDelay: const Duration(milliseconds: 10),
      playerFactory: () => fake,
    );
    player.init();

    await tester.runAsync(() async {
      // 先让歌 1 正常播放：底层播放器进入播放态。
      await player.playAt([song(1)], 0);
      expect(fake.playing, isTrue);
      expect(player.currentSong?.id, 1);

      // 切到歌 2（网络故障）：触发退避重试。
      await player.playAt([song(2)], 0);
      // 至少触发过重试（初始 1 轮 + 重试轮次）。
      expect(api.songUrlCalls, greaterThan(1));
      // Fix 1 的区分性断言：首轮失败进入重试前调用了 pause。
      expect(fake.pauseCount, 1);
      // 底层已暂停：pause 后 playing=false，且重试期间不再被 play 起来。
      expect(fake.playing, isFalse);
      expect(player.playing, isFalse);
      // 重试耗尽后显式 stop 底层播放器（保留当前曲等自愈）。
      expect(fake.stopCount, greaterThanOrEqualTo(1));
      // 当前曲保留，不被自动跳过。
      expect(player.currentSong?.id, 2);
      // 保留错误态供 UI 提示，而非误报无版权。
      expect(player.error, isA<NeteaseException>());
      // 让串行化守卫挂起的补偿加载/自愈定时器在托管时间内完成。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  });

  testWidgets('无版权（接口正常但 url=null）：仍按原逻辑跳过', (tester) async {
    final api = _FakeApi(
      songUrlImpl: (ids) async => {
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

/// 可注入 songUrl 实现的假 NeteaseApi。实现接收本次请求的歌曲 id 列表，
/// 便于按歌返回不同结果（如歌 1 正常、歌 2 网络故障）。
class _FakeApi extends NeteaseApi {
  _FakeApi({Future<Map<String, dynamic>> Function(List<num> ids)? songUrlImpl})
    : _impl = songUrlImpl,
      super(NeteaseClient());

  final Future<Map<String, dynamic>> Function(List<num> ids)? _impl;
  int songUrlCalls = 0;

  @override
  Future<Map<String, dynamic>> songUrl(
    List<num> ids, {
    String level = 'standard',
    bool useER = false,
  }) async {
    songUrlCalls++;
    final impl = _impl;
    if (impl != null) return impl(ids);
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

/// 可驱动/断言的假底层播放器：覆盖 just_audio [AudioPlayer] 的全部成员，
/// 让 PlayerProvider 在网络故障测试中走真实的暂停/停止/播放路径。
class _FakeAudioPlayer extends AudioPlayer {
  bool _playing = false;

  int pauseCount = 0;
  int stopCount = 0;
  int playCount = 0;
  int setUrlCount = 0;

  int _positionMs = 0;
  double _volume = 1.0;

  final _playerStateCtrl = StreamController<PlayerState>.broadcast();
  final _errorCtrl = StreamController<PlayerException>.broadcast();
  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration?>.broadcast();
  final _processingStateCtrl = StreamController<ProcessingState>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Future<void> play() async {
    playCount++;
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing = false;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _playing = false;
  }

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    setUrlCount++;
    return Duration.zero;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _positionMs = position?.inMilliseconds ?? 0;
  }

  @override
  Future<void> dispose() async {
    await _playerStateCtrl.close();
    await _errorCtrl.close();
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _processingStateCtrl.close();
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateCtrl.stream;

  @override
  Stream<PlayerException> get errorStream => _errorCtrl.stream;

  @override
  Stream<Duration> get positionStream => _positionCtrl.stream;

  @override
  Stream<Duration?> get durationStream => _durationCtrl.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      _processingStateCtrl.stream;

  @override
  Duration get position => Duration(milliseconds: _positionMs += 500);

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  double get volume => _volume;

  @override
  ProcessingState get processingState => ProcessingState.ready;
}