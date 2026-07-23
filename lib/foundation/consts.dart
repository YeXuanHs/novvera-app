/// Product brand (fork of Venera → light novel desktop).
const appBrandName = 'Novvera';

/// Official repository.
const appRepoUrl = 'https://github.com/YeXuanHs/novvera-app';

const appRepoReleasesUrl = '$appRepoUrl/releases';

/// Remote pubspec used by in-app update check (same branch as releases).
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

/// Default user agent for http requests.
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36";

/// Pages for all comics is started from this value.
const firstPage = 1;

/// Chapters for all comics is started from this value.
const firstChapter = 1;