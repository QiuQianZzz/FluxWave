import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxwave/core/lyric/line_lyric_reveal_mode.dart';
import 'package:fluxwave/core/lyric/lyric_spring.dart';
import 'package:fluxwave/providers/settings_provider.dart';

/// SettingsProvider.launcherIconId（桌面图标切换）的持久化测试。
void main() {
  test('默认使用默认图标（launcherIconId=default）', () {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsProvider();
    expect(s.initialized, isFalse);
    expect(s.launcherIconId, 'default');
  });

  test('setLauncherIconId 切换并持久化；非法 id 忽略', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsProvider();
    await s.init();
    expect(s.launcherIconId, 'default');

    await s.setLauncherIconId('alt');
    expect(s.launcherIconId, 'alt');

    // 不在可选列表内的 id 应被忽略
    await s.setLauncherIconId('nonexistent');
    expect(s.launcherIconId, 'alt');

    await s.setLauncherIconId('default');
    expect(s.launcherIconId, 'default');

    // 重新 init 应从磁盘恢复最后一次选择
    await s.setLauncherIconId('alt');
    final s2 = SettingsProvider();
    await s2.init();
    expect(s2.launcherIconId, 'alt');
  });

  test('默认行级歌词揭示方式为纯静态；切换并持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsProvider();
    expect(s.lineLyricRevealMode, LineLyricRevealMode.staticLine);

    await s.init();
    expect(s.lineLyricRevealMode, LineLyricRevealMode.staticLine);

    await s.setLineLyricRevealMode(LineLyricRevealMode.linearSweep);
    expect(s.lineLyricRevealMode, LineLyricRevealMode.linearSweep);

    final s2 = SettingsProvider();
    await s2.init();
    expect(s2.lineLyricRevealMode, LineLyricRevealMode.linearSweep);

    // 未知值回退到纯静态
    SharedPreferences.setMockInitialValues({
      'line_lyric_reveal_mode': 'nonexistent_mode',
    });
    final s3 = SettingsProvider();
    await s3.init();
    expect(s3.lineLyricRevealMode, LineLyricRevealMode.staticLine);
  });

  test('歌词景深模糊默认 75；调节并持久化；兼容旧版布尔存储', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsProvider();
    expect(s.lyricDepthBlurAmount, 75);

    await s.init();
    expect(s.lyricDepthBlurAmount, 75);

    await s.setLyricDepthBlurAmount(30);
    expect(s.lyricDepthBlurAmount, 30);
    await s.setLyricDepthBlurAmount(150);
    expect(s.lyricDepthBlurAmount, 100, reason: '超上限应被钳制到 100');

    final s2 = SettingsProvider();
    await s2.init();
    expect(s2.lyricDepthBlurAmount, 100);

    // 旧版 bool 存储迁移：false→0（关闭）、true→75（默认强度）。
    SharedPreferences.setMockInitialValues({'lyric_depth_blur': false});
    final s3 = SettingsProvider();
    await s3.init();
    expect(s3.lyricDepthBlurAmount, 0);

    SharedPreferences.setMockInitialValues({'lyric_depth_blur': true});
    final s4 = SettingsProvider();
    await s4.init();
    expect(s4.lyricDepthBlurAmount, 75);
  });

  test('流体背景律动默认关；切换并持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsProvider();
    expect(s.fluidBeat, isFalse);

    await s.init();
    expect(s.fluidBeat, isFalse);

    await s.setFluidBeat(true);
    expect(s.fluidBeat, isTrue);

    final s2 = SettingsProvider();
    await s2.init();
    expect(s2.fluidBeat, isTrue);

    await s2.setFluidBeat(false);
    expect(s2.fluidBeat, isFalse);
  });

  test('流体帧率默认均衡；切换并持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsProvider();
    expect(s.fluidFrameRate, FluidFrameRate.balanced);

    await s.init();
    expect(s.fluidFrameRate, FluidFrameRate.balanced);

    await s.setFluidFrameRate(FluidFrameRate.high);
    expect(s.fluidFrameRate, FluidFrameRate.high);

    final s2 = SettingsProvider();
    await s2.init();
    expect(s2.fluidFrameRate, FluidFrameRate.high);

    await s2.setFluidFrameRate(FluidFrameRate.low);
    expect(s2.fluidFrameRate, FluidFrameRate.low);
  });

  test('歌词弹簧档位默认标准；切换并持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsProvider();
    expect(s.lyricSpringPreset, LyricSpringPreset.standard);

    await s.init();
    expect(s.lyricSpringPreset, LyricSpringPreset.standard);

    await s.setLyricSpringPreset(LyricSpringPreset.bouncy);
    expect(s.lyricSpringPreset, LyricSpringPreset.bouncy);

    final s2 = SettingsProvider();
    await s2.init();
    expect(s2.lyricSpringPreset, LyricSpringPreset.bouncy);

    await s2.setLyricSpringPreset(LyricSpringPreset.soft);
    expect(s2.lyricSpringPreset, LyricSpringPreset.soft);
  });
}
