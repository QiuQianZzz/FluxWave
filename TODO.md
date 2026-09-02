# TODO

## Android 小窗模式布局适配

### 问题概述

Android freeform/small window 模式下，除小播放器和底部 Tab 栏外所有内容不可见。根因是全页面布局假设全屏高度，固定常量在小窗（300-400px）下挤占全部空间。

### 关键问题

| 优先级 | 问题 | 位置 | 说明 |
|--------|------|------|------|
| P0 | 底部固定占用 ~196px | `page_scroll_view.dart:6,10` | `kFloatingNavHeight(80) + kMiniPlayerClearance(100) + 16`，小窗 350px 时只剩 154px 给内容 |
| P0 | 播放页 `freeH0` 归零 | `player_page.dart:469-478` | 封面+控件+标题合计 ~447px，小窗高度不够时全部堆叠重叠 |
| P1 | 封面最小 180px | `player_page.dart:407` | `.clamp(180.0, 280.0)` 强制最小尺寸，小窗下封面占 60% 高度 |
| P1 | 首页 SliverAppBar 148px | `home_page.dart:110` | 展开高度 148 + 底部栏 196 = 344px，小窗下内容区高度为负 |
| P1 | 歌词面板高度归零 | `player_page.dart:514-516` | 窗口 < 280px 时 `lyricsH` clamp 到 0，歌词不可见 |
| P2 | 600px 断点不适配 | `main_scaffold.dart:281` | 小窗 400px 宽触发底部栏布局，但高度不够 |
| P2 | 导航栏 padding 剥离 | `main_scaffold.dart:371-376` | `MediaQuery.removePadding` 在小窗下可能导致手势区对齐异常 |
| P2 | 宽布局迷你播放器无底部偏移 | `main_scaffold.dart:470-473` | `Align(bottomCenter)` 没加 `mq.padding.bottom`，可能和系统手势区重叠 |
| P3 | 控件高度魔数 145px | `player_page.dart:444` | `controlsH` 不随窗口缩放，小窗下定位偏移 |
| P3 | 队列面板 85% 高度 | `queue_sheet.dart:187` | 小窗 200px 时仅 170px，列表项几乎无法显示 |

### 修复方向

1. **底部常量改为动态计算**：`kFloatingNavHeight` 和 `kMiniPlayerClearance` 应基于 `MediaQuery` 动态调整，或在小窗模式下缩减
2. **播放页布局兜底**：`freeH0` 归零时切换到紧凑布局（封面缩小、控件下沉）
3. **封面尺寸自适应**：去掉 `.clamp(180.0, 280.0)` 的最小值限制，或根据窗口高度动态调整
4. **首页 SliverAppBar**：小窗下减小 `expandedHeight`
5. **断点调整**：考虑加入窗口高度判断，小窗强制使用紧凑布局

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

#### 2b. `_coverFallback` — 8文件重复

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

**方案**：提取 `CoverPlaceholder` widget 到 `cover_image.dart`。

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

| 优先级 | 任务 | 收益 |
|--------|------|------|
| 🔴 P0 | 拆分 `player_provider.dart` — 提取 `QueueManager`（队列+shuffle+播放顺序） | 降低God Object风险 |
| 🔴 P0 | 拆分 `player_provider.dart` — 提取 `PlaybackStatsManager`（统计+最近播放+迁移） | 职责分离 |
| 🔴 P0 | 拆分 `player_provider.dart` — 提取 `UrlResolver`（URL解析+音质+缓冲） | 可测试性提升 |
| 🔴 P0 | 提取 `SongActions` mixin — 统一 `_playNext`/`_addToQueue`/`_playAt` + toast | 消除5处重复 |
| 🟡 P1 | 提取 `CoverPlaceholder` 到 `cover_image.dart` | 消除8处重复 |
| 🟡 P1 | 提取 `PlayAllHeader` widget | 消除2处重复 |
| 🟡 P1 | 提取 `ErrorPlaceholder` widget | 消除5处重复 |
| 🟢 P2 | 统一状态管理 — setState派改用Provider | 降低认知负担 |
| 🟢 P2 | 拆分 `player_page.dart` — 进度条/控制区/歌词区分离 | 可读性提升 |
| 🟢 P2 | 拆分 `main_scaffold.dart` — 侧边栏/导航/响应式分离 | 可读性提升 |
