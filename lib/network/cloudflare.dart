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

  CloudflareException(this.url);

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException:\s*(\S+)").firstMatch(message);
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
  RequestOptions get requestOptions => RequestOptions();

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;

  @override
  DioExceptionReadableStringBuilder? stringBuilder;
}

/// Open the site origin for challenges — never a .jpg/.js asset URL.
/// Loading CF HTML on a static-file URL often breaks the challenge WebView
/// (blank page / odd redirects that look like 127.0.0.1 on some devices).
String _challengeLaunchUrl(String raw) {
  var s = raw.trim();
  final cut = s.indexOf(RegExp(r'[\s\n]'));
  if (cut > 0) s = s.substring(0, cut);
  Uri? uri;
  try {
    uri = Uri.parse(s);
  } catch (_) {}
  if (uri == null ||
      uri.host.isEmpty ||
      uri.host == 'localhost' ||
      uri.host == '127.0.0.1' ||
      uri.host.endsWith('.localhost')) {
    return 'https://www.linovelib.com/';
  }
  final path = uri.path.toLowerCase();
  final isAsset = path.endsWith('.jpg') ||
      path.endsWith('.jpeg') ||
      path.endsWith('.png') ||
      path.endsWith('.webp') ||
      path.endsWith('.gif') ||
      path.endsWith('.css') ||
      path.endsWith('.js') ||
      path.contains('/files/article/') ||
      path.contains('/cover/');
  if (isAsset || path.isEmpty || path == '/') {
    return '${uri.scheme}://${uri.host}/';
  }
  // Prefer host root so Turnstile can complete cleanly.
  return '${uri.scheme}://${uri.host}/';
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final ua = appdata.implicitData['ua'];
    final cookie = options.headers['cookie']?.toString() ?? '';
    // cf_clearance is bound to the WebView UA — reuse it when present.
    if (ua is String &&
        ua.isNotEmpty &&
        (cookie.contains('cf_clearance') ||
            options.uri.host.contains('linovelib') ||
            options.uri.host.contains('readpai'))) {
      options.headers['user-agent'] = ua;
      options.headers['User-Agent'] = ua;
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 403 || err.response?.statusCode == 503) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 403 || response.statusCode == 503) {
      var err = _check(response);
      if (err != null) {
        handler.reject(err);
        return;
      }
      // Streamed cover/image responses may not expose HTML body here; treat
      // text/html 403 from protected hosts as Cloudflare.
      final ct = response.headers.value('content-type') ?? '';
      final host = response.requestOptions.uri.host;
      if (ct.contains('text/html') &&
          (host.contains('linovelib') || host.contains('readpai'))) {
        handler.reject(CloudflareException(
          _challengeLaunchUrl(response.requestOptions.uri.toString()),
        ));
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    final launch = _challengeLaunchUrl(
      response.realUri.toString().isNotEmpty
          ? response.realUri.toString()
          : response.requestOptions.uri.toString(),
    );
    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      return CloudflareException(launch);
    }
    // Fallback: classic challenge pages without cf-mitigated header.
    final status = response.statusCode;
    if (status == 403 || status == 503) {
      final data = response.data;
      String html = '';
      if (data is String) {
        html = data;
      } else if (data is List<int>) {
        html = String.fromCharCodes(data.take(4096));
      }
      if (html.contains('challenge-platform') ||
          html.contains('Just a moment') ||
          html.contains('cf-browser-verification') ||
          html.contains('window._cf_chl_opt')) {
        return CloudflareException(launch);
      }
    }
    return null;
  }
}

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  var url = _challengeLaunchUrl(e.url);
  var uri = Uri.parse(url);

  void saveCookies(Map<String, String> cookies) {
    var domain = uri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    // Also store under apex domain variants used by CDN paths.
    SingleInstanceCookieJar.instance!.saveFromResponse(
      uri,
      List<io.Cookie>.generate(cookies.length, (index) {
        var cookie = io.Cookie(
            cookies.keys.elementAt(index), cookies.values.elementAt(index));
        cookie.domain = domain;
        return cookie;
      }),
    );
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
            body.contains("window._cf_chl_opt");
        if (!isChallenging) {
          Log.info(
            "Cloudflare",
            "Cloudflare is passed due to there is no challenge css",
          );
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookiesMap = await controller.getCookies(url);
          if (cookiesMap['cf_clearance'] == null) {
            return;
          }
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
      var head = await controller.evaluateJavascript(
          source: "document.head.innerHTML") as String;
      var body = await controller.evaluateJavascript(
          source: "document.body.innerHTML") as String;
      Log.info("Cloudflare", "Checking head: $head");
      var isChallenging = head.contains('#challenge-success-text') ||
          head.contains("#challenge-error-text") ||
          head.contains("#challenge-form") ||
          body.contains("challenge-platform") ||
          body.contains("window._cf_chl_opt");
      if (!isChallenging) {
        Log.info(
          "Cloudflare",
          "Cloudflare is passed due to there is no challenge css",
        );
        var ua = await controller.getUA();
        if (ua != null) {
          appdata.implicitData['ua'] = ua;
          appdata.writeImplicitData();
        }
        var cookies = await controller.getCookies(url) ?? [];
        if (cookies.firstWhereOrNull(
                (element) => element.name == 'cf_clearance') ==
            null) {
          return;
        }
        SingleInstanceCookieJar.instance?.saveFromResponse(uri, cookies);
        if (!success) {
          App.rootPop();
          success = true;
        }
      }
    }

    await App.rootContext.to(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onTitleChange: (title, controller) async {
          check(controller);
        },
        onLoadStop: (controller) async {
          check(controller);
        },
        onStarted: (controller) async {
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookies = await controller.getCookies(url) ?? [];
          SingleInstanceCookieJar.instance?.saveFromResponse(uri, cookies);
        },
      ),
    );
    onFinished();
  }
}
