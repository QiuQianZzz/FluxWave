import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../constants/app_links.dart';
import 'logging/app_log.dart';

/// GitHub 贡献者信息。
class Contributor {
  final String login;
  final String avatarUrl;
  final String htmlUrl;
  final int contributions;

  const Contributor({
    required this.login,
    required this.avatarUrl,
    required this.htmlUrl,
    required this.contributions,
  });

  factory Contributor.fromJson(Map<String, dynamic> json) {
    return Contributor(
      login: json['login'] as String? ?? '',
      avatarUrl: json['avatar_url'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      contributions: json['contributions'] as int? ?? 0,
    );
  }
}

/// 贡献者服务：从 GitHub API 拉取贡献者列表，内存缓存。
///
/// - 无 Token 限流 60 次/小时，对个人项目足够。
/// - 同一 app 生命周期内只请求一次（内存缓存）。
/// - 数据有几小时的 GitHub 侧缓存，无需频繁刷新。
class ContributorService {
  ContributorService._();

  static final instance = ContributorService._();

  /// 内存缓存：app 生命周期内有效。
  List<Contributor>? _cache;

  /// 正在加载时的 completer，防止并发重复请求。
  Completer<List<Contributor>>? _loading;

  /// 获取贡献者列表。
  ///
  /// [maxCount] 最多返回的数量，默认 10。
  /// 有缓存时直接返回，无缓存时发起请求。
  Future<List<Contributor>> getContributors({int maxCount = 10}) async {
    // 有缓存直接返回
    if (_cache != null) {
      return _cache!.take(maxCount).toList();
    }

    // 正在加载中，等待结果
    if (_loading != null) {
      final result = await _loading!.future;
      return result.take(maxCount).toList();
    }

    // 发起新请求
    _loading = Completer<List<Contributor>>();
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(
          Uri.parse(AppLinks.kContributorsApiUrl),
        );
        request.headers.set('Accept', 'application/vnd.github.v3+json');
        request.headers.set('User-Agent', 'FluxWave/1.0');
        final response = await request.close();

        if (response.statusCode != 200) {
          throw HttpException(
            'GitHub API 请求失败: HTTP ${response.statusCode}',
            uri: Uri.parse(AppLinks.kContributorsApiUrl),
          );
        }

        final body = await response.transform(utf8.decoder).join();
        final list = jsonDecode(body) as List;
        final contributors = list
            .whereType<Map<String, dynamic>>()
            .map(Contributor.fromJson)
            .toList();

        _cache = contributors;
        _loading!.complete(contributors);
        return contributors.take(maxCount).toList();
      } finally {
        client.close();
      }
    } catch (e, st) {
      AppLog.warn(
        '获取贡献者列表失败',
        tag: 'contributor',
        error: e,
        stack: st,
      );
      _loading!.complete([]);
      return [];
    } finally {
      _loading = null;
    }
  }
}
