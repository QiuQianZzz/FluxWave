import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'logging/app_log.dart';

/// GitHub Release 更新检测服务。
///
/// 调用 GitHub API 获取最新 release，与本地版本比较，返回 [UpdateInfo]。
/// 支持应用内下载 APK 并触发系统安装。
class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

  static const _owner = 'QiuQianZzz';
  static const _repo = 'FluxWave';
  static const _latestUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';
  static const _releasesUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases';

  /// 检查是否有新版本。返回 null 表示已是最新或检查失败。
  ///
  /// [includeBeta] 为 true 时检查所有 release（含预发布），
  /// 为 false 时只检查正式版。
  Future<UpdateInfo?> check({bool includeBeta = false}) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final release = includeBeta
          ? await _fetchLatestIncludingPrerelease()
          : await _fetchLatestStable();
      if (release == null) return null;

      final latestVersion = _normalizeVersion(release.tagName);
      final current = _normalizeVersion(currentVersion);

      if (_isNewer(latestVersion, current)) {
        return UpdateInfo(
          currentVersion: currentVersion,
          latestVersion: _stripVersionPrefix(release.tagName),
          releaseNotes: release.body,
          releaseUrl: release.htmlUrl,
          downloadUrl: release.downloadUrl,
          publishedAt: release.publishedAt,
          isPrerelease: release.isPrerelease,
        );
      }
      return null;
    } catch (e, st) {
      AppLog.warn('更新检查失败', tag: 'update', error: e, stack: st);
      return null;
    }
  }

  /// 下载 APK 文件到临时目录。返回文件路径。
  ///
  /// [onProgress] 回调下载进度（0.0 ~ 1.0）。
  /// 下载过程中会频繁回调，UI 层应节流更新（建议 ≥100ms 间隔）。
  Future<String> downloadApk(
    String url, {
    Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/fluxwave_update.apk';
    final file = File(filePath);

    // 删除旧的下载文件
    if (await file.exists()) {
      await file.delete();
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'FluxWave/1.0');
      request.headers.set('Cache-Control', 'no-cache');
      final response = await request.close();

      if (response.statusCode != 200) {
        throw HttpException(
          '下载失败: HTTP ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }

      final totalBytes = response.contentLength;
      var receivedBytes = 0;

      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call(receivedBytes / totalBytes);
        }
      }
      await sink.flush();
      await sink.close();

      return filePath;
    } finally {
      client.close();
    }
  }

  /// 获取最新正式版 release。
  Future<_GitHubRelease?> _fetchLatestStable() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(_latestUrl));
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'FluxWave/1.0');
      request.headers.set('Cache-Control', 'no-cache');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return _GitHubRelease.fromJson(json);
    } finally {
      client.close();
    }
  }

  /// 获取最新 release（含预发布）：拉取最近 10 条，取第一条。
  Future<_GitHubRelease?> _fetchLatestIncludingPrerelease() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.parse('$_releasesUrl?per_page=10'),
      );
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'FluxWave/1.0');
      request.headers.set('Cache-Control', 'no-cache');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List;
      if (list.isEmpty) return null;
      return _GitHubRelease.fromJson(list.first as Map<String, dynamic>);
    } finally {
      client.close();
    }
  }

  /// 从版本字符串中提取可比较的版本号（去掉 v 前缀和预发布后缀）。
  String _normalizeVersion(String version) {
    var v = _stripVersionPrefix(version);
    // 去掉预发布后缀（-beta.1, -rc.2 等）只比较主版本号
    final dashIndex = v.indexOf('-');
    if (dashIndex != -1) v = v.substring(0, dashIndex);
    return v;
  }

  /// 去掉版本号的 v/V 前缀。
  String _stripVersionPrefix(String version) {
    var v = version.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    return v;
  }

  /// 比较两个版本号（x.y.z 格式），返回 true 表示 a > b。
  bool _isNewer(String a, String b) {
    final aParts = a.split('.').map(int.tryParse).whereType<int>().toList();
    final bParts = b.split('.').map(int.tryParse).whereType<int>().toList();
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final ai = i < aParts.length ? aParts[i] : 0;
      final bi = i < bParts.length ? bParts[i] : 0;
      if (ai > bi) return true;
      if (ai < bi) return false;
    }
    return false;
  }
}

/// 更新信息。
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String? releaseNotes;
  final String releaseUrl;
  final String? downloadUrl;
  final String? publishedAt;
  final bool isPrerelease;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    this.releaseNotes,
    required this.releaseUrl,
    this.downloadUrl,
    this.publishedAt,
    this.isPrerelease = false,
  });

  /// 是否有可下载的 APK 资源。
  bool get hasDownload => downloadUrl != null && downloadUrl!.isNotEmpty;
}

/// GitHub Release API 响应的最小解析。
class _GitHubRelease {
  final String tagName;
  final String? body;
  final String htmlUrl;
  final String? publishedAt;
  final bool isPrerelease;
  final String? downloadUrl;

  const _GitHubRelease({
    required this.tagName,
    this.body,
    required this.htmlUrl,
    this.publishedAt,
    this.isPrerelease = false,
    this.downloadUrl,
  });

  factory _GitHubRelease.fromJson(Map<String, dynamic> json) {
    // 从 assets 中查找 APK 文件的下载链接
    String? apkUrl;
    final assets = json['assets'] as List?;
    if (assets != null) {
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.apk')) {
          apkUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
    }

    return _GitHubRelease(
      tagName: json['tag_name'] as String? ?? '',
      body: json['body'] as String?,
      htmlUrl: json['html_url'] as String? ?? '',
      publishedAt: json['published_at'] as String?,
      isPrerelease: json['prerelease'] as bool? ?? false,
      downloadUrl: apkUrl,
    );
  }
}
