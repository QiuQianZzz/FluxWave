import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'logging/app_log.dart';

/// GitHub Release 更新检测服务。
///
/// 调用 GitHub API 获取最新 release，与本地版本比较，返回 [UpdateInfo]。
/// 不做自动下载，仅提供 release 页面链接供用户手动下载。
class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

  static const _owner = 'QiuQianZzz';
  static const _repo = 'FluxWave';
  static const _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// 检查是否有新版本。返回 null 表示已是最新或检查失败。
  Future<UpdateInfo?> check() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final release = await _fetchLatestRelease();
      if (release == null) return null;

      final latestVersion = _normalizeVersion(release.tagName);
      final current = _normalizeVersion(currentVersion);

      if (_isNewer(latestVersion, current)) {
        return UpdateInfo(
          currentVersion: currentVersion,
          latestVersion: _stripVersionPrefix(release.tagName),
          releaseNotes: release.body,
          releaseUrl: release.htmlUrl,
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

  /// 获取最新 release 信息。
  Future<_GitHubRelease?> _fetchLatestRelease() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(_apiUrl));
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'FluxWave/1.0');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return _GitHubRelease.fromJson(json);
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
  final String? publishedAt;
  final bool isPrerelease;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    this.releaseNotes,
    required this.releaseUrl,
    this.publishedAt,
    this.isPrerelease = false,
  });
}

/// GitHub Release API 响应的最小解析。
class _GitHubRelease {
  final String tagName;
  final String? body;
  final String htmlUrl;
  final String? publishedAt;
  final bool isPrerelease;

  const _GitHubRelease({
    required this.tagName,
    this.body,
    required this.htmlUrl,
    this.publishedAt,
    this.isPrerelease = false,
  });

  factory _GitHubRelease.fromJson(Map<String, dynamic> json) =>
      _GitHubRelease(
        tagName: json['tag_name'] as String? ?? '',
        body: json['body'] as String?,
        htmlUrl: json['html_url'] as String? ?? '',
        publishedAt: json['published_at'] as String?,
        isPrerelease: json['prerelease'] as bool? ?? false,
      );
}
