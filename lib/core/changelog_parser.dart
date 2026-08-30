/// CHANGELOG.md 解析器。
///
/// 从 Keep a Changelog 格式的 Markdown 文件中提取各版本的更新日志。
class ChangelogParser {
  ChangelogParser._();

  /// 解析 CHANGELOG.md 内容，返回版本号 -> 更新日志内容的映射。
  ///
  /// 版本号格式为 `0.5.4`（无 v 前缀），`Unreleased` 对应未发布版本。
  /// 返回的 Markdown 内容保留原始格式（含标题和列表）。
  static Map<String, String> parse(String content) {
    final entries = <String, String>{};
    final lines = content.split('\n');

    String? currentVersion;
    final currentContent = StringBuffer();

    for (final line in lines) {
      // 匹配版本标题行: ## [v0.5.4] - 2026-08-25 或 ## [Unreleased]
      final versionMatch = _versionHeaderRegex.firstMatch(line);
      if (versionMatch != null) {
        // 保存上一个版本的内容
        if (currentVersion != null) {
          final text = currentContent.toString().trim();
          if (text.isNotEmpty) {
            entries[currentVersion] = text;
          }
        }
        // 去掉 v/V 前缀
        var rawVersion = versionMatch.group(1)!;
        if (rawVersion.startsWith('v') || rawVersion.startsWith('V')) {
          rawVersion = rawVersion.substring(1);
        }
        currentVersion = rawVersion;
        currentContent.clear();
        // 不添加版本标题行本身，只添加内容
        continue;
      }

      // 跳过分隔线
      if (line.trim() == '---') continue;

      // 跳过文件开头的说明文字
      if (currentVersion == null) continue;

      // 跳过文件末尾的链接定义
      if (line.startsWith('[') && line.contains(']: ')) continue;

      currentContent.writeln(line);
    }

    // 保存最后一个版本
    if (currentVersion != null) {
      final text = currentContent.toString().trim();
      if (text.isNotEmpty) {
        entries[currentVersion] = text;
      }
    }

    return entries;
  }

  /// 从版本号列表中提取介于 [current] 和 [latest] 之间的所有版本日志。
  ///
  /// [changelogEntries] 是 [parse] 返回的映射。
  /// [current] 和 [latest] 应为已规范化的版本号（无 v 前缀，如 `0.5.4`）。
  /// 返回按版本从新到旧排列的 (版本号, 日志内容) 列表。
  static List<(String version, String content)> extractSkipped(
    Map<String, String> changelogEntries,
    String current,
    String latest,
  ) {
    final result = <(String, String)>[];

    // 收集所有版本号并排序
    final versions = changelogEntries.keys.toList();
    _sortVersionsDesc(versions);

    for (final version in versions) {
      if (version == 'Unreleased') {
        // Unreleased 只在 latest 也是 Unreleased 时显示
        if (latest.toLowerCase() == 'unreleased') {
          result.add((version, changelogEntries[version]!));
        }
        continue;
      }

      // 比较版本号：需要在 current 和 latest 之间（不含 current，含 latest）
      if (_isNewer(version, current) &&
          !_isNewer(version, latest)) {
        result.add((version, changelogEntries[version]!));
      }
    }

    return result;
  }

  /// 将版本号列表按语义化版本从新到旧排序。
  static void _sortVersionsDesc(List<String> versions) {
    versions.sort((a, b) {
      // Unreleased 排最前
      if (a == 'Unreleased') return -1;
      if (b == 'Unreleased') return 1;
      return _compareVersions(b, a); // 降序
    });
  }

  /// 比较两个版本号（x.y.z 格式）。
  /// 返回负数表示 a < b，0 表示相等，正数表示 a > b。
  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map(int.tryParse).whereType<int>().toList();
    final bParts = b.split('.').map(int.tryParse).whereType<int>().toList();
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final ai = i < aParts.length ? aParts[i] : 0;
      final bi = i < bParts.length ? bParts[i] : 0;
      if (ai != bi) return ai - bi;
    }
    return 0;
  }

  /// 判断版本号 a 是否比 b 新。
  static bool _isNewer(String a, String b) {
    return _compareVersions(a, b) > 0;
  }

  static final _versionHeaderRegex = RegExp(r'^## \[(.+?)\]');
}
