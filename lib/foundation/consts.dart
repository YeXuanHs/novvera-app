/// Product brand (fork of Venera → light novel desktop).
const appBrandName = 'Novvera';

/// Official repository.
const appRepoUrl = 'https://github.com/YeXuanHs/novvera-app';

const appRepoReleasesUrl = '$appRepoUrl/releases';

/// Update check / download hit GitHub directly (no traffic proxy).
const appVersionJsonUrl =
    'https://raw.githubusercontent.com/YeXuanHs/novvera-app/main/publish/version.json';
const appReleasesApiUrl =
    'https://api.github.com/repos/YeXuanHs/novvera-app/releases/latest';
const appRepoPubspecUrl =
    'https://raw.githubusercontent.com/YeXuanHs/novvera-app/main/pubspec.yaml';

/// Community QQ group invite.
const appQqGroupUrl = 'https://qm.qq.com/q/P2br4CwKsy';

/// If window width is less than this value, it is considered as mobile.
const changePoint = 600;

/// If window width is less than this value, it is considered as tablet.
///
/// If it is more than this value, it is considered as desktop.
const changePoint2 = 1300;

/// Desktop Chrome 124 UA for novel HTML + CF Verify WebView.
///
/// Used by huanmeng, linovelib, and wenku8 **website** HTML. Keep Dio and the
/// challenge WebView on the same string so `cf_clearance` matches.
/// Never use Mobile Chrome here. wenku8 App relay keeps Dalvik separately.
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

/// Pages for all books is started from this value.
const firstPage = 1;

/// Chapters for all books is started from this value.
const firstChapter = 1;
