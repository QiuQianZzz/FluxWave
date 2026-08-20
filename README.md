# FluxWave

跨平台聚合音乐播放器，基于 Flutter 构建，主打**沉浸式播放体验**。

[![GitHub stars](https://img.shields.io/github/stars/QiuQianZzz/FluxWave?style=flat)](https://github.com/QiuQianZzz/FluxWave/stargazers)
[![Release](https://img.shields.io/github/v/release/QiuQianZzz/FluxWave)](https://github.com/QiuQianZzz/FluxWave/releases)
[![License](https://img.shields.io/github/license/QiuQianZzz/FluxWave)](https://github.com/QiuQianZzz/FluxWave/blob/master/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-blue)](https://github.com/QiuQianZzz/FluxWave)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](https://github.com/QiuQianZzz/FluxWave/pulls)

在搜索、逐字歌词、本地收藏等基础能力之外，FluxWave 用自研 GLSL 着色器为播放页打造了跟随封面色采动态流动的背景，并通过封面强调色驱动整个播放页主题，让每首歌都有一块属于自己的视觉氛围。

> [!IMPORTANT]
> 本项目仅供个人学习与研究使用，请勿用于任何商业及非法用途。
> 部分功能依赖第三方平台的非官方接口，相关权利归各平台所有；使用本项目产生的任何风险由使用者自行承担。

## 功能亮点

### 沉浸式播放体验

- **流体动态背景**：封面取色生成色板，经 Fragment Shader 实时渲染出流动渐变背景，切换歌曲时色板平滑过渡、不闪烁
- **封面强调色主题**：播放页固定深色基调，从封面解析可读强调色驱动播放按钮、进度条、歌词高亮，白底封面自动压暗压饱和保证可读性
- **节奏律动**：背景随音乐进度脉冲，可独立开关
- **逐字歌词**：LRC / YRC / NRC 三种格式，Canvas 逐帧绘制，卡拉 OK 渐变高亮，Apple Music 风格弹簧滚动动画，前奏/间奏呼吸圆点

### 完整播放能力

- 在线音乐搜索与播放、多音质选择、试听判断
- 音频缓存（边下边播）+ 离线播放
- 本地收藏、最近播放、播放统计
- 系统通知栏控制（MediaSession）
- 深色/浅色主题、动态取色
- 预测性返回手势、播放队列与循环/随机模式
- 数据备份与恢复

### 性能与隐私

- 播放页背景帧率三档可调（省电 / 均衡 / 流畅）
- 端到端加密、会话自动续期、默认直连不注入来源 IP

## 平台支持

| 平台 | 状态 |
|------|------|
| Android | 支持 |
| Windows | 支持 |

### 能力现状

| 能力 | 说明 |
|------|------|
| 在线音乐 | 搜索 / 播放 / 多音质 / 试听判断 |
| 歌词 | LRC / YRC / NRC 逐字渲染 |
| 缓存 | 边下边播 + 离线播放 |
| 收藏与记录 | 本地收藏 / 最近播放 / 播放统计 |
| 系统集成 | 通知栏控制（MediaSession）、预测性返回手势 |
| 主题 | 深色/浅色 + 动态取色 + 封面强调色 |
| 数据 | 备份与恢复 |

## 快速开始

```bash
# 克隆项目
git clone https://github.com/QiuQianZzz/FluxWave.git
cd FluxWave

# 安装依赖
flutter pub get

# 运行
flutter run

# 测试
flutter test

# 构建
flutter build apk --release     # Android
flutter build windows --release # Windows
```

## 文档

- [用户指南](docs/USER_GUIDE.md)
- [开发文档](docs/DEVELOPMENT.md)
- [加解密实现](docs/netease-crypto.md)

## 隐私与数据

- 播放记录、收藏、设置等数据仅保存在设备本地数据库
- 音频缓存存储在应用私有目录，不对外公开
- 不采集任何个人信息，无第三方统计与广告 SDK

## 贡献

欢迎提交 Issue 与 PR。请先阅读 [开发文档](docs/DEVELOPMENT.md) 了解架构与约定。

## 技术栈

Flutter · Provider · just_audio · audio_service · sqflite · GLSL

## 许可

MIT License，详见 [LICENSE](LICENSE)。