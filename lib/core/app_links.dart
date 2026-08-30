/// 应用级外部链接的统一出口。
///
/// 所有指向 GitHub / 文档站 / LICENSE 等外部资源的 URL 集中在此，
/// 避免散落各处导致维护困难。
class AppLinks {
  AppLinks._();

  // ── GitHub ──

  static const githubOwner = 'QiuQianZzz';
  static const githubRepo = 'FluxWave';

  /// 仓库主页。
  static const kGitHubRepoUrl =
      'https://github.com/$githubOwner/$githubRepo';

  /// LICENSE 文件的 raw 内容地址（main 分支）。
  static const kLicenseUrl =
      'https://raw.githubusercontent.com/$githubOwner/$githubRepo/main/LICENSE';

  /// GitHub API：最新 release（正式版）。
  static String get kLatestReleaseApiUrl =>
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

  /// GitHub API：releases 列表（含预发布）。
  static String get kReleasesApiUrl =>
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases';

  // ── 文档 ──

  /// 项目文档站。
  static const kDocsUrl = 'https://fluxwave.docs.jodex.cn/';
}
