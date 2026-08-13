import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 网易云封面图：统一处理 CDN 的访问要求。
///
/// 网易云图片 CDN 对缺浏览器 UA 的请求返回 403。实测：
/// - `Image.network`（Flutter 引擎 `NetworkImage`）即使传 `headers` 也被
///   拒 403（引擎对 UA 处理不可控）；
/// - 自己用 dart:io `HttpClient` + Chrome UA + Referer 直连 → 稳定 200。
///
/// 故本组件自己下载字节（`Image.memory` 渲染），并做进程内 LRU 缓存：
/// 1. `http://` 升级 `https://`（服务端 https 也可访问）；
/// 2. 追加 `User-Agent`(Chrome) + `Referer: https://music.163.com/`；
/// 3. 失败兜底 [placeholder]。
class CoverImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final Widget? placeholder;
  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  static const Map<String, String> cdnHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'Referer': 'https://music.163.com/',
  };

  /// 规范化图片 URL：空 → null；http 升 https；带 param 不变。
  static String? normalize(String? u) {
    if (u == null || u.isEmpty) return null;
    if (u.startsWith('http://')) return 'https://${u.substring(7)}';
    return u;
  }

  /// 取封面字节：命中进程内缓存直接返回，否则按 CDN 要求下载并缓存。
  /// 失败返回 null。供取色等非渲染用途复用下载/缓存逻辑。
  static Future<Uint8List?> fetchBytes(String? rawUrl) async {
    final fitted = normalize(rawUrl);
    if (fitted == null) return null;
    final cached = CoverImageCache.instance.get(fitted);
    if (cached != null) return cached;
    try {
      final bytes = await _download(fitted);
      CoverImageCache.instance.put(fitted, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _download(String url) async {
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse(url));
      CoverImage.cdnHeaders.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      // 用 BytesBuilder 收集响应块：避免 `[...a, ...b]` 每次新建列表并全量
      // 复制已累计字节（大图时分块多时 O(n²)，此处一次转换 O(n)）。
      final builder = BytesBuilder(copy: false);
      await res.forEach(builder.add);
      return builder.takeBytes();
    } finally {
      http.close(force: true);
    }
  }

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final bytes = await CoverImage.fetchBytes(widget.url);
    if (!mounted) return;
    if (bytes != null) {
      setState(() => _bytes = bytes);
    } else {
      setState(() {}); // 失败：build 走 placeholder 兜底
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: widget.fit, gaplessPlayback: true);
    }
    return widget.placeholder ??
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        );
  }
}

/// 进程内图片字节缓存：真 LRU（LinkedHashMap 键序即访问序）。
///
/// - [get] 命中后把 key 移到末尾（最近使用）；
/// - [put] 存在则先移除再重插（同样视为最新访问）；
/// - 超上限删除头部（最久未使用）。上限 256 项。
class CoverImageCache {
  CoverImageCache._();
  static final CoverImageCache instance = CoverImageCache._();

  static const _maxEntries = 256;
  // 显式 LinkedHashMap：键序 = 插入序 = 访问序（LRU 依赖）。
  final Map<String, Uint8List> _map = <String, Uint8List>{};

  Uint8List? get(String key) {
    final value = _map[key];
    if (value != null) {
      // 命中即提升为最近使用，保证淘汰是"最久未使用"而非"最老插入"。
      _map.remove(key);
      _map[key] = value;
    }
    return value;
  }

  void put(String key, Uint8List bytes) {
    if (_map.containsKey(key)) {
      _map.remove(key);
    }
    _map[key] = bytes;
    while (_map.length > _maxEntries) {
      _map.remove(_map.keys.first);
    }
  }
}
