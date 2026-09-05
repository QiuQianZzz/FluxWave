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

---

## 导航架构重构

### 一、问题概述

当前导航架构存在多个结构性问题，核心矛盾是 **播放页在根 Navigator 上，而各 Tab 有独立的嵌套 Navigator**，导致：

1. **Android 返回手势冲突**：播放页打开时，嵌套 Navigator 的 `PopScope` 仍然注册在 widget 树中，优先拦截手势，播放页无法通过返回手势关闭
2. **跨 Navigator 通信依赖静态回调**：`ArtistNavigation.onNavigateToArtist` 和 `AlbumNavigation.onNavigateToAlbum` 使用全局可变静态字段，存在竞态条件和紧耦合
3. **TabNavigator + NavigatorPopHandler 复杂度高**：`PopScope` 注册顺序、`enabled` 状态传递、`Offstage` 常驻时的 PopScope 抑制等，逻辑脆弱且难维护
4. **导航入口不一致**：Settings 用 `PopScope` + 状态切换，其他 Tab 用 Navigator push，LogListPage 直接 `Navigator.of(context).push` 可能推到错误的 Navigator
5. **Tab 切换时的路由栈管理复杂**：每个 Tab 的 Navigator 用 `GlobalKey` 保持状态，`Offstage` 常驻，`NavigatorPopHandler` 的 `enabled` 控制等

### 二、行业最佳实践

Android 音乐播放器的导航架构普遍采用以下模式：

| 模式 | 说明 | 优势 |
|------|------|------|
| **播放页作为叠加层** | 播放页不放在任何导航栈上，而是用状态变量控制的 `AnimatedVisibility`/`Stack` 叠加层 | 完全避免返回手势冲突，独立于导航状态 |
| **状态机管理详情页** | Tab 内详情页用 sealed class + 状态切换管理，不依赖嵌套 Navigator | 简化返回手势处理，独立管理每个 Tab 的详情栈 |
| **BackHandler 优先级栈** | 返回手势按 widget 树渲染顺序自然形成优先级，最上层的 handler 先处理 | 无需手动协调，天然正确 |
| **集中式导航管理** | 所有导航逻辑集中在顶层 widget，不通过全局静态回调 | 消除竞态条件，易于理解和维护 |

### 三、重构方案

#### Phase 1：播放页改为叠加层（解决返回手势冲突）

**目标**：将 PlayerPage 从根 Navigator 路由改为状态控制的叠加层，彻底消除返回手势冲突。

**当前架构**：
```
MiniPlayer → Navigator.of(context).push(PlayerPage) → 根 Navigator
返回手势 → 嵌套 Navigator PopScope 拦截 → 手势无法到达根 Navigator
```

**新架构**：
```
MainScaffold._showPlayer = true → Stack 中渲染 PlayerPage（叠加层）
返回手势 → PlayerPage 内 PopScope 直接处理 → 关闭播放页
```

**具体改动**：

| 文件 | 改动 |
|------|------|
| `main_scaffold.dart` | 添加 `bool _showPlayer = false`；在 Stack 顶层条件渲染 `PlayerPage`；添加 `PopScope` 拦截返回手势 |
| `mini_player.dart` | `_openPlayer` 改为调用回调，不再 `Navigator.push` |
| `tab_navigator.dart` | 移除 `isPlayerOpen` 相关逻辑（如有） |
| `player_page.dart` | 关闭按钮改为调用回调（如 `onClose`），不再 `Navigator.of(context).pop()` |

**MainScaffold Stack 层级**（从底到顶）：
```
Stack
  ├─ Scaffold（tab 内容 + 导航栏）
  ├─ MiniPlayer（底部悬浮）
  ├─ PlayerPage（条件渲染，fillMaxSize，slide-in 动画）
  └─ ToastOverlay
```

**返回手势处理**：
```dart
// main_scaffold.dart
PopScope(
  canPop: !_showPlayer,
  onPopInvokedWithResult: (didPop, _) {
    if (!didPop && _showPlayer) {
      setState(() => _showPlayer = false);
    }
  },
  child: Stack(
    children: [
      // ... tab content, mini player ...
      if (_showPlayer)
        PlayerPage(onClose: () => setState(() => _showPlayer = false)),
    ],
  ),
)
```

