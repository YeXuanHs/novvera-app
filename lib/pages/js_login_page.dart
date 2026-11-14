import 'dart:async';

import 'package:flutter/material.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/network/cookie_jar.dart';
import 'package:novvera/pages/webview.dart';

/// 给 JS 源用的「可见 WebView 登录」。
///
/// Dio 没有浏览器 TLS 指纹，像 wenku8 的 login.php 会被 Cloudflare 拦；
/// 这里开一个真实 WebView 让用户登录，命中 [successKeywords] 后把 cookie
/// 回写到 Dio 用的 jar，JS 源后续请求就能复用登录态。
Future<bool> jsWebviewLogin({
  required String url,
  required String? userAgent,
  required List<String> successKeywords,
  required String cookieUrl,
}) async {
  final done = Completer<bool>();
  try {
    final ctx = App.rootContext;
    await Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (pageCtx) => Scaffold(
          appBar: AppBar(
            title: const Text('登录'),
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  if (!done.isCompleted) done.complete(false);
                  Navigator.of(pageCtx).pop();
                },
              ),
            ],
          ),
          body: AppWebview(
            initialUrl: url,
            userAgent: userAgent,
            onLoadStop: (controller) async {
              if (done.isCompleted) return;
              try {
                final html = await controller.evaluateJavascript(
                  source: 'document.documentElement.outerHTML',
                );
                if (html is! String || html.isEmpty) return;
                final ok = successKeywords.isEmpty
                    ? true
                    : successKeywords.any(html.contains);
                if (!ok) return;
                final cookies = await controller.getCookies(cookieUrl);
                if (cookies != null && cookies.isNotEmpty) {
                  SingleInstanceCookieJar.instance
                      ?.saveFromResponse(Uri.parse(cookieUrl), cookies);
                }
                if (!done.isCompleted) done.complete(true);
                if (pageCtx.mounted) Navigator.of(pageCtx).pop();
              } catch (e) {
                Log.warning('JsLogin', '$e');
              }
            },
          ),
        ),
      ),
    );
  } catch (e, s) {
    Log.warning('JsLogin', '$e\n$s');
  }
  if (!done.isCompleted) done.complete(false);
  return done.future;
}
