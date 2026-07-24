/// Product brand (fork of Venera → light novel desktop).
const appBrandName = 'Novvera';

/// Official repository.
const appRepoUrl = 'https://github.com/YeXuanHs/novvera-app';

const appRepoReleasesUrl = '$appRepoUrl/releases';

/// GitHub traffic proxy (try first; fall back to direct on failure).
const githubProxyPrefix = 'https://gh.sixyin.com/https://';

String githubProxied(String url) {
  if (url.startsWith(githubProxyPrefix)) return url;
  if (url.startsWith('https://')) {
    return '$githubProxyPrefix$url';
  }
  if (url.startsWith('http://')) {
    return '${githubProxyPrefix}https://${url.substring(7)}';
  }
  return url;
}

/// Strip sixyin proxy prefix if present.
String githubDirect(String url) {
  const p = githubProxyPrefix;
  if (url.startsWith(p)) return url.substring(p.length);
  return url;
}

/// Direct (unproxied) endpoints.
const appVersionJsonUrlDirect =
    'https://raw.githubusercontent.com/YeXuanHs/novvera-app/main/publish/version.json';
const appReleasesApiUrlDirect =
    'https://api.github.com/repos/YeXuanHs/novvera-app/releases/latest';
const appRepoPubspecUrlDirect =
    'https://raw.githubusercontent.com/YeXuanHs/novvera-app/main/pubspec.yaml';

/// Proxied endpoints (preferred).
final appVersionJsonUrl = githubProxied(appVersionJsonUrlDirect);
final appReleasesApiUrl = githubProxied(appReleasesApiUrlDirect);
final appRepoPubspecUrl = githubProxied(appRepoPubspecUrlDirect);

/// Community QQ group invite.
const appQqGroupUrl = 'https://qm.qq.com/q/P2br4CwKsy';

/// If window width is less than this value, it is considered as mobile.
const changePoint = 600;

/// If window width is less than this value, it is considered as tablet.
///
/// If it is more than this value, it is considered as desktop.
const changePoint2 = 1300;

/// Default user agent for http requests.
///
/// Keep in sync with Playwright MCP Chromium (`navigator.userAgent`), so
/// linovelib / Cloudflare sites see the same desktop Chrome fingerprint.
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";

/// Pages for all comics is started from this value.
const firstPage = 1;

/// Chapters for all comics is started from this value.
const firstChapter = 1;