**收益**：
- 彻底消除播放页与嵌套 Navigator 的返回手势冲突
- 移除 `isPlayerOpen` 状态在 MiniPlayer → MainScaffold → 4 个 TabNavigator 之间的传递链
- 移除 TabNavigator 中条件渲染 NavigatorPopHandler 的复杂逻辑
- 播放页打开/关闭不再影响 Tab 的导航行为

#### Phase 2：移除嵌套 Navigator，改用状态机管理 Tab 内详情

**目标**：每个 Tab 用状态机 + `AnimatedSwitcher` 管理详情页，移除嵌套 Navigator。

**当前架构**：
```
TabNavigator
  └─ NavigatorPopHandler
      └─ Navigator
          └─ HomePage → push(PlaylistDetailPage)
```

**新架构**：
```
TabContent（state machine）
  ├─ state=list → HomePage
  └─ state=detail → PlaylistDetailPage
```

**具体改动**：

| 文件 | 改动 |
|------|------|
| `tab_navigator.dart` | **删除整个文件**（或重写为简单的状态机容器） |
| `main_scaffold.dart` | 移除 `_tabNavKeys`（GlobalKey 列表）和 `_tabObservers`；每个 Tab 改为状态机容器 |
| `home_page.dart` | 添加 `_selectedDetail` 状态；详情页 push 改为状态切换 |
| `search_page.dart` | 同上 |
| `profile_page.dart` | 同上 |
| `settings_page.dart` | 已经是状态机模式，保持不变 |

**状态机模式**（以 HomePage 为例）：
```dart
class HomePage extends StatefulWidget {
  // detailPage: 从 MainScaffold 传入，或由 HomePage 内部管理
}

class _HomePageState extends State<HomePage> {
  Widget? _detailPage;

  void _openDetail(Widget page) {
    setState(() => _detailPage = page);
  }

  void _closeDetail() {
    setState(() => _detailPage = null);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Duration(milliseconds: 300),
      child: _detailPage ?? widget.child,
    );
  }
}
```

**返回手势处理**：
```dart
// 在每个 Tab 内容页中
PopScope(
  canPop: _detailPage == null,
  onPopInvokedWithResult: (didPop, _) {
    if (!didPop) _closeDetail();
  },
  child: AnimatedSwitcher(...),
)
```

**迁移策略**：
- 分阶段迁移：先 HomePage，再 SearchPage，再 ProfilePage
- 每个阶段独立可测试
- 保持 `AppNav.push()` 接口不变，内部改为状态切换

**收益**：
- 移除 `NavigatorPopHandler`、`Navigator.of(context, rootNavigator: true)`、`GlobalKey<NavigatorState>` 等复杂机制
- 消除 `Offstage` 常驻时 PopScope 注册/抑制的边界问题
- 每个 Tab 独立管理自己的详情栈，互不干扰
- 更容易实现自定义过渡动画
- 更容易保存/恢复滚动位置

#### Phase 3：消除跨 Navigator 静态回调

**目标**：移除 `ArtistNavigation` 和 `AlbumNavigation` 静态回调，改为直接导航。

**当前问题**：
```
PlayerPage（根 Navigator）→ ArtistNavigation.onNavigateToArtist → MainScaffold._navigateToArtistFromPlayer → pop 根 Navigator + push 到 Tab Navigator
```

**新方案**：PlayerPage 改为叠加层后，点击歌手/专辑直接在 MainScaffold 中处理：

```dart
// main_scaffold.dart
void _onPlayerNavigateToArtist(int id, String name) {
  setState(() {
    _showPlayer = false;  // 关闭播放页
    _detailPage = ArtistDetailPage(artistId: id, artistName: name);  // 显示歌手页
    // 可选：切换到相关 Tab
  });
}
```

| 文件 | 改动 |
|------|------|
| `artist_navigation.dart` | **删除整个文件** |
| `album_navigation.dart` | **删除整个文件** |
| `player_page.dart` | 歌手/专辑点击改为调用回调 `onNavigateToArtist`/`onNavigateToAlbum` |
| `main_scaffold.dart` | 直接处理导航，不再通过静态回调 |
| `artist_detail_page.dart` | 专辑点击改为回调（不再依赖 `AlbumNavigation`） |
| `album_detail_page.dart` | 歌手点击改为回调（不再依赖 `ArtistNavigation`） |

