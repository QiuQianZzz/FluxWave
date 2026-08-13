# FluxWave

跨平台聚合音乐播放器，基于 Flutter 构建。

## 功能

- 在线音乐搜索与播放
- 逐字歌词渲染（LRC/YRC/NRC）
- 本地收藏与播放记录
- 系统通知栏控制
- 音频缓存（边下边播 + 离线播放）
- 多音质选择
- 深色/浅色主题 + 动态取色
- 预测性返回手势

## 平台支持

| 平台 | 状态 |
|------|------|
| Android | 支持 |
| Windows | 支持 |

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
flutter build apk --release    # Android
flutter build windows --release # Windows
```

## 文档

- [用户指南](docs/USER_GUIDE.md)
- [开发文档](docs/DEVELOPMENT.md)
- [加解密实现](docs/netease-crypto.md)

## 许可证

MIT
