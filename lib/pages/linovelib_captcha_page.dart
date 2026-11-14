import 'dart:async';

import 'package:flutter/material.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/network/cookie_jar.dart';
import 'package:novvera/pages/webview.dart';

/// 打开可见 WebView 让用户完成「搜索验证」（4 位图片验证码）。
///
/// 图片验证码无法可靠地自动识别，只能人工过一次；站点对该 IP 30 分钟内
/// 免验证，通过后把 WebView 的 cookie 回写到 Dio 用的 jar，后续爬取直接复用。
///
/// 单独放在页面层，是因为 `LinovelibClient` 依赖 `package:html`，与 material
/// 的 `Element` / `Text` 同名冲突。
Future<bool> passLinovelibSearchCaptcha({
  required String base,
  required String userAgent,
  required bool Function(String html) isCaptcha,
  required bool Function(String url, String html) isResult,
}) async {
  final done = Completer<bool>();
  try {
    final ctx = App.rootContext;
    await Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (pageCtx) => Scaffold(
          appBar: AppBar(
            title: const Text('完成搜索验证'),
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
            initialUrl: '$base/S6/',
            userAgent: userAgent,
            onLoadStop: (controller) async {
              if (done.isCompleted) return;
              final url = (await controller.getUrl())?.toString() ?? '';
              final html = await controller.evaluateJavascript(
                source: 'document.documentElement.outerHTML',
              );
              if (html is! String || html.length < 200) return;
              // 还在验证页，等用户输入验证码后提交。
              if (isCaptcha(html)) return;
              if (!isResult(url, html)) return;
              final cookies = await controller.getCookies('$base/');
              if (cookies != null && cookies.isNotEmpty) {
                SingleInstanceCookieJar.instance
                    ?.saveFromResponse(Uri.parse('$base/'), cookies);
              }
              appdata.implicitData['ua'] = userAgent;
              appdata.writeImplicitData();
              if (!done.isCompleted) done.complete(true);
              if (pageCtx.mounted) Navigator.of(pageCtx).pop();
            },
          ),
        ),
      ),
    );
  } catch (e, s) {
    Log.warning('Linovelib', 'captcha webview failed: $e\n$s');
  }
  if (!done.isCompleted) done.complete(false);
  return done.future;
}
