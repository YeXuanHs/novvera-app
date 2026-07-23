import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:novvera/network/app_dio.dart';
import 'package:novvera/network/cloudflare.dart';

String cleanText(String? s) {
  if (s == null) return '';
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String absUrl(String base, String? href) {
  if (href == null || href.isEmpty) return '';
  if (href.startsWith('//')) return 'https:$href';
  if (href.startsWith('http://') || href.startsWith('https://')) return href;
  return Uri.parse(base).resolve(href).toString();
}

/// Resolve cover/image URL preferring lazy-load attributes over placeholder [src].
String lazyImgSrc(Element? img, String base) {
  if (img == null) return '';
  final raw = img.attributes['data-original'] ??
      img.attributes['data-src'] ??
      img.attributes['data-lazy'] ??
      img.attributes['data-url'] ??
      img.attributes['src'];
  return preferHttps(absUrl(base, raw));
}

/// Prefer https for CDN hosts that still emit http links.
String preferHttps(String url) {
  if (url.startsWith('http://')) {
    return 'https://${url.substring(7)}';
  }
  return url;
}

/// Wenku8 chapter illustrations: HTML often uses pic.wenku8.com which 302s to
/// pic.777743.xyz (path drops the `/pictures/` prefix). Resolve eagerly so
/// image downloads do not depend on redirect-following.
String normalizeNovelImageUrl(String url) {
  var u = preferHttps(url.trim());
  if (u.isEmpty) return u;
  final pic = RegExp(
    r'^https://pic\.wenku8\.com/pictures/(.+)$',
    caseSensitive: false,
  ).firstMatch(u);
  if (pic != null) {
    return 'https://pic.777743.xyz/${pic.group(1)}';
  }
  return u;
}

/// Wenku8 cover: CDN is incomplete for many books (404). Use a custom scheme
/// resolved via App API `action=book&do=cover` in [ImageDownloader].
String wenku8CoverUrl(String aid) {
  final id = int.tryParse(aid);
  if (id == null) return '';
  return 'novvera://wenku8/cover/$id';
}

/// Legacy CDN path (may 404). Kept for diagnostics / migration.
String wenku8CoverCdnUrl(String aid) {
  final id = int.tryParse(aid);
  if (id == null) return '';
  final folder = id ~/ 1000;
  return 'https://img.wenku8.com/image/$folder/$aid/${aid}s.jpg';
}

/// Linovelib cover path used by the site templates.
String linovelibCoverUrl(String aid) {
  final id = int.tryParse(aid);
  if (id == null) return '';
  final folder = id ~/ 1000;
  return 'https://www.linovelib.com/files/article/image/$folder/$aid/${aid}s.jpg';
}

/// Huanmeng list pages often omit cover imgs (text-only shelf links).
/// Resolve via detail page in [ImageDownloader].
String huanmengCoverUrl(String aid) {
  final id = int.tryParse(aid);
  if (id == null) return '';
  return 'novvera://huanmeng/cover/$id';
}

Document parseHtml(String source) => html_parser.parse(source);

/// Parse last page number from common Chinese novel site pagers.
/// Returns null if the HTML has no usable pager.
int? parseHtmlMaxPage(Document doc) {
  int? best;

  void consider(int? n) {
    if (n == null || n < 1) return;
    if (best == null || n > best!) best = n;
  }

  // "#pagelink a.last" / class=last
  for (final a in doc.querySelectorAll(
    '#pagelink a.last, #pagelink a.Last, a.last, .pagination a.last',
  )) {
    final href = a.attributes['href'] ?? '';
    final m = RegExp(r'[?&]page=(\d+)').firstMatch(href) ??
        RegExp(r'/(\d+)\.html').firstMatch(href);
    if (m != null) {
      consider(int.tryParse(m.group(1)!));
    } else {
      consider(int.tryParse(cleanText(a.text)));
    }
  }

  // Any pager links with page=
  for (final a in doc.querySelectorAll(
    '#pagelink a[href], .pages a[href], .pagination a[href], .pagelink a[href], a[href*="/page/"]',
  )) {
    final href = a.attributes['href'] ?? '';
    final m = RegExp(r'[?&]page=(\d+)').firstMatch(href);
    if (m != null) consider(int.tryParse(m.group(1)!));
    final m2 = RegExp(r'/(\d+)\.html').firstMatch(href);
    if (m2 != null) consider(int.tryParse(m2.group(1)!));
    final m3 = RegExp(r'/page/(\d+)').firstMatch(href);
    if (m3 != null) consider(int.tryParse(m3.group(1)!));
    final t = int.tryParse(cleanText(a.text));
    if (t != null && t < 100000) consider(t);
  }

  // "1/42" style
  for (final el in doc.querySelectorAll('#pagestats, .pagestats, #pagelink')) {
    final m = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(el.text);
    if (m != null) consider(int.tryParse(m.group(2)!));
  }

  return best;
}

/// Infer max page when HTML pager is missing.
/// Never use "current+1 forever" — that makes 1/2 → 2/3 → 3/4 endless UI.
///
/// When [parsed] is set (from `#pagestats` / `a.last`), always prefer it.
/// Soft `page+1` is only for a single source with a full page and no pager;
/// callers that merge several searches must use [mergeSearchMaxPage] instead.
int inferMaxPage(int page, int itemCount, {int fullPageSize = 10, int? parsed}) {
  if (parsed != null && parsed >= 1) {
    return parsed < page ? page : parsed;
  }
  if (itemCount <= 0) {
    return page <= 1 ? 1 : page - 1;
  }
  // Short page ⇒ last page. Full page ⇒ allow one more probe only.
  if (itemCount < fullPageSize) {
    return page;
  }
  return page + 1;
}

/// Merge max pages from parallel search types (书名/作者/标签).
/// Prefer any real HTML pager; never let a soft `page+1` from one type
/// inflate past a parsed pager from another (that caused endless 1/2→2/3…).
int mergeSearchMaxPage(
  int page, {
  required List<int?> pagerMaxes,
  required List<int> itemCounts,
  int fullPageSize = 10,
}) {
  int? bestPager;
  for (final p in pagerMaxes) {
    if (p == null || p < 1) continue;
    if (bestPager == null || p > bestPager) bestPager = p;
  }
  if (bestPager != null) {
    return bestPager < page ? page : bestPager;
  }
  var anyFull = false;
  var anyItems = false;
  for (final n in itemCounts) {
    if (n > 0) anyItems = true;
    if (n >= fullPageSize) anyFull = true;
  }
  if (!anyItems) {
    return page <= 1 ? 1 : page - 1;
  }
  if (!anyFull) return page;
  return page + 1;
}

String decodeHtmlBytes(Uint8List bytes, {bool preferGbk = false}) {
  if (preferGbk) {
    try {
      return gbk.decode(bytes);
    } catch (_) {}
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {}
  try {
    return gbk.decode(bytes);
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

String gbkQueryEncode(String text) {
  final bytes = gbk.encode(text);
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write('%');
    sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return sb.toString();
}

/// Thin wrapper around AppDio for novel site scraping.
/// Cloudflare challenges are detected only by [CloudflareInterceptor]
/// (`403` + `cf-mitigated: challenge`), same as upstream Venera.
class NovelHttp {
  NovelHttp({this.defaultReferer});

  final String? defaultReferer;
  final Dio _dio = AppDio();

  Future<T> _guardDio<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on CloudflareException {
      rethrow;
    } on DioException catch (e) {
      if (e is CloudflareException) rethrow;
      final err = e.error;
      if (err is CloudflareException) throw err;
      final fromMsg = CloudflareException.fromString(e.message ?? '');
      if (fromMsg != null) throw fromMsg;
      rethrow;
    }
  }

  Future<({int status, String html, String url})> getHtml(
    String url, {
    bool preferGbk = false,
    Map<String, String>? headers,
  }) async {
    return _guardDio(() async {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          headers: {
            if (defaultReferer != null) 'Referer': defaultReferer!,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            ...?headers,
          },
        ),
      );
      final bytes = Uint8List.fromList(res.data ?? const []);
      final html = decodeHtmlBytes(bytes, preferGbk: preferGbk);
      final finalUrl = res.realUri.toString();
      return (status: res.statusCode ?? 0, html: html, url: finalUrl);
    });
  }

  Future<({int status, String html, String url})> postForm(
    String url,
    Map<String, String> form, {
    bool preferGbk = false,
    Map<String, String>? headers,
  }) async {
    return _guardDio(() async {
      final res = await _dio.post<List<int>>(
        url,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.bytes,
          followRedirects: true,
          headers: {
            if (defaultReferer != null) 'Referer': defaultReferer!,
            ...?headers,
          },
        ),
      );
      final bytes = Uint8List.fromList(res.data ?? const []);
      final html = decodeHtmlBytes(bytes, preferGbk: preferGbk);
      final finalUrl = res.realUri.toString();
      return (status: res.statusCode ?? 0, html: html, url: finalUrl);
    });
  }
}
