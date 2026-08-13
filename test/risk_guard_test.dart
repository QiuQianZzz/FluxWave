import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/netease/netease_client.dart';
import 'package:fluxwave/core/netease/request.dart';
import 'package:fluxwave/core/netease/storage/netease_session_storage.dart';
import 'package:fluxwave/providers/netease_provider.dart';

/// 风控守卫离线单测：匿名注册 deviceId 复用 / 失败冷却（不依赖真实网络）。
void main() {
  test('ensureStableDeviceId：已有稳定 deviceId 时复用（不换指纹）', () {
    final client = NeteaseClient(
      context: NeteaseRequestContext(deviceId: 'ABC123'),
    );
    client.ensureStableDeviceId();
    expect(client.ctx.deviceId, 'ABC123');
  });

  test('ensureStableDeviceId：空 deviceId 才补生成一次', () {
    final client = NeteaseClient(context: NeteaseRequestContext(deviceId: ''));
    client.ensureStableDeviceId();
    expect(client.ctx.deviceId, isNotEmpty);
  });

  test('shouldAttemptAnon：已有匿名态不重试', () {
    expect(shouldAttemptAnon(hasAnon: true), isFalse);
    expect(
      shouldAttemptAnon(hasAnon: true, retryAfter: DateTime.now()),
      isFalse,
    );
  });

  test('shouldAttemptAnon：无冷却记录直接尝试', () {
    expect(shouldAttemptAnon(), isTrue);
  });

  test('shouldAttemptAnon：冷却期内不重试', () {
    final now = DateTime(2026, 8, 3, 12);
    expect(
      shouldAttemptAnon(
        retryAfter: now.add(const Duration(hours: 1)),
        now: now,
      ),
      isFalse,
    );
  });

  test('shouldAttemptAnon：冷却过期后重试', () {
    final now = DateTime(2026, 8, 3, 12);
    expect(
      shouldAttemptAnon(
        retryAfter: now.subtract(const Duration(minutes: 1)),
        now: now,
      ),
      isTrue,
    );
  });

  test('storage：匿名注册冷却截止时间可持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await NeteaseSessionStorage.init();
    expect(storage.getAnonRetryAfter(), isNull);
    final at = DateTime(2026, 8, 3, 18);
    await storage.saveAnonRetryAfter(at);
    expect(storage.getAnonRetryAfter(), at);
  });
}
