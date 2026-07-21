import 'dart:async';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/cache_manager.dart';
import 'package:novvera/foundation/comic_source/comic_source.dart';
import 'package:novvera/foundation/js_engine.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_api/novel_api_client.dart';
import 'package:novvera/network/cookie_jar.dart';
import 'package:novvera/pages/follow_updates_page.dart';
import 'package:novvera/pages/settings/settings_page.dart';
import 'package:novvera/utils/app_links.dart';
import 'package:novvera/utils/handle_text_share.dart';
import 'package:novvera/utils/opencc.dart';
import 'package:novvera/utils/tags_translation.dart';
import 'package:novvera/utils/translations.dart';
import 'foundation/appdata.dart';


extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

Future<void> init() async {
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  // In-process Dart novel backends (wenku8 / linovelib); no Python sidecar.
  await NovelApiClient.instance.init().wait();
  try {
    var futures = [
      Rhttp.init(),
      App.initComponents(),
      SAFTaskWorker().init().wait(),
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  ComicSourceManager().registerBuiltinPages();
  // Ensure wenku8 account/session once API is up.
  await NovelApiClient.instance.ensureAccount().wait();
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  _checkOldConfigs();
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch(e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/venera-app/venera/issues/343
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('novvera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }

  if (appdata.settings['comicSourceListUrl'].toString().contains("git.nyne.dev")) {
    // migrate to jsdelivr cdn
    appdata.settings['comicSourceListUrl'] = "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json";
    appdata.saveData();
  }
}

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.implicitData['lastCheckUpdate'] = now;
  appdata.writeImplicitData();
  // Comic source store updates disabled (builtin novel sources only).
  if (appdata.settings['checkUpdateOnStart']) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  _checkAppUpdates();
  FollowUpdatesService.initChecker();
}
