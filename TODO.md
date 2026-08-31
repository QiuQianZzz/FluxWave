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
