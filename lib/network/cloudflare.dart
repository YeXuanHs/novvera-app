import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/pages/webview.dart';
import 'package:novvera/utils/ext.dart';

import 'cookie_jar.dart';

class CloudflareException implements DioException {
  final String url;
  final RequestOptions? _requestOptions;
  final Response? _response;

  CloudflareException(this.url, {RequestOptions? requestOptions, Response? response})
      : _requestOptions = requestOptions,
        _response = response;

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException: (.+)").firstMatch(message);
    if (match == null) return null;
    return CloudflareException(match.group(1)!);
  }

  @override
  DioException copyWith(
      {RequestOptions? requestOptions,
      Response<dynamic>? response,
      DioExceptionType? type,
      Object? error,
      StackTrace? stackTrace,
      String? message}) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions =>
      _requestOptions ?? RequestOptions(path: url);

  @override
  Response? get response => _response;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;

  @override
  DioExceptionReadableStringBuilder? stringBuilder;
}

/// Sites that pin desktop Chrome 124 ([webUA]) for Dio + CF Verify.
/// wenku8 **website** (HTML) is included; the App relay (Dalvik) is not.
bool _pinsDesktopChromeUa(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.contains('wenku8-relay') || host.contains('mewx.org')) {
    return false;
  }
  return host.contains('huanmengacg') ||
      host.contains('linovelib') ||
      host.contains('wenku8');
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.headers['cookie'].toString().contains('cf_clearance')) {
      final url = options.uri.toString();
      if (_pinsDesktopChromeUa(url)) {
        // WebView Verify mints clearance under [webUA]; Dio must match.
        options.headers['user-agent'] = webUA;
        options.headers.remove('User-Agent');
      } else {
        // wenku8 / others: keep explicit request UA; only fill if missing.
        final existing = options.headers['User-Agent'] ??
            options.headers['user-agent'];
        if (existing == null || '$existing'.trim().isEmpty) {
          options.headers['user-agent'] =
              appdata.implicitData['ua'] ?? webUA;
        }
      }
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 403) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 403) {
      var err = _check(response);
      if (err != null) {
        handler.reject(err);
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    final req = response.requestOptions;
    final url = req.uri.toString();
    CloudflareException fail(String reason) {
      Log.warning(
        'Cloudflare',
        'challenge on ${req.method} $url '
        '(status=${response.statusCode}, $reason)',
      );
      return CloudflareException(
        url,
        requestOptions: req,
        response: response,
      );
    }

    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      return fail('cf-mitigated=challenge');
    }
    // wenku8 often returns a hard CF block page (Attention Required) without
    // cf-mitigated — still need WebView Verify / cf_clearance.
    if (response.statusCode == 403) {
      final html = _peekBody(response);
      if (html.contains('Attention Required') ||
          html.contains('Just a moment') ||
          html.contains('cf-browser-verification') ||
          html.contains('challenge-platform') ||
          html.contains('window._cf_chl_opt')) {
        return fail('challenge html');
      }
    }
    return null;
  }
}

String _peekBody(Response response) {
  final data = response.data;
  if (data is String) {
    return data.length > 4096 ? data.substring(0, 4096) : data;
  }
  if (data is List<int>) {
    return String.fromCharCodes(data.take(4096));
  }
  return '';
}

/// Anti-CC / slider page: 「验证」 or English verify/verification.
/// Blunt on purpose. Ignore SEO tags like `baidu-site-verification`.
bool looksLikeSliderOrHumanCheck(String body) {
  if (body.isEmpty) return false;
  if (body.contains('验证')) return true;
  // Strip common SEO meta names that contain the substring "verification".
  final lower = body
      .toLowerCase()
      .replaceAll('site-verification', '')
      .replaceAll('domain-verification', '');
  if (lower.contains('verification')) return true;
  if (RegExp(r'\bverify\b').hasMatch(lower)) return true;
  return false;
}

void throwIfSliderOrHumanCheck(String url, String body) {
  if (!looksLikeSliderOrHumanCheck(body)) return;
  Log.warning(
    'Cloudflare',
    'slider/human-check keywords on $url — open Verify WebView',
  );
  throw CloudflareException(url);
}

/// POST/API paths (e.g. linovelib `/S6/`) usually do not render a CF
/// challenge page on GET — opening the site root makes Verify look like a
/// no-op (homepage has no challenge CSS). Prefer staying on the same host
/// root only when the path is clearly an asset; for `/S6/` keep the URL so
/// the search form can load (and linovelib search already WebView-falls-back).
String _challengeBrowseUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final path = uri.path;
  final looksLikeAsset = RegExp(
    r'\.(jpe?g|png|gif|webp|css|js|ico|woff2?|mp3|mp4)(\?|$)',
    caseSensitive: false,
  ).hasMatch(path);
  if (looksLikeAsset) {
    return '${uri.scheme}://${uri.host}/';
  }
  final isSearchPost =
      path == '/S6' || path == '/S6/' || path.startsWith('/S6/');
  if (isSearchPost) {
    Log.info(
      'Cloudflare',
      'Verify for linovelib /S6/ opens homepage to mint cookies; '
      'search itself uses WebView POST (Dio cannot reuse cf_clearance).',
    );
    return '${uri.scheme}://${uri.host}/';
  }
  return url;
}

