import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/dom.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/chapterlog.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/app_dio.dart';
import 'package:novvera/network/cloudflare.dart';
import 'package:novvera/network/cookie_jar.dart';
import 'package:novvera/pages/webview.dart';

const _base = 'https://www.linovelib.com';

/// Labels / paths follow https://www.linovelib.com/top.html sidebar.
const _rankTypes = <String, String>{
  'monthvisit': '月点击榜',
  'weekvisit': '周点击榜',
  'monthvote': '月推荐榜',
  'weekvote': '周推荐榜',
  'monthflower': '月鲜花榜',
  'weekflower': '周鲜花榜',
  'monthegg': '月鸡蛋榜',
  'weekegg': '周鸡蛋榜',
  'lastupdate': '最近更新',
  'postdate': '最新入库',
  'goodnum': '收藏榜',
  'newhot': '新书榜',
  'done': '全本',
};

const _rankPaths = <String, String>{
  'monthvisit': '/top/monthvisit/{page}.html',
  'weekvisit': '/top/weekvisit/{page}.html',
  'monthvote': '/top/monthvote/{page}.html',
  'weekvote': '/top/weekvote/{page}.html',
  'monthflower': '/top/monthflower/{page}.html',
  'weekflower': '/top/weekflower/{page}.html',
  'monthegg': '/top/monthegg/{page}.html',
  'weekegg': '/top/weekegg/{page}.html',
  'lastupdate': '/top/lastupdate/{page}.html',
  'postdate': '/top/postdate/{page}.html',
  'goodnum': '/top/goodnum/{page}.html',
  'newhot': '/top/newhot/{page}.html',
  'done': '/topfull/allvisit/{page}.html',
};

final _aidRe = RegExp(r'/novel/(\d+)\.html');
final _cidRe = RegExp(r'/novel/(\d+)/(\d+)(?:_(\d+))?\.html');
final _searchJsCookieRe =
    RegExp(r'document\.cookie="(jieqiSearchJs=[^"]+)"');
final _spaceRe = RegExp(r'\s+');

/// Dart-side linovelib.com client (replaces Python sidecar).
class LinovelibClient {
  LinovelibClient._();
  static final LinovelibClient instance = LinovelibClient._();

  final _http = NovelHttp(defaultReferer: '$_base/');
  final _bookCache = <String, Map<String, dynamic>>{};
  final _catalogCache = <String, Map<String, dynamic>>{};

  /// Desktop Chrome 124 — same as [webUA] / CF Verify (never Mobile).
  static const _ua = webUA;

  Map<String, String> get _uaHeaders => const {'User-Agent': _ua};

  Future<void> init() async {
    try {
      await ensureSession();
      Log.info('Linovelib', 'HTTP session ready');
    } on CloudflareException catch (e) {
      Log.warning(
        'Linovelib',
        'Cloudflare on bootstrap (${e.url}); verify when browsing',
      );
    } catch (e) {
      Log.warning('Linovelib', 'bootstrap: $e');
    }
  }

  bool _sessionReady = false;
  DateTime? _sessionAt;

  /// Warm homepage cookies. Real CF challenges are raised by
  /// [CloudflareInterceptor] (`cf-mitigated: challenge`), not HTML heuristics.
  Future<bool> ensureSession({bool force = false}) async {
    if (!force &&
        _sessionReady &&
        _sessionAt != null &&
        DateTime.now().difference(_sessionAt!) < const Duration(minutes: 25)) {
      return true;
    }
    await _getHtml('$_base/');
    _sessionReady = true;
    _sessionAt = DateTime.now();
    try {
      await passSearchGuard();
    } catch (_) {}
    return true;
  }

  bool _isCfHtml(String html) {
    final lower = html.toLowerCase();
    return lower.contains('just a moment') ||
        lower.contains('attention required') ||
        lower.contains('challenge-platform') ||
        html.contains('window._cf_chl_opt') ||
        html.contains('cf-browser-verification');
  }

  /// Dio GET with WebView fallback. Verify-minted `cf_clearance` is TLS-bound
  /// to the browser fingerprint and often cannot authorize Dio on Android —
  /// without this fallback the Verify button loops forever.
  Future<({int status, String html, String url})> _getHtml(String url) async {
    try {
      final res = await _http.getHtml(url, headers: _uaHeaders);
      if (_isCfHtml(res.html)) {
        throw CloudflareException(url);
      }
      return res;
    } on CloudflareException catch (e) {
      Log.warning(
        'Linovelib',
        'Dio GET CF ($e); WebView HTML fallback',
      );
      final html = await _fetchHtmlViaWebView(url);
      return (status: 200, html: html, url: url);
    }
  }

