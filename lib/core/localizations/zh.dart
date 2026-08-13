import 'package:flutter/material.dart';

/// 轻量中文本地化：仅覆盖 Flutter 文本选择工具栏的「复制 / 全选」按钮文案，
/// 其余 Label 沿用英文默认值，避免引入 flutter_localizations 全量语言包。
///
/// 为什么只改这两处：`SelectionArea`/`SelectableText` 的文本选择菜单用的是
/// [AdaptiveTextSelectionToolbar]，其「复制」「全选」按钮文案来自
/// [MaterialLocalizations.copyButtonLabel] / [MaterialLocalizations.selectAllButtonLabel]。
/// 在不接入全局本地化时它们固定显示英文，这里提供一个最小自定义实现修正。
class ZhLocalizations extends DefaultMaterialLocalizations {
  const ZhLocalizations();

  @override
  String get copyButtonLabel => '复制';

  @override
  String get selectAllButtonLabel => '全选';

  /// Android 的选择菜单含「分享」，Windows 桌面不显示该按钮。
  @override
  String get shareButtonLabel => '分享';
}

/// 为任意 locale 提供 [ZhLocalizations]（语言无关，仅修正上图两处文案）。
class ZhLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const ZhLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) async =>
      const ZhLocalizations();

  @override
  bool shouldReload(ZhLocalizationsDelegate old) => false;
}
