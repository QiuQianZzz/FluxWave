# FluxWave 开发文档

## 项目概述

FluxWave 是一款跨平台聚合音乐播放器，基于 Flutter 构建，支持 Android、Windows。核心能力包括在线音乐搜索/播放、歌词逐字渲染、本地收藏、播放统计、系统通知栏控制等。

## 技术栈

- **框架**：Flutter 3.44+，Dart 3.12+
- **状态管理**：Provider
- **音频引擎**：just_audio（桌面 + 移动端），audio_service（系统媒体会话）
- **数据库**：sqflite + sqflite_common_ffi（桌面端 FFI 兼容）
- **缓存**：自建 HTTP 代理服务器 + SQLite 索引（边下边播 + 离线缓存）
- **歌词**：自研逐字渲染引擎（LRC/YRC/NRC 解析 + Canvas 逐帧绘制）

## 目录结构

```
lib/
├── constants/          # 常量定义（导航阈值、动画参数等）
├── core/
│   ├── audio_cache/    # 音频缓存代理（本地 HTTP 代理 + SQLite 索引）
│   ├── audio_service/  # 系统媒体会话（通知栏控制、MediaSession）
│   ├── localizations/  # 本地化
│   ├── logging/        # 日志系统（运行日志 + 崩溃日志）
│   ├── lyric/          # 歌词解析（LRC/YRC/NRC 模型 + 解析器）
│   ├── navigation/     # 路由导航（预测性返回手势支持）
│   ├── netease/        # 在线音乐 API 适配层（加解密、会话管理）
│   ├── permissions/    # 权限申请
│   ├── playback_stats/ # 播放统计 + 最近播放 + 本地收藏存储
│   ├── player/         # 播放 URL 解析（音质选择、试听判断）
│   └── color_readability.dart # 封面强调色可读性修正 + 背景压暗
├── models/             # 数据模型（Song、Playlist 等）
├── pages/              # 页面（首页、播放页、搜索、我的、设置等）
├── providers/          # 状态管理（PlayerProvider、NeteaseProvider 等）
├── widgets/            # 通用组件（歌词视图、迷你播放栏、流体背景等）
├── shaders/            # GLSL 着色器（fluid.frag 流体背景）
└── main.dart           # 应用入口
```

## 架构要点

### 播放器架构

- `PlayerProvider`：播放状态中枢，管理队列、循环/随机模式、进度持久化
- `AppAudioHandler`：audio_service 回调入口，处理系统媒体按钮事件
- `MediaSessionManager`：媒体会话管理，单例模式

### 流体背景与强调色（播放页视觉）

- `FluidBackground`：封面取色 → 色板过渡 → GLSL shader 渲染，全链路受帧率档位节流（省电/均衡/流畅），低功耗设备可降帧
- 封面色板：`CoverColorExtractor` 提取主色 → `darkenForBackground` 压暗过亮封面（白/浅色封面压到明度 0.22-0.33、饱和 ≤0.35），深色封面原样通过，保证白字可读
- 强调色发布：`FluidBackground.accentColor` 静态通知器发布可读强调色（`ReadableAccentResolver`），播放页 `ValueListenableBuilder` 监听并覆盖主题 primary，色板过渡完成即发布，不依赖动画推进
- 节奏律动：BPM 硬编码 120，`_onPosition` 写入脉冲目标、节流帧内指数平滑推进，shader 内做中心缩放 + 亮度脉冲
- 性能要点：动画重启首帧 delta 修复、跳节流帧不更新 `_lastTickUs`（保证每间隔恰好执行一次）、过渡用真实 elapsed 累计（跳帧不拉长过渡）

### 缓存系统

- 本地 HTTP 代理（`AudioCacheProxy`）：拦截 just_audio 的 HTTP 请求，透明路由到本地缓存
- `CacheStore`：SQLite 管理缓存索引，支持边下边落（播放中途崩溃不丢缓存）
- 缓存策略：优先离线 → 代理回源 → CDN 直链

### 歌词系统

- 支持 LRC（逐行）、YRC（逐字）、NRC（逐字）三种格式
- `LyricProvider`：歌词加载编排，进程内 LRU 缓存（40 首）
- `LyricView`：Canvas 逐帧绘制，支持卡拉 OK 渐变高亮、前奏/间奏呼吸圆点

### 网络层

- 端到端加密：weapi/eapi/linuxapi/xeapi 四种模式
- 会话管理：Cookie 持久化 + 24h 自动续期
- 安全策略：默认直连、不注入来源 IP、绕过系统代理

## 测试

```bash
# 运行全量测试
flutter test

# 运行单个测试文件
flutter test test/lyric_parser_test.dart

# 运行 analyze
flutter analyze
```

测试覆盖：414 个测试用例，涵盖存储层、Provider 状态管理、页面渲染、布局溢出回归、预测性返回手势、色彩可读性等。

## 构建

```bash
# Android
flutter build apk --release

# Windows
flutter build windows --release
```

## 参考项目

本项目在实现过程中参考了以下开源项目的架构与实现：

- **SPlayer**：歌词解析、加密协议基础实现
- **SPlayer-Next**：API 端点设计、会话管理、缓存策略
- **NeriPlayer**：歌词逐字渲染、UI 交互动画、播放器状态管理

感谢以上项目的社区贡献者。
