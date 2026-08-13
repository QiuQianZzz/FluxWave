/// 可选的桌面图标定义。
///
/// 约定（详见 tool/generate_app_icons.ps1 与 AndroidManifest.xml）：
/// - [id] 必须是合法 Java 标识符（字母/数字/下划线），用于 Android 资源名与
///   activity-alias 名（`LauncherIcon_<id>`）。
/// - 列表第一个为**默认图标**：Windows 等不支持运行时切换的平台固定使用它。
/// - Android 资源：默认图标用框架约定的 `@mipmap/ic_launcher`；其余用
///   `@mipmap/app_icon_<id>`（由脚本生成）。
/// - 预览图：`assets/icon/previews/preview_<id>.png`（Flutter asset，
///   pubspec 已声明整个 previews/ 目录，新增文件无需改 pubspec）。
class AppIconOption {
  final String id;
  final String label;
  final String previewAsset;

  const AppIconOption({
    required this.id,
    required this.label,
    required this.previewAsset,
  });
}

/// 全部可选桌面图标。新增图标时在此追加一项，并按约定放置资源。
const appIconOptions = <AppIconOption>[
  AppIconOption(
    id: 'default',
    label: '默认图标',
    previewAsset: 'assets/icon/previews/preview_default.png',
  ),
  AppIconOption(
    id: 'alt',
    label: '备选图标',
    previewAsset: 'assets/icon/previews/preview_alt.png',
  ),
];

/// 按 [id] 取图标选项；未知 id 回退到默认图标（列表首项）。
AppIconOption appIconOptionFor(String id) => appIconOptions.firstWhere(
  (o) => o.id == id,
  orElse: () => appIconOptions.first,
);
