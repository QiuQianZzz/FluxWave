import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 返回 application support 目录下指定子目录（`logs` / `crash` / `audio_cache` 等）。
///
/// 路径统一走这里，避免各模块各自手拼 `pathSeparator` 字符串造成散布常量。
Future<Directory> appSupportDir(String name) async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}${Platform.pathSeparator}$name');
}
