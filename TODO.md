# TODO

## ~~Android 小窗模式布局适配~~ ✅ 已完成

### 问题概述

小米澎湃系统（HyperOS 2.0+）的小窗模式下，系统返回了错误的WindowInsets值，导致MediaQuery.padding.top异常增大（如从38变成640），SafeArea把内容推到可视区域之外，页面内容不可见。

这是澎湃系统的bug，原生Android和其他厂商系统不受影响。

参考：https://github.com/flutter/flutter/issues/161086

### 解决方案

1. **全局修正MediaQuery.padding**（main.dart）
   - 添加 `_AndroidSmallWindowFix` Widget包裹MaterialApp
   - 检测top padding是否异常（超过窗口高度30%或超过500）
   - 异常时重置为0，让SafeArea正常工作

2. **小窗模式布局自适应**（window_utils.dart）
   - 添加 `WindowUtils` 工具类
   - 提供小窗模式检测：`isSmallWindow`、`isCompactWindow`
   - 提供自适应参数：`floatingNavHeight`、`miniPlayerClearance`、`playerCoverSize`等

### 修改文件

| 文件 | 修改内容 |
|------|----------|
| `lib/main.dart` | 添加 `_AndroidSmallWindowFix` 全局修正 |
| `lib/core/window_utils.dart` | 添加小窗模式检测和自适应布局参数 |
| `lib/pages/player_page.dart` | 使用自适应封面尺寸 |
| `lib/pages/home_page.dart` | 使用自适应SliverAppBar高度 |
| `lib/widgets/page_scroll_view.dart` | 使用自适应底部留白 |
| `lib/pages/main_scaffold.dart` | 使用自适应导航栏高度 |

---

## 代码重构：消除重复 / 解耦 / 拆分大文件

### 一、超大文件拆分

| 文件 | 行数 | 问题 |
|------|------|------|
| `providers/player_provider.dart` | 2385 | God Object：队列+播放+URL+歌词+迁移+统计全混 |
| `pages/player_page.dart` | 1491 | UI+状态+动画+进度条混在一起 |
| `pages/main_scaffold.dart` | 1217 | 导航+侧边栏+响应式布局+回调注册 |
| `core/playback_stats/database_helper.dart` | 1052 | 多表CRUD+迁移+版本管理 |

### 二、重复逻辑（6类）

#### 2a. `_playNext` / `_addToQueue` / `_playAt` — 5文件重复

| 文件 | 行号 |
|------|------|
| `pages/daily/daily_page.dart` | 53-60 |
| `pages/album/album_detail_page.dart` | 97-110 |
| `pages/playlist/playlist_detail_page.dart` | 180-192 |
| `pages/recent_plays_page.dart` | 52-70 |
| `pages/artist/artist_detail_page.dart` | 105-111 |

**方案**：提取 `SongActions` mixin，统一 toast 文案和 `PlayerProvider` 调用。

#### 2b. `_coverFallback` — 8文件重复 ✅ 已完成

| 文件 | 行号 |
|------|------|
| `pages/home_page.dart` | 397 |
| `widgets/mini_player.dart` | 428 |
| `pages/album/album_detail_page.dart` | 245 |
| `pages/profile_page.dart` | 558 |
| `pages/player_page.dart` | 725 |
| `widgets/song_tile.dart` | 172 |
| `pages/playlist/playlist_detail_page.dart` | 324 |
| `widgets/queue_sheet.dart` | 513 |

**方案**：已提取 `CoverPlaceholder` widget 到 `cover_image.dart`。

#### 2c. 错误占位 widget — 5个私有副本

| 文件 | 类名 | 行号 |
|------|------|------|
| `pages/home_page.dart` | `_SlideError` | 245 |
| `pages/daily/daily_page.dart` | `_DailyError` | 218 |
| `pages/radar/radar_page.dart` | `_RadarError` | 302 |
| `pages/search_page.dart` | `_ErrorState` | 248 |
| `pages/artist/artist_detail_page.dart` | `_TabError` | 726 |

**方案**：提取 `ErrorPlaceholder` widget 或复用 `SongListView` 错误态。

#### 2d. `_Header`（播放全部按钮）— 2文件重复

| 文件 | 行号 |
|------|------|
| `pages/liked_songs_page.dart` | 119 |
| `pages/recent_plays_page.dart` | 156 |

**方案**：提取 `PlayAllHeader` widget。

#### 2e. Loading/Error/Empty 三态 — 8+文件重复

`SongListView` 已解决 album/playlist，其余页面仍内联。

#### 2f. RefreshIndicator + Consumer — 3文件重复

| 文件 | 行号 |
|------|------|
| `pages/daily/daily_page.dart` | 68-78 |
| `pages/home_page.dart` | 80-89 |
| `pages/radar/radar_page.dart` | 49-54 |

### 三、耦合问题

| 文件 | 被引用次数 | 问题 |
|------|-----------|------|
| `providers/player_provider.dart` | 16文件 | 所有页面直接依赖 God Object |
| `core/netease/netease_api.dart` | 12文件 | API变更影响面大 |

### 四、状态管理不一致

- **Provider派**：`DailyProvider`、`HomeProvider`、`RadarProvider`、`SearchProvider`、`ArtistProvider`
- **setState派**：`RecentPlaysPage`、`AlbumDetailPage`、`PlaylistDetailPage`、`QrLoginPage`、`BackupPage`、`PlayerPage`

### 修复计划

| 优先级 | 任务 | 收益 | 状态 |
|--------|------|------|------|
| 🔴 P0 | 拆分 `player_provider.dart` — 提取 `QueueManager`（队列+shuffle+播放顺序） | 降低God Object风险 | 待完成 |
| 🔴 P0 | 拆分 `player_provider.dart` — 提取 `PlaybackStatsManager`（统计+最近播放+迁移） | 职责分离 | 待完成 |
| 🔴 P0 | 拆分 `player_provider.dart` — 提取 `UrlResolver`（URL解析+音质+缓冲） | 可测试性提升 | 待完成 |
| 🔴 P0 | 提取 `SongActions` mixin — 统一 `_playNext`/`_addToQueue`/`_playAt` + toast | 消除5处重复 | 待完成 |
| 🟡 P1 | 提取 `CoverPlaceholder` 到 `cover_image.dart` | 消除8处重复 | ✅ 已完成 |
| 🟡 P1 | 提取 `PlayAllHeader` widget | 消除2处重复 | 待完成 |
| 🟡 P1 | 提取 `ErrorPlaceholder` widget | 消除5处重复 | 待完成 |
| 🟢 P2 | 统一状态管理 — setState派改用Provider | 降低认知负担 | 待完成 |
| 🟢 P2 | 拆分 `player_page.dart` — 进度条/控制区/歌词区分离 | 可读性提升 | 待完成 |
| 🟢 P2 | 拆分 `main_scaffold.dart` — 侧边栏/导航/响应式分离 | 可读性提升 | 待完成 |
