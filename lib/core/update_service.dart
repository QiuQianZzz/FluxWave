import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_links.dart';
import 'changelog_parser.dart';
import 'logging/app_log.dart';

/// GitHub Release 更新检测服务。
///
/// 调用 GitHub API 获取最新 release，与本地版本比较，返回 [UpdateInfo]。
/// 支持应用内下载 APK 并触发系统安装。
class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

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
        // 异步获取 CHANGELOG.md，不阻塞更新检测
        final changelogEntries = await _fetchChangelog().timeout(
          const Duration(seconds: 5),
          onTimeout: () => <String, String>{},
        );
        final skippedChangelogs = changelogEntries.isNotEmpty
            ? ChangelogParser.extractSkipped(
                changelogEntries,
                current,
                latestVersion,
              )
            : <(String, String)>[];

        return UpdateInfo(
          currentVersion: currentVersion,
          latestVersion: _stripVersionPrefix(release.tagName),
          releaseNotes: release.body,
          releaseUrl: release.htmlUrl,
          downloadUrl: release.downloadUrl,
          sha256Url: release.sha256Url,
          publishedAt: release.publishedAt,
          isPrerelease: release.isPrerelease,
          changelogEntries: changelogEntries,
          skippedChangelogs: skippedChangelogs,
        );
      }
      return null;
    } catch (e, st) {
      AppLog.warn('更新检查失败', tag: 'update', error: e, stack: st);
      return null;
    }
  }

  String? _tempDir;

  Future<String> _getTempDir() async {
    _tempDir ??= (await getTemporaryDirectory()).path;
    return _tempDir!;
  }

  /// 检查是否已有指定版本的下载好的 APK 文件。
  Future<bool> hasDownloadedApk(String version) async {
    final dir = await _getTempDir();
    final file = File('$dir/fluxwave_${_normalizeVersion(version)}.apk');
    if (!await file.exists()) return false;
    final size = await file.length();
    return size > 0;
  }

  /// 下载 APK 文件到临时目录。返回文件路径。
  ///
  /// 如果已存在有效的下载文件，直接返回路径（跳过重复下载）。
  /// [forceReDownload] 为 true 时强制重新下载。
  /// [onProgress] 回调下载进度（0.0 ~ 1.0）。
  Future<String> downloadApk(
    String url, {
    String? version,
    bool forceReDownload = false,
    Function(double progress)? onProgress,
  }) async {
    final dir = await _getTempDir();
    final v = version != null ? _normalizeVersion(version) : 'latest';
    final filePath = '$dir/fluxwave_$v.apk';
    final file = File(filePath);

    // 文件已存在且不强制重下：跳过下载，直接返回
    if (!forceReDownload && await file.exists()) {
      final size = await file.length();
      if (size > 0) {
        onProgress?.call(1.0);
        return filePath;
      }
    }

    // 删除旧的下载文件（删不掉不影响后续写入）
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }

    // 清理其他版本的旧 APK 文件（失败不影响下载）
    final dirObj = Directory(dir);
    if (await dirObj.exists()) {
      await for (final entity in dirObj.list()) {
        if (entity is File &&
            entity.path.startsWith('$dir/fluxwave_') &&
            entity.path.endsWith('.apk') &&
            entity.path != filePath) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
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
      final request = await client.getUrl(Uri.parse(AppLinks.kLatestReleaseApiUrl));
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
        Uri.parse('${AppLinks.kReleasesApiUrl}?per_page=10'),
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

  /// 从版本号字符串中提取可比较的版本号（去掉 v 前缀和预发布后缀）。
  String _normalizeVersion(String version) {
    var v = _stripVersionPrefix(version);
    // 去掉预发布后缀（-beta.1, -rc.2 等）只比较主版本号
    final dashIndex = v.indexOf('-');
    if (dashIndex != -1) v = v.substring(0, dashIndex);
    return v;
  }

  /// 从 GitHub 获取 CHANGELOG.md 并解析。
  Future<Map<String, String>> _fetchChangelog() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(Uri.parse(AppLinks.kChangelogUrl));
        request.headers.set('User-Agent', 'FluxWave/1.0');
        request.headers.set('Cache-Control', 'no-cache');
        final response = await request.close();
        if (response.statusCode != 200) return {};
        final body = await response.transform(utf8.decoder).join();
        return ChangelogParser.parse(body);
      } finally {
        client.close();
      }
    } catch (e, st) {
      AppLog.warn('获取 CHANGELOG 失败', tag: 'update', error: e, stack: st);
      return {};
    }
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

  /// 计算文件的 SHA256 哈希值（小写十六进制）。
  Future<String> computeFileSha256(String filePath) async {
    final file = File(filePath);
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }

  /// 从 GitHub 获取期望的 SHA256 哈希值。
  ///
  /// [sha256Url] 指向 .sha256 文件（内容格式为 `<hash>  <filename>` 或纯 hash）。
  Future<String?> fetchExpectedSha256(String sha256Url) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(Uri.parse(sha256Url));
        request.headers.set('User-Agent', 'FluxWave/1.0');
        final response = await request.close();
        if (response.statusCode != 200) return null;
        final body = await response.transform(utf8.decoder).join();
        // 支持两种格式：
        // 1. 纯哈希: "a1b2c3..."
        // 2. 标准格式: "a1b2c3...  fluxwave_0.5.5.apk"
        final line = body.trim().split('\n').first.trim();
        final hash = line.split(RegExp(r'\s+')).first.trim().toLowerCase();
        // 校验是否为 64 位十六进制字符串
        if (hash.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
          return hash;
        }
        return null;
      } finally {
        client.close();
      }
    } catch (e, st) {
      AppLog.warn('获取 SHA256 失败', tag: 'update', error: e, stack: st);
      return null;
    }
  }

  /// 校验文件 SHA256。返回 null 表示校验通过，否则返回错误信息。
  ///
  /// [expectedHash] 为 null 表示无校验文件（跳过校验）；
  /// 为空字符串表示校验文件内容无效（视为失败）。
  Future<String?> verifySha256({
    required String filePath,
    required String? expectedHash,
  }) async {
    if (expectedHash == null) {
      return null; // 无校验文件，跳过校验
    }

    if (expectedHash.isEmpty) {
      return 'SHA256 校验文件内容无效';
    }

    final actualHash = await computeFileSha256(filePath);
    if (actualHash != expectedHash) {
      // 校验失败，删除已下载文件
      try {
        await File(filePath).delete();
      } catch (_) {}
      return 'SHA256 校验失败：文件可能已损坏或被篡改\n期望：$expectedHash\n实际：$actualHash';
    }
    return null;
  }
}

