# 架构要点

## 播放器架构

- `PlayerProvider`：播放状态中枢，管理队列、循环/随机模式、进度持久化、洗牌序持久化（随机模式下切歌/追加/移除不重排洗牌序）
- `QueueSheet`：播放队列面板，行首序号、点击跳转、顶部「第 N 首」定位当前项、右下角快捷操作（清空队列 / 原始·随机视图切换）；面板底色与当前行高亮跟随主题实时刷新
- `AppAudioHandler`：audio_service 回调入口，处理系统媒体按钮事件
- `MediaSessionManager`：媒体会话管理，单例模式

## 主题与动态取色

- `ThemeProvider`：管理主题模式（system/light/dark）、种子色、自定义调色板，统一覆盖 AppBar/Card/ListTile/NavigationBar 等组件主题
- 动态取色：`_CoverSeedWatcher` 监听当前歌曲封面，经 `CoverColorExtractor` 提取主色后作为 `ColorScheme.fromSeed` 的种子；无封面/解析前回退到手动种子色
- 封面种子持久化：最近一次取色写入 SharedPreferences，启动时恢复，避免启动瞬间回落到种子色造成闪色；关闭动态取色时清除
- 预测性返回：设置开关控制 `PageTransitionsTheme` 与 `showPredictiveBackSheet`，仅 Android + 系统支持时生效

## 流体背景与强调色（播放页视觉）

- `FluidBackground`：封面取色 → 色板过渡 → GLSL shader 渲染，全链路受帧率档位节流（省电/均衡/流畅），低功耗设备可降帧
- 封面色板：`CoverColorExtractor` 提取主色 → `darkenForBackground` 压暗过亮封面（白/浅色封面压到明度 0.22-0.33、饱和 ≤0.35），深色封面原样通过，保证白字可读
- 强调色发布：`FluidBackground.accentColor` 静态通知器发布可读强调色（`ReadableAccentResolver`），播放页 `ValueListenableBuilder` 监听并覆盖主题 primary，色板过渡完成即发布，不依赖动画推进
- 节奏律动：BPM 硬编码 120，`_onPosition` 写入脉冲目标、节流帧内指数平滑推进，shader 内做中心缩放 + 亮度脉冲
- 性能要点：动画重启首帧 delta 修复、跳节流帧不更新 `_lastTickUs`（保证每间隔恰好执行一次）、过渡用真实 elapsed 累计（跳帧不拉长过渡）

## 缓存系统

- 本地 HTTP 代理（`AudioCacheProxy`）：拦截 just_audio 的 HTTP 请求，透明路由到本地缓存
- `CacheStore`：SQLite 管理缓存索引，支持边下边落（播放中途崩溃不丢缓存）
- 缓存策略：优先离线 → 代理回源 → CDN 直链

## 歌词系统

- 支持 LRC（逐行）、YRC（逐字）、NRC（逐字）、TTML（逐字）四种格式
- `LyricProvider`：歌词加载编排，三级缓存策略（进程内 LRU 40 首 → 磁盘 → 网络），磁盘缓存按格式分离（`lyrics.txt` / `lyrics_ttml.txt`）
- TTML 歌词源：`AmllDbClient` 多镜像源自动降级，`TtmlParser` 解析 Apple Music TTML 格式，支持背景人声（x-bg）、BCP 47 语言标签翻译选择
- `LyricView`：Canvas 逐帧绘制，支持卡拉 OK 渐变高亮、前奏/间奏呼吸圆点
- Apple Music 风格弹簧滚动动画（`lyric_spring.dart`）：行间切换带弹性缓动，圆点动画带锚定逻辑；景深模糊强度可在设置中调节

## 网络层

- 端到端加密：weapi/eapi/linuxapi/xeapi 四种模式
- 会话管理：Cookie 持久化 + 24h 自动续期
- 安全策略：默认直连、不注入来源 IP、绕过系统代理
- 扫码登录：二维码轮询退后台自动暂停、断网指数退避重试，日志降噪

加解密协议的详细实现见 [加解密实现](./crypto)。