void _purgeJarCfClearance(Uri uri) {
  final jar = SingleInstanceCookieJar.instance;
  if (jar == null) return;
  final root = Uri.parse('${uri.scheme}://${uri.host}/');
  jar.delete(root, 'cf_clearance');
  jar.delete(uri, 'cf_clearance');
}

void _persistPinnedUa(String url) {
  if (!_pinsDesktopChromeUa(url)) return;
  appdata.implicitData['ua'] = webUA;
  appdata.writeImplicitData();
}

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  var url = _challengeBrowseUrl(e.url);
  var uri = Uri.parse(url);
  // WebView follows the Dio UA we already pin for huanmeng/linovelib.
  final verifyUa = _pinsDesktopChromeUa(url) ? webUA : null;
  Log.info(
    'Cloudflare',
    'Verify open $url (from ${e.url})'
    '${verifyUa != null ? ' ua=desktop-chrome-124' : ''}',
  );

  void saveCookies(Map<String, String> cookies) {
    var domain = uri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    final list = <io.Cookie>[];
    for (final entry in cookies.entries) {
      final cookie = tryCreateCookie(entry.key, entry.value);
      if (cookie == null) continue;
      cookie.domain = domain;
      list.add(cookie);
    }
    if (list.isEmpty) return;
    SingleInstanceCookieJar.instance!.saveFromResponse(uri, list);
  }

  // windows version of package `flutter_inappwebview` cannot get some cookies
  // Using DesktopWebview instead
  if (App.isLinux) {
    var webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) async {
        var head =
            await controller.evaluateJavascript("document.head.innerHTML") ??
                "";
        var body =
            await controller.evaluateJavascript("document.body.innerHTML") ??
                "";
        Log.info("Cloudflare", "Checking head: $head");
        var isChallenging = head.contains('#challenge-success-text') ||
            head.contains("#challenge-error-text") ||
            head.contains("#challenge-form") ||
            body.contains("challenge-platform") ||
            body.contains("window._cf_chl_opt") ||
            title.contains('Just a moment') ||
            title.contains('Attention Required');
        if (!isChallenging) {
          Log.info(
            "Cloudflare",
            "Cloudflare is passed due to there is no challenge css",
          );
          if (verifyUa != null) {
            _persistPinnedUa(url);
          } else {
            var ua = controller.userAgent;
            if (ua != null) {
              appdata.implicitData['ua'] = ua;
              appdata.writeImplicitData();
            }
          }
          var cookiesMap = await controller.getCookies(url);
          if (cookiesMap['cf_clearance'] == null) {
            return;
          }
          _purgeJarCfClearance(uri);
          saveCookies(cookiesMap);
          controller.close();
          onFinished();
        }
      },
      onClose: onFinished,
    );
    webview.open();
  } else {
    bool success = false;
    void check(InAppWebViewController controller) async {
      try {
        var head = await controller.evaluateJavascript(
            source: "document.head.innerHTML") as String;
        var body = await controller.evaluateJavascript(
            source: "document.body.innerHTML") as String;
        final title = await controller.getTitle() ?? '';
        Log.info("Cloudflare", "Checking head: $head");
        var isChallenging = head.contains('#challenge-success-text') ||
            head.contains("#challenge-error-text") ||
            head.contains("#challenge-form") ||
            body.contains("challenge-platform") ||
            body.contains("window._cf_chl_opt") ||
            title.contains('Just a moment') ||
            title.contains('Attention Required');
        if (!isChallenging) {
          Log.info(
            "Cloudflare",
            "Cloudflare is passed due to there is no challenge css",
          );
          if (verifyUa != null) {
            _persistPinnedUa(url);
          } else {
            var ua = await controller.getUA();
            if (ua != null) {
              appdata.implicitData['ua'] = ua;
              appdata.writeImplicitData();
            }
          }
          var cookies = await controller.getCookies(url) ?? [];
          if (cookies.firstWhereOrNull(
                  (element) => element.name == 'cf_clearance') ==
              null) {
            return;
          }
          _purgeJarCfClearance(uri);
          SingleInstanceCookieJar.instance?.saveFromResponse(uri, cookies);
          if (!success) {
            App.rootPop();
            success = true;
          }
        }
      } catch (err, st) {
        Log.error('Cloudflare', 'Verify check failed\n$err\n$st');
      }
    }

    await App.rootContext.to(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        userAgent: verifyUa,
        onTitleChange: (title, controller) async {
          check(controller);
        },
        onLoadStop: (controller) async {
          check(controller);
        },
        onStarted: (controller) async {
          if (verifyUa != null) {
            _persistPinnedUa(url);
          } else {
            var ua = await controller.getUA();
            if (ua != null) {
              appdata.implicitData['ua'] = ua;
              appdata.writeImplicitData();
            }
          }
          var cookies = await controller.getCookies(url) ?? [];
          SingleInstanceCookieJar.instance?.saveFromResponse(uri, cookies);
        },
      ),
    );
    onFinished();
  }
}