/// 更新信息。
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String? releaseNotes;
  final String releaseUrl;
  final String? downloadUrl;
  final String? sha256Url;
  final String? publishedAt;
  final bool isPrerelease;

  /// CHANGELOG.md 解析后的全部版本日志映射。
  final Map<String, String> changelogEntries;

  /// 跳过的版本日志列表（从新到旧），每个元素为 (版本号, 日志内容)。
  final List<(String version, String content)> skippedChangelogs;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    this.releaseNotes,
    required this.releaseUrl,
    this.downloadUrl,
    this.sha256Url,
    this.publishedAt,
    this.isPrerelease = false,
    this.changelogEntries = const {},
    this.skippedChangelogs = const [],
  });

  /// 是否有可下载的 APK 资源。
  bool get hasDownload => downloadUrl != null && downloadUrl!.isNotEmpty;

  /// 是否有 SHA256 校验文件。
  bool get hasSha256 => sha256Url != null && sha256Url!.isNotEmpty;

  /// 是否有来自 CHANGELOG.md 的更新日志。
  bool get hasChangelog => skippedChangelogs.isNotEmpty;

  /// 跳过的版本数量。
  int get skippedVersionCount => skippedChangelogs.length;
}

/// GitHub Release API 响应的最小解析。
class _GitHubRelease {
  final String tagName;
  final String? body;
  final String htmlUrl;
  final String? publishedAt;
  final bool isPrerelease;
  final String? downloadUrl;
  final String? sha256Url;

  const _GitHubRelease({
    required this.tagName,
    this.body,
    required this.htmlUrl,
    this.publishedAt,
    this.isPrerelease = false,
    this.downloadUrl,
    this.sha256Url,
  });

  factory _GitHubRelease.fromJson(Map<String, dynamic> json) {
    // 从 assets 中查找 APK 和 SHA256 校验文件的下载链接
    String? apkUrl;
    String? sha256Url;
    final assets = json['assets'] as List?;
    if (assets != null) {
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        final lowerName = name.toLowerCase();
        if (lowerName.endsWith('.apk')) {
          apkUrl = asset['browser_download_url'] as String?;
        } else if (lowerName.endsWith('.sha256')) {
          sha256Url = asset['browser_download_url'] as String?;
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
      sha256Url: sha256Url,
    );
  }
}
