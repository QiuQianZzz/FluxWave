import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/netease/netease_config.dart';
import 'package:fluxwave/core/netease/request.dart';

void main() {
  void reset() {
    NeteaseConfig.enableRealIpInjection = false;
    NeteaseConfig.bypassSystemProxy = true;
  }

  setUp(reset);
  tearDown(reset);

  test('显式 realIp 优先：开关关闭时也注入', () {
    expect(effectiveRealIp(explicit: '1.2.3.4'), '1.2.3.4');
  });

  test('开关关闭时不注入', () {
    NeteaseConfig.enableRealIpInjection = false;
    expect(effectiveRealIp(), '');
    expect(effectiveRealIp(explicit: ''), '');
  });

  test('开关开启时注入会话级国内 IP 且进程内稳定', () {
    NeteaseConfig.enableRealIpInjection = true;
    final a = effectiveRealIp();
    final b = effectiveRealIp();
    expect(a, isNotEmpty);
    expect(a, b); // 会话稳定，不漂移
    final parts = a.split('.');
    expect(parts, hasLength(4));
  });
}
