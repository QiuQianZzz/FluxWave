# 项目概览

## 项目概述

FluxWave 是一款跨平台聚合音乐播放器，基于 Flutter 构建，支持 Android、Windows。
核心能力包括在线音乐搜索/播放、歌词逐字渲染、本地收藏、播放统计、系统通知栏控制等。

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
│   ├── audio_cache/    # 音频缓存代理（本地 HTTP 代理 + SQLite 索引 + 封面/歌词缓存）
│   ├── audio_service/  # 系统媒体会话（通知栏控制、MediaSession）
│   ├── backup_service.dart # 数据备份与恢复
│   ├── color_readability.dart # 封面强调色可读性修正 + 背景压暗
│   ├── cover_color_extractor.dart # 封面取色（主色 + 可读强调色）
│   ├── fluid_palette.dart # 流体背景色板
│   ├── localizations/  # 本地化
│   ├── logging/        # 日志系统（运行日志 + 崩溃日志 + 导出）
│   ├── lyric/          # 歌词解析（LRC/YRC/NRC 模型 + 解析器）
│   ├── navigation/     # 路由导航（预测性返回手势支持）
│   ├── netease/        # 在线音乐 API 适配层（加解密、会话管理）
│   ├── permissions/    # 权限申请
│   ├── playback_stats/ # 播放统计 + 最近播放 + 本地收藏存储
│   ├── player/         # 播放 URL 解析（音质选择、试听判断）
│   └── update_service.dart # 更新检查
├── models/             # 数据模型（Song、Playlist 等）
├── pages/              # 页面（首页、播放页、搜索、我的、设置、备份、播放统计、雷达、每日推荐等）
├── providers/          # 状态管理（PlayerProvider、ThemeProvider、NeteaseProvider 等）
├── widgets/            # 通用组件（歌词视图、迷你播放栏、流体背景、播放队列面板等）
├── shaders/            # GLSL 着色器（fluid.frag 流体背景）
└── main.dart           # 应用入口
```

## 构建

```bash
# Android
flutter build apk --release

# Windows
flutter build windows --release
```