  Future<String> _fetchHtmlViaWebView(String url) async {
    final completer = Completer<String>();

    late final HeadlessInAppWebView headless;
    headless = HeadlessInAppWebView(
      webViewEnvironment: AppWebview.webViewEnvironment,
      initialSettings: InAppWebViewSettings(
        userAgent: _ua,
        javaScriptEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      initialUrlRequest: URLRequest(url: WebUri(url)),
      onLoadStop: (controller, loadedUrl) async {
        if (completer.isCompleted) return;
        try {
          await _injectJarCookies(controller);
          final html = await controller.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          if (html is! String || html.length < 200) return;
          if (_isCfHtml(html)) {
            // Still on interstitial — wait for next navigation.
            return;
          }
          final cookies = await controller.getCookies('$_base/');
          if (cookies != null && cookies.isNotEmpty) {
            SingleInstanceCookieJar.instance
                ?.saveFromResponse(Uri.parse('$_base/'), cookies);
          }
          // Keep app UA pinned to Playwright MCP desktop Chrome.
          appdata.implicitData['ua'] = _ua;
          appdata.writeImplicitData();
          if (!completer.isCompleted) completer.complete(html);
          await headless.dispose();
        } catch (e, s) {
          Log.error('Linovelib', 'WebView HTML: $e\n$s');
          if (!completer.isCompleted) completer.completeError(e);
          try {
            await headless.dispose();
          } catch (_) {}
        }
      },
    );

    await headless.run();
    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      try {
        await headless.dispose();
      } catch (_) {}
      // Still challenged — surface Verify for interactive solve, then retry.
      throw CloudflareException(url);
    }
  }

  String _extractAid(String href) {
    final m = _aidRe.firstMatch(href);
    return m?.group(1) ?? '';
  }

  String? _meta(Document doc, List<String> keys) {
    for (final key in keys) {
      for (final meta in doc.querySelectorAll('meta')) {
        final prop = meta.attributes['property'] ?? meta.attributes['name'];
        if (prop == key) {
          final c = cleanText(meta.attributes['content']);
          if (c.isNotEmpty) return c;
        }
      }
    }
    return null;
  }

  void _setCookie(String name, String value) {
    final jar = SingleInstanceCookieJar.instance;
    if (jar == null) return;
    final c = tryCreateCookie(name, value);
    if (c == null) return;
    c.domain = '.linovelib.com';
    c.path = '/';
    jar.saveFromResponse(Uri.parse('$_base/'), [c]);
  }

  Future<bool> passSearchGuard() async {
    try {
      await _http.getHtml('$_base/', headers: _uaHeaders);
      await _http.getHtml('$_base/S6/?search_guard=css', headers: _uaHeaders);
      final js = await _http.getHtml(
        '$_base/S6/?search_guard=js',
        headers: _uaHeaders,
      );
      final m = _searchJsCookieRe.firstMatch(js.html);
      if (m != null) {
        final part = m.group(1)!.split(';').first;
        final eq = part.indexOf('=');
        if (eq > 0) {
          _setCookie(part.substring(0, eq), part.substring(eq + 1));
        }
      }
      // Site JS redeems at 120ms / 800ms / 2000ms; one immediate redeem is often
      // too early for POST /S6/ to accept the ticket.
      final ts = DateTime.now().millisecondsSinceEpoch;
      await _http.getHtml(
        '$_base/S6/?search_guard=redeem&r=$ts',
        headers: _uaHeaders,
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await _http.getHtml(
        '$_base/S6/?search_guard=redeem&r=${DateTime.now().millisecondsSinceEpoch}',
        headers: _uaHeaders,
      );
      final jar = SingleInstanceCookieJar.instance;
      if (jar == null) return false;
      final cookies = jar.loadForRequest(Uri.parse('$_base/'));
      return cookies.any((c) => c.name == 'jieqiSearchTicket');
    } catch (e) {
      Log.warning('Linovelib', 'search_guard: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> rank(String type, int page) async {
    await ensureSession();
    final path =
        (_rankPaths[type] ?? _rankPaths['monthvisit']!).replaceAll('{page}', '$page');
    final res = await _getHtml('$_base$path');
    final doc = parseHtml(res.html);
    final aids = _extractAidsFromRoot(doc.documentElement ?? doc.body!);
    final items = await _enrichAids(aids);
    final pagerMax = parseHtmlMaxPage(doc);
    final maxPage = inferMaxPage(
      page,
      aids.length,
      fullPageSize: 20,
      parsed: pagerMax,
    );
    return {
      'type': type,
      'type_name': _rankTypes[type] ?? type,
      'page': page,
      'pager_max': pagerMax,
      'max_page': maxPage,
      'items': items,
    };
  }

  /// Homepage recommendation blocks — scrape IDs only, enrich via detail pages.
  /// Same contract as search: list HTML → aids → [bookDetail] for name/cover.
  Future<Map<String, dynamic>> home() async {
    await ensureSession();
    final res = await _getHtml('$_base/');
    final doc = parseHtml(res.html);
    final sectionAids = <({String title, List<String> aids})>[];
    final seenTitles = <String>{};
    final allAids = <String>[];
    final allSeen = <String>{};

    for (final titleEl in doc.querySelectorAll('.top-title, .top-title-two')) {
      var title = cleanText(titleEl.text).replaceAll('更多', '').trim();
      if (title.isEmpty || title.length > 24) continue;
      if (!seenTitles.add(title)) continue;
      Element? section = titleEl.parent;
      for (var i = 0; i < 5 && section != null; i++) {
        if (section.querySelectorAll('a[href*="/novel/"]').length >= 3) break;
        section = section.parent;
      }
      if (section == null) continue;
      final aids = _extractAidsFromRoot(section);
      if (aids.length < 3) continue;
      sectionAids.add((title: title, aids: aids));
      for (final id in aids) {
        if (allSeen.add(id)) allAids.add(id);
      }
    }

    final enriched = await _enrichAids(allAids);
    final byId = {for (final b in enriched) '${b['aid']}': b};
    final sections = <Map<String, dynamic>>[];
    for (final s in sectionAids) {
      final items = <Map<String, dynamic>>[
        for (final id in s.aids)
          if (byId[id] != null) Map<String, dynamic>.from(byId[id]!),
      ];
      if (items.length < 3) continue;
      sections.add({'title': s.title, 'items': items});
    }
    return {'sections': sections};
  }

  /// Ordered unique novel IDs under [root] (list / section / rank page).
  List<String> _extractAidsFromRoot(Element root) {
    final aids = <String>[];
    final seen = <String>{};

    void add(String aid) {
      if (aid.isEmpty || !seen.add(aid)) return;
      aids.add(aid);
    }

    // Rank page titles.
    for (final a in root.querySelectorAll('.rank_d_b_name a')) {
      add(_extractAid(a.attributes['href'] ?? ''));
    }
    if (aids.isNotEmpty) return aids;

    for (final a in root.querySelectorAll('a[href*="/novel/"]')) {
      final name = cleanText(a.attributes['title'] ?? a.text);
      if (name == '书籍详情' || name == '加入书架' || name == '立即阅读') {
        continue;
      }
      // Only /novel/{aid}.html — chapter URLs don't match _aidRe.
      add(_extractAid(a.attributes['href'] ?? ''));
    }
    return aids;
  }

  Future<Map<String, dynamic>> search(
    String keyword,
    String type,
    int page,
  ) async {
    await ensureSession();
    if (type == 'author') {
      final url =
          '$_base/authorarticle/${Uri.encodeComponent(keyword)}.html';
      final res = await _getHtml(url);
      final aids = _extractSearchAids(parseHtml(res.html));
      final items = await _enrichAids(aids);
      return {
        'type': type,
        'keyword': keyword,
        'page': page,
        'max_page': 1,
        'items': items,
      };
    }

    if (!await passSearchGuard()) {
      Log.warning('Linovelib', 'search_guard missing ticket; trying anyway');
    }

    String html;
    var finalUrl = '$_base/S6/';
    try {
      var res = await _http.postForm(
        '$_base/S6/',
        {'searchkey': keyword},
        headers: {
          'User-Agent': _ua,
          'Origin': _base,
          'Referer': '$_base/',
        },
      );
      if (res.html.trim().isEmpty) {
        await passSearchGuard();
        res = await _http.postForm(
          '$_base/S6/',
          {'searchkey': keyword},
          headers: {
            'User-Agent': _ua,
            'Origin': _base,
            'Referer': '$_base/',
          },
        );
      }
      html = res.html;
      finalUrl = res.url;
    } on CloudflareException catch (e) {
      // Dio TLS ≠ browser TLS: cf_clearance from Verify cannot authorize Dio POST.
      // Searching inside WebView uses the same fingerprint as the cookie.
      Log.warning(
        'Linovelib',
        'Dio POST /S6/ blocked ($e); falling back to WebView search '
        '(Verify homepage alone cannot fix this)',
      );
      final wv = await _searchHtmlViaWebView(keyword);
      html = wv.html;
      finalUrl = wv.url;
    }

    final doc = parseHtml(html);
    // Unique hit: site 302s to `/novel/{aid}.html`. That detail page also lists
    // related books — scraping every /novel/*.html would inflate results.
    // Prefer the landed book when URL/meta say we are on a detail page.
    List<String> aids;
    final single = _extractAidFromDetailLanding(finalUrl, doc);
    final onDetail = single != null &&
        _aidRe.hasMatch(finalUrl) &&
        doc.querySelectorAll('.search-result-list, .se-result-book').isEmpty;
    if (onDetail) {
      Log.info(
        'Linovelib',
        'search single-hit redirect → novel/$single.html (ignore related links)',
      );
      aids = [single];
    } else {
      aids = _extractSearchAids(doc);
      if (aids.isEmpty && single != null) {
        Log.info(
          'Linovelib',
          'search single-hit redirect → novel/$single.html',
        );
        aids = [single];
      }
    }
    final items = await _enrichAids(aids);
    final pagerMax = parseHtmlMaxPage(doc);
    final maxPage = inferMaxPage(
      page,
      aids.length,
      fullPageSize: 20,
      parsed: pagerMax,
    );
    return {
      'type': type,
      'keyword': keyword,
      'page': page,
      'pager_max': pagerMax,
      'max_page': maxPage,
      'items': items,
    };
  }

  /// When search lands on a book detail page (1 match), pull that aid.
  String? _extractAidFromDetailLanding(String url, Document doc) {
    final fromUrl = _extractAid(url);
    if (fromUrl.isNotEmpty) return fromUrl;
    for (final key in ['og:url', 'og:novel:read_url']) {
      final v = _meta(doc, [key]);
      if (v == null || v.isEmpty) continue;
      final aid = _extractAid(v);
      if (aid.isNotEmpty) return aid;
    }
    final canon =
        doc.querySelector('link[rel="canonical"]')?.attributes['href'] ?? '';
    final fromCanon = _extractAid(canon);
    if (fromCanon.isNotEmpty) return fromCanon;
    // Detail pages always expose book_name; avoid treating random pages as hits.
    final name = _meta(doc, ['og:novel:book_name']);
    if (name == null || name.isEmpty) return null;
    for (final a in doc.querySelectorAll('a[href*="/novel/"]')) {
      final aid = _extractAid(a.attributes['href'] ?? '');
      if (aid.isNotEmpty) return aid;
    }
    return null;
  }

  /// Run search_guard + form POST inside WebView (browser TLS + cookies).
  /// Returns HTML + final URL (may be `/novel/{aid}.html` on a unique hit).
  Future<({String html, String url})> _searchHtmlViaWebView(
    String keyword,
  ) async {
    final completer = Completer<({String html, String url})>();
    var submitted = false;
    final kwJson = jsonEncode(keyword);

    late final HeadlessInAppWebView headless;
    headless = HeadlessInAppWebView(
      webViewEnvironment: AppWebview.webViewEnvironment,
      initialSettings: InAppWebViewSettings(
        userAgent: _ua,
        javaScriptEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      initialUrlRequest: URLRequest(url: WebUri('$_base/')),
      onLoadStop: (controller, url) async {
        if (completer.isCompleted) return;
        try {
          final href = url?.toString() ?? '';
          if (!submitted) {
            submitted = true;
            // Seed jar cookies into WebView, then redeem search_guard & POST.
            await _injectJarCookies(controller);
            await controller.evaluateJavascript(source: '''
(async function() {
  try {
    await fetch('/S6/?search_guard=css', {credentials:'include'});
    var jsTxt = await fetch('/S6/?search_guard=js', {credentials:'include'})
      .then(function(r){ return r.text(); });
    eval(jsTxt);
    await new Promise(function(r){ setTimeout(r, 900); });
    await fetch('/S6/?search_guard=redeem&r=' + Date.now(), {credentials:'include'});
    await new Promise(function(r){ setTimeout(r, 900); });
    await fetch('/S6/?search_guard=redeem&r=' + Date.now(), {credentials:'include'});
    var form = document.createElement('form');
    form.method = 'POST';
    form.action = '/S6/';
    var input = document.createElement('input');
    input.type = 'hidden';
    input.name = 'searchkey';
    input.value = $kwJson;
    form.appendChild(input);
    document.body.appendChild(form);
    form.submit();
  } catch (e) {
    window.__linovelibSearchErr = String(e);
  }
})();
''');
            return;
          }

          // After submit: wait until result markup or error appears.
          final err = await controller.evaluateJavascript(
            source: 'window.__linovelibSearchErr || ""',
          );
          if (err is String && err.isNotEmpty) {
            throw Exception('WebView search JS: $err');
          }
          final html = await controller.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          if (html is! String || html.length < 200) return;
          final lower = html.toLowerCase();
          if (lower.contains('just a moment') ||
              lower.contains('attention required') ||
              lower.contains('challenge-platform')) {
            // Still on CF interstitial — wait for next loadStop.
            return;
          }
          // Unique search hit: site redirects to `/novel/{aid}.html`.
          final singleHit = _aidRe.hasMatch(href) ||
              html.contains('og:novel:book_name') ||
              html.contains('property="og:novel:book_name"');
          if (href.contains('/S6') ||
              singleHit ||
              html.contains('se-result') ||
              html.contains('search-result') ||
              html.contains('没有搜索到') ||
              html.contains('搜索结果')) {
            // Persist WebView cookies (incl. cf_clearance) back to Dio jar.
            final cookies = await controller.getCookies('$_base/');
            if (cookies != null && cookies.isNotEmpty) {
              SingleInstanceCookieJar.instance
                  ?.saveFromResponse(Uri.parse('$_base/'), cookies);
            }
            appdata.implicitData['ua'] = _ua;
            appdata.writeImplicitData();
            if (!completer.isCompleted) {
              completer.complete((html: html, url: href));
            }
            await headless.dispose();
          }
        } catch (e, s) {
          Log.error('Linovelib', 'WebView search: $e\n$s');
          if (!completer.isCompleted) completer.completeError(e);
          try {
            await headless.dispose();
          } catch (_) {}
        }
      },
    );

    await headless.run();
    try {
      return await completer.future.timeout(const Duration(seconds: 50));
    } on TimeoutException {
      try {
        await headless.dispose();
      } catch (_) {}
      throw Exception(
        '哔哩轻小说搜索超时：站点对 App 内 HTTP 客户端拦截了 POST /S6/，'
        'WebView 回退也未在限时内完成。请稍后重试。',
      );
    }
  }

  Future<void> _injectJarCookies(InAppWebViewController controller) async {
    final jar = SingleInstanceCookieJar.instance;
    if (jar == null) return;
    final cm = CookieManager.instance(
      webViewEnvironment: AppWebview.webViewEnvironment,
    );
    final cookies = jar.loadForRequest(Uri.parse('$_base/'));
    for (final c in cookies) {
      try {
        await cm.setCookie(
          url: WebUri('$_base/'),
          name: c.name,
          value: c.value,
          domain: c.domain ?? '.linovelib.com',
          path: c.path ?? '/',
          isSecure: c.secure,
          webViewController: controller,
        );
      } catch (_) {}
    }
  }

  /// Search / list HTML → ordered unique book IDs only (ignore list name/cover).
  ///
  /// Matches site markup verified via Playwright: prefer `.search-result-list`
  /// rows, then any `/novel/{aid}.html` link (cover-only links included).
  List<String> _extractSearchAids(Document doc) {
    final aids = <String>[];
    final seen = <String>{};

    void add(String aid) {
      if (aid.isEmpty || !seen.add(aid)) return;
      aids.add(aid);
    }

    void addFrom(Element root) {
      for (final a in root.querySelectorAll('a[href*="/novel/"]')) {
        final label = cleanText(a.attributes['title'] ?? a.text);
        if (label == '书籍详情' || label == '加入书架' || label == '立即阅读') {
          continue;
        }
        add(_extractAid(a.attributes['href'] ?? ''));
      }
    }

    final rows = doc.querySelectorAll('.search-result-list');
    if (rows.isNotEmpty) {
      for (final row in rows) {
        // One ID per result row (first novel link — often the cover <a>).
        String? rowAid;
        for (final a in row.querySelectorAll('a[href*="/novel/"]')) {
          final aid = _extractAid(a.attributes['href'] ?? '');
          if (aid.isEmpty) continue;
          rowAid = aid;
          break;
        }
        if (rowAid != null) add(rowAid);
      }
      if (aids.isNotEmpty) return aids;
    }

    addFrom(doc.documentElement ?? doc.body!);
    return aids;
  }

  /// Fill name/author/cover/intro from `/novel/{aid}.html` only ([bookDetail]).
  /// Hollow / error detail pages are dropped (e.g. empty shells in search hits).
  /// Cap at 3 concurrent detail fetches — linovelib CF Error 1015 on bursts.
  /// (huanmeng / wenku8 keep uncapped [Future.wait].)
  static const _enrichConcurrency = 3;

  Future<List<Map<String, dynamic>>> _enrichAids(List<String> aids) async {
    if (aids.isEmpty) return [];
    final out = <Map<String, dynamic>?>[];
    for (var i = 0; i < aids.length; i += _enrichConcurrency) {
      final end = i + _enrichConcurrency < aids.length
          ? i + _enrichConcurrency
          : aids.length;
      final batch = aids.sublist(i, end);
      final parts = await Future.wait(batch.map((aid) async {
        try {
          final info = await bookDetail(aid);
          if (info['hollow'] == true) {
            Log.warning('Linovelib', 'enrich skip hollow aid=$aid');
            return null;
          }
          final author = '${info['author_raw'] ?? info['author'] ?? ''}';
          final cover = '${info['cover'] ?? ''}'.trim();
          return <String, dynamic>{
            'aid': aid,
            'name': '${info['name'] ?? ''}',
            'author': author,
            'author_raw': author,
            'cover': cover.isNotEmpty ? cover : linovelibCoverUrl(aid),
            'status': '${info['status'] ?? ''}',
            'intro': '${info['intro'] ?? ''}',
          };
        } catch (e) {
          Log.warning('Linovelib', 'enrich aid=$aid: $e');
          return null;
        }
      }));
      out.addAll(parts);
    }
    return [
      for (final p in out)
        if (p != null) p,
    ];
  }

  Future<Map<String, dynamic>> bookDetail(String aid) async {
    if (_bookCache.containsKey(aid)) return Map.from(_bookCache[aid]!);
    final res = await _getHtml('$_base/novel/$aid.html');
    final doc = parseHtml(res.html);
    var name = _meta(doc, ['og:novel:book_name', 'og:title']) ?? '';
    if (name.isEmpty) {
      final h1 = doc.querySelector('h1.book-name') ?? doc.querySelector('h1');
      name = cleanText(h1?.text);
    }
    final authorRaw = _meta(doc, ['og:novel:author', 'author']) ?? '';
    final status = _meta(doc, ['og:novel:status']) ?? '';
    final updateTime = _meta(doc, ['og:novel:update_time', 'update']);
    final tags = _meta(doc, ['og:novel:tags']);
    var cover = preferHttps(absUrl(_base, _meta(doc, ['og:image', 'pic'])));
    // Soft error / empty shells (e.g. search hit aid=5272, ~1.6KB, no meta).
    final looksError = name.toLowerCase() == 'error';
    final looksShell = res.html.length < 3000 &&
        name.isEmpty &&
        authorRaw.isEmpty &&
        cover.isEmpty;
    if (looksError || looksShell) {
      name = '';
    }
    var intro = '';
    final dec = doc.querySelector('.book-dec');
    if (dec != null) {
      // Site copyright banners live in aside.notice / .notice-body; strip
      // before reading intro so they never become book description.
      for (final n in [
        ...dec.querySelectorAll('aside.notice'),
        ...dec.querySelectorAll('.notice'),
      ]) {
        n.remove();
      }
      final parts = <String>[];
      for (final p in dec.querySelectorAll('p')) {
        if (p.classes.contains('backupname')) continue;
        if (p.classes.contains('notice-body')) continue;
        final t = cleanText(p.text);
        if (t.isEmpty || _looksLikeSiteNotice(t)) continue;
        parts.add(t);
      }
      if (parts.isEmpty) {
        final t = cleanText(dec.text);
        if (t.isNotEmpty && !_looksLikeSiteNotice(t)) parts.add(t);
      }
      intro = parts.join('\n');
    }
    if (intro.isEmpty) {
      intro = _meta(doc, ['og:description', 'description']) ?? '';
    }
    intro = intro
        .replaceFirst(RegExp(r'^.*?内容简介[：:]'), '')
        .trim();
    if (_looksLikeSiteNotice(intro)) {
      intro = _meta(doc, ['og:description', 'description']) ?? '';
    }
    final hollow = name.isEmpty && authorRaw.isEmpty && cover.isEmpty;
    if (!hollow && cover.isEmpty) {
      cover = linovelibCoverUrl(aid);
    }
    // Only fields consumed by _loadComicInfo / cards. No 分类.
    final data = <String, dynamic>{
      'aid': aid,
      'name': name.isEmpty ? '小说_$aid' : name,
      'author_raw': authorRaw,
      'status': status,
      'update_time': updateTime,
      'tags': tags,
      'cover': cover,
      'intro': intro,
      'hollow': hollow,
    };
    // Do not cache hollow shells — may be transient rate-limit pages.
    if (!hollow) {
      _bookCache[aid] = Map.from(data);
    }
    return data;
  }

  Future<Map<String, dynamic>> catalog(String aid) async {
    if (_catalogCache.containsKey(aid)) {
      return _catalogSummary(_catalogCache[aid]!);
    }
    final res = await _getHtml('$_base/novel/$aid/catalog');
    final doc = parseHtml(res.html);
    var title = _meta(doc, ['og:novel:book_name', 'og:title']) ?? '';
    if (title.isEmpty) {
      title = cleanText(doc.querySelector('h1')?.text);
    }
    if (title.isEmpty) title = '小说_$aid';
    final catalog = <String, dynamic>{
      'aid': aid,
      'title': title,
      'volumes': <Map<String, dynamic>>[],
    };
    for (final vol in doc.querySelectorAll('div.volume')) {
      final nameEl = vol.querySelector(
        '.volume-info .volume-title, .volume-info h2, .volume-info a, h2, h3',
      );
      var volName = cleanText(nameEl?.text);
      if (volName.isEmpty) {
        volName =
            '第${(catalog['volumes'] as List).length + 1}卷';
      }
      final chapters = <Map<String, dynamic>>[];
      var seq = 0;
      for (final a in vol.querySelectorAll('.chapter-list a, ul a')) {
        final href = a.attributes['href'] ?? '';
        final m = _cidRe.firstMatch(href);
        if (m == null || m.group(1) != aid) continue;
        final cid = m.group(2)!;
        final chapTitle = cleanText(a.text);
        if (chapTitle.isEmpty) continue;
        seq++;
        chapters.add({
          'seq': seq,
          'title': chapTitle,
          'cid': cid,
          'url': '$_base/novel/$aid/$cid.html',
        });
      }
      if (chapters.isEmpty) continue;
      (catalog['volumes'] as List).add({
        'vol_num': (catalog['volumes'] as List).length + 1,
        'name': volName,
        'chapters': chapters,
      });
    }
    if ((catalog['volumes'] as List).isEmpty) {
      throw Exception('目录为空');
    }
    _catalogCache[aid] = catalog;
    return _catalogSummary(catalog);
  }

  Map<String, dynamic> _catalogSummary(Map<String, dynamic> catalog) {
    final volumes = <Map<String, dynamic>>[];
    for (final vol in catalog['volumes'] as List) {
      final v = Map<String, dynamic>.from(vol as Map);
      volumes.add({
        'vol_num': v['vol_num'],
        'name': v['name'],
        'chapters': [
          for (final c in (v['chapters'] as List))
            {'seq': c['seq'], 'title': c['title']},
        ],
      });
    }
    return {
      'aid': catalog['aid'],
      'title': catalog['title'],
      'volume_count': volumes.length,
      'chapter_count':
          volumes.fold<int>(0, (n, v) => n + (v['chapters'] as List).length),
      'volumes': volumes,
    };
  }

  String? _sameChapterNext(String? href, String aid, String cid) {
    if (href == null || href.isEmpty) return null;
    final full = absUrl(_base, href);
    final m = _cidRe.firstMatch(full);
    if (m == null) return null;
    if (m.group(1) != aid || m.group(2) != cid) return null;
    return full;
  }

  Map<String, dynamic> _parseChapterPage(String html, String cid) {
    final doc = parseHtml(html);
    final titleEl = doc.querySelector('#mlfy_main_text h1');
    final pageTitle = cleanText(titleEl?.text);
    final tc = doc.querySelector('#TextContent');
    final lines = <String>[];
    final images = <String>[];
    if (tc == null) {
      return {
        'page_title': pageTitle,
        'lines': lines,
        'images': images,
        'next': null,
      };
    }

    // #TextContent often embeds <style> (e.g. .pinglun{…}); remove so
    // textContent / empty fallback never leaks CSS into chapter body.
    for (final junk in tc.querySelectorAll('style, script, noscript')) {
      junk.remove();
    }

    final pTexts = <String>[];
    for (final node in tc.nodes) {
      if (node is! Element) continue;
      if (node.localName == 'style' ||
          node.localName == 'script' ||
          node.localName == 'noscript') {
        continue;
      }
      if (node.localName == 'p') {
        final txt = node.text;
        if (txt.replaceAll(_spaceRe, '').isEmpty) continue;
        final cleaned = cleanText(txt);
        if (_looksLikeCssSnippet(cleaned)) continue;
        pTexts.add(cleaned);
      } else if (node.localName == 'img') {
        final src = preferHttps(absUrl(
          _base,
          node.attributes['data-src'] ?? node.attributes['src'],
        ));
        if (src.isNotEmpty) images.add(src);
      } else {
        for (final img in node.querySelectorAll('img')) {
          final src = preferHttps(absUrl(
            _base,
            img.attributes['data-src'] ?? img.attributes['src'],
          ));
          if (src.isNotEmpty && !images.contains(src)) images.add(src);
        }
      }
    }
    for (final img in tc.querySelectorAll('img')) {
      final src = preferHttps(absUrl(
        _base,
        img.attributes['data-src'] ?? img.attributes['src'],
      ));
      if (src.isNotEmpty && !images.contains(src)) images.add(src);
    }

    var paragraphs = pTexts;
    if (paragraphs.isNotEmpty && html.contains('/scripts/chapterlog.js')) {
      paragraphs = restoreParagraphs(paragraphs, int.parse(cid));
    }
    lines.addAll(paragraphs);
    if (lines.isEmpty && images.isEmpty) {
      final raw = cleanText(tc.text);
      if (raw.isNotEmpty && !_looksLikeCssSnippet(raw)) {
        lines.add(raw);
      }
    }
    for (final src in images) {
      if (!lines.contains(src)) lines.add(src);
    }

    String? nextUrl;
    for (final a in doc.querySelectorAll('a')) {
      if (cleanText(a.text) == '下一页') {
        nextUrl = a.attributes['href'];
        break;
      }
    }
    return {
      'page_title': pageTitle,
      'lines': lines,
      'images': images,
      'next': nextUrl,
    };
  }

  Future<Map<String, dynamic>> chapter(
    String aid,
    int volNum,
    int chapNum,
  ) async {
    var catalog = _catalogCache[aid];
    if (catalog == null) {
      await this.catalog(aid);
      catalog = _catalogCache[aid];
    }
    if (catalog == null) throw Exception('目录不可用');
    Map? chap;
    Map? vol;
    for (final v in catalog['volumes'] as List) {
      if (v['vol_num'] == volNum) {
        vol = v as Map;
        for (final c in v['chapters'] as List) {
          if (c['seq'] == chapNum) {
            chap = c as Map;
            break;
          }
        }
        break;
      }
    }
    if (chap == null || vol == null) throw Exception('章节不存在');
    final cid = chap['cid'].toString();

    final lines = <String>[];
    final images = <String>[];
    var pageTitle = '';
    var url = '$_base/novel/$aid/$cid.html';
    final seen = <String>{};
    while (url.isNotEmpty && !seen.contains(url)) {
      seen.add(url);
      final res = await _getHtml(url);
      final page = _parseChapterPage(res.html, cid);
      if (pageTitle.isEmpty) {
        pageTitle = (page['page_title'] as String?) ?? '';
      }
      lines.addAll((page['lines'] as List).cast<String>());
      for (final src in (page['images'] as List).cast<String>()) {
        if (!images.contains(src)) images.add(src);
      }
      url = _sameChapterNext(page['next'] as String?, aid, cid) ?? '';
    }
    if (lines.isEmpty && images.isEmpty) {
      throw Exception('章节内容为空（可能需要登录）');
    }
    return {
      'aid': aid,
      'title': catalog['title'],
      'vol_num': volNum,
      'vol_name': vol['name'],
      'chapter_seq': chapNum,
      'chapter_title': chap['title'],
      'cid': cid,
      'images': images,
      'content': lines.join('\n'),
    };
  }

  /// Copyright / takedown banners from linovelib (aside.notice).
  static bool _looksLikeSiteNotice(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return t.contains('尊敬的哔哩') ||
        t.contains('版权方的要求') ||
        t.contains('现已屏蔽') ||
        (t.contains('仅保留作品文字简介') && t.contains('敬请谅解'));
  }

  /// CSS rules accidentally pulled from embedded style tags.
  static bool _looksLikeCssSnippet(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (RegExp(r'^\.[a-zA-Z_-]+\s*\{').hasMatch(t)) return true;
    if (t.contains('{') &&
        t.contains('}') &&
        (t.contains('display:') ||
            t.contains('margin:') ||
            t.contains('text-align:'))) {
      return true;
    }
    return false;
  }

  /// Cover bytes for list/detail cards.
  ///
  /// Dio often gets CF HTML (not JPEG) even when the same URL opens fine in a
  /// browser — clearance is TLS-bound. Fall back to headless WebView `fetch`.
  Future<Uint8List> fetchCoverBytes(String coverUrl) async {
    var url = preferHttps(coverUrl.trim());
    if (url.startsWith('//')) url = 'https:$url';
    if (url.isEmpty) {
      throw Exception('linovelib cover url empty');
    }
    try {
      final bytes = await _dioFetchCover(url);
      if (_looksLikeImageBytes(bytes)) return bytes;
      Log.warning(
        'Linovelib',
        'cover Dio not image (${bytes.length}B); WebView fallback',
      );
    } catch (e) {
      Log.warning('Linovelib', 'cover Dio failed: $e; WebView fallback');
    }
    return _webviewFetchCoverQueued(url);
  }

  Future<Uint8List> _dioFetchCover(String url) async {
    final dio = AppDio();
    final res = await dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: {
          'User-Agent': _ua,
          'Referer': '$_base/',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        },
      ),
    );
    final status = res.statusCode ?? 0;
    if (status >= 400) {
      throw Exception('cover HTTP $status');
    }
    return Uint8List.fromList(res.data ?? const []);
  }

  /// Serialize WebView cover fetches — spawning many headless views at once
  /// is slow and flaky on desktop.
  Future<Uint8List>? _coverWvTail;

  Future<Uint8List> _webviewFetchCoverQueued(String url) {
    final prev = _coverWvTail;
    final done = Completer<Uint8List>();
    _coverWvTail = done.future;
    () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      try {
        done.complete(await _webviewFetchCoverOnce(url));
      } catch (e, s) {
        done.completeError(e, s);
      }
    }();
    return done.future;
  }

  Future<Uint8List> _webviewFetchCoverOnce(String url) async {
    final completer = Completer<Uint8List>();
    final urlJson = jsonEncode(url);
    final baseJson = jsonEncode('$_base/');

    late final HeadlessInAppWebView headless;
    headless = HeadlessInAppWebView(
      webViewEnvironment: AppWebview.webViewEnvironment,
      initialSettings: InAppWebViewSettings(
        userAgent: _ua,
        javaScriptEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      // Warm same-site cookies, then fetch the image in-page (browser TLS).
      initialUrlRequest: URLRequest(url: WebUri('$_base/')),
      onLoadStop: (controller, _) async {
        if (completer.isCompleted) return;
        try {
          await _injectJarCookies(controller);
          final html = await controller.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          if (html is String && _isCfHtml(html)) {
            // Still on CF interstitial — wait for next navigation.
            return;
          }
          await controller.evaluateJavascript(source: '''
window.__linovelibCover = null;
(async function() {
  try {
    var r = await fetch($urlJson, {
      credentials: 'include',
      headers: { 'Referer': $baseJson }
    });
    var buf = await r.arrayBuffer();
    var bytes = new Uint8Array(buf);
    var bin = '';
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      bin += String.fromCharCode.apply(
        null,
        bytes.subarray(i, Math.min(i + chunk, bytes.length))
      );
    }
    window.__linovelibCover = btoa(bin);
  } catch (e) {
    window.__linovelibCover = 'ERR:' + String(e);
  }
})();
''');
          String? b64;
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            final v = await controller.evaluateJavascript(
              source: 'window.__linovelibCover',
            );
            if (v is String && v.isNotEmpty && v != 'null') {
              b64 = v;
              break;
            }
          }
          if (b64 == null) {
            throw Exception('WebView cover timeout');
          }
          if (b64.startsWith('ERR:')) {
            throw Exception(b64);
          }
          final bytes = base64Decode(b64);
          if (!_looksLikeImageBytes(bytes)) {
            throw Exception(
              'WebView cover not image (${bytes.length}B)',
            );
          }
          final cookies = await controller.getCookies('$_base/');
          if (cookies != null && cookies.isNotEmpty) {
            SingleInstanceCookieJar.instance
                ?.saveFromResponse(Uri.parse('$_base/'), cookies);
          }
          appdata.implicitData['ua'] = _ua;
          appdata.writeImplicitData();
          if (!completer.isCompleted) completer.complete(bytes);
          try {
            await headless.dispose();
          } catch (_) {}
        } catch (e, s) {
          Log.error('Linovelib', 'WebView cover: $e\n$s');
          if (!completer.isCompleted) completer.completeError(e);
          try {
            await headless.dispose();
          } catch (_) {}
        }
      },
    );

    await headless.run();
    try {
      return await completer.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      try {
        await headless.dispose();
      } catch (_) {}
      throw Exception('linovelib cover WebView timeout: $url');
    }
  }

  static bool _looksLikeImageBytes(List<int> data) {
    if (data.length < 8) return false;
    if (data[0] == 0xFF && data[1] == 0xD8) return true; // JPEG
    if (data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true; // PNG
    }
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return true;
    if (data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data.length > 11 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      return true; // WEBP
    }
    return false;
  }
}
