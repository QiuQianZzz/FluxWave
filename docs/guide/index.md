# 快速开始

## 简介

FluxWave 是一款跨平台聚合音乐播放器，基于 Flutter 构建，支持 Android、Windows。
提供在线音乐搜索播放、逐字歌词、本地收藏、播放统计、播放队列、动态取色主题等能力。

> [!IMPORTANT]
> 本项目仅供个人学习与研究使用，请勿用于任何商业及非法用途。
> 部分功能依赖第三方平台的非官方接口，相关权利归各平台所有；使用本项目产生的任何风险由使用者自行承担。

## 平台支持

| 平台 | 状态 |
|------|------|
| Android | 支持 |
| Windows | 支持 |

## 安装

从 [Releases](https://github.com/QiuQianZzz/FluxWave/releases) 下载对应平台的安装包：

- **Android**：安装 APK
- **Windows**：解压后运行可执行文件

## 从源码运行

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
```

## 快速上手

1. 通过底部导航栏进入**搜索**页，输入关键词搜索在线音乐
2. 点击歌曲开始播放，底部迷你播放栏常驻，点击展开全屏播放页
3. 播放页支持逐字歌词、进度条拖拽、音质切换，点击「队列」按钮管理播放列表

继续阅读 [播放音乐](./playback) 了解完整用法。