**收益**：
- 消除全局可变状态和竞态条件
- 导航逻辑集中在 MainScaffold，更容易理解和维护
- PlayerPage 不再依赖 MainScaffold 设置回调

#### Phase 4：统一导航入口

**目标**：统一所有详情页的导航方式。

| 当前方式 | 统一后 | 涉及文件 |
|----------|--------|----------|
| `AppNav.push()` → Tab Navigator | 状态切换 | home_page, profile_page, radar_page |
| `Navigator.of(context).push()` → 可能错误的 Navigator | 状态切换 | about_section, log_list_page |
| `AppNav.pushNamedGlobal()` → 根 Navigator | 保留（登录页确实需要全屏） | 多个文件 |
| Settings 内部 `PopScope` + 状态 | 已是正确模式 | settings_page |

**收益**：
- 消除导航入口不一致问题
- 避免 `Navigator.of(context)` 在不同上下文中解析到不同 Navigator
- 所有详情页导航路径统一，更容易添加过渡动画

#### Phase 5：增强返回手势体验

**目标**：实现平滑的预测性返回动画。

**当前状态**：
- Flutter 的 `PredictiveBackPageTransitionsBuilder` 已支持 Android 预测性返回
- `PredictiveBackGesture` widget 已实现底部弹窗的预测性关闭
- 但 Tab 内详情页的返回动画是简单的 `MaterialPageRoute` 过渡

**改进方案**：
- Tab 内详情页使用自定义 `PageRoute`，支持预测性返回的缩放+淡出动画
- 播放页使用从底部滑出的动画（已有），关闭时反向

| 文件 | 改动 |
|------|------|
| `app_nav.dart` | `TabAwarePageRoute` 改为支持预测性返回动画 |
| 新文件 `lib/core/navigation/detail_page_route.dart` | 自定义详情页路由，支持缩放+淡出过渡 |

### 四、迁移计划

| 阶段 | 任务 | 优先级 | 预估工作量 | 依赖 |
|------|------|--------|-----------|------|
| Phase 1a | PlayerPage 改为叠加层（最小可用） | 🔴 P0 | 2-3h | 无 | ✅ 已完成 |
| Phase 1b | 清理 isPlayerOpen 传递链 | 🔴 P0 | 1h | Phase 1a | ✅ 已完成 |
| Phase 1c | 移除 TabNavigator 中的条件渲染逻辑 | 🔴 P0 | 0.5h | Phase 1b | ✅ 已完成 |
| Phase 2a | HomePage 改为状态机详情管理 | 🔴 P0 | 2-3h | Phase 1 | 待完成 |
| Phase 2b | ProfilePage 改为状态机 | 🟡 P1 | 2h | Phase 2a | 待完成 |
| Phase 2c | SearchPage 改为状态机 | 🟡 P1 | 1h | Phase 2a | 待完成 |
| Phase 2d | 删除 TabNavigator 文件 | 🟡 P1 | 0.5h | Phase 2a-c | 待完成 |
| Phase 3 | 消除静态回调 | 🟡 P1 | 2h | Phase 1a | 待完成 |
| Phase 4 | 统一导航入口 | 🟢 P2 | 2h | Phase 2 | 部分完成（about_section, log_list_page, main_scaffold 已统一为 AppNav.push/route） |
| Phase 5 | 增强返回手势动画 | 🟢 P2 | 3-4h | Phase 2 | 待完成 |

### 五、验证清单

每个阶段完成后需验证：

- [x] Android 真机：播放页打开时返回手势能关闭播放页
- [x] Android 真机：播放页打开 + 歌单详情页打开时，返回手势只关闭播放页
- [x] Android 真机：播放页关闭后，返回手势能关闭歌单详情页
- [x] Android 真机：预测性返回手势动画正常
- [x] Tab 切换后返回手势作用于正确的 Tab
- [x] 从播放页点击歌手/专辑能正确跳转
- [ ] 非活跃 Tab 的返回手势不干扰当前 Tab（待验证）
- [ ] Windows 桌面模式下所有导航正常（待验证）
- [ ] 热重载后导航状态保持（待验证）
- [ ] 进程恢复后导航状态保持（待验证）
