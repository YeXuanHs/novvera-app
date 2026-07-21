import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

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

Document parseHtml(String source) => html_parser.parse(source);

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

bool isCloudflareChallenge(String html, int? status) {
  if (status == 403 || status == 503) {
    if (html.contains('Just a moment') ||
        html.contains('cf-browser-verification') ||
        html.contains('challenge-platform')) {
      return true;
    }
  }
  return html.contains('cf-browser-verification') &&
      html.contains('challenge-platform');
}

/// Thin wrapper around AppDio for novel site scraping.
class NovelHttp {
  NovelHttp({this.defaultReferer});

  final String? defaultReferer;
  final Dio _dio = AppDio();

  Future<({int status, String html, String url})> getHtml(
    String url, {
    bool preferGbk = false,
    Map<String, String>? headers,
  }) async {
    final res = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        validateStatus: (s) => s != null && s < 600,
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
    if (isCloudflareChallenge(html, res.statusCode)) {
      Log.warning('NovelHttp', 'Cloudflare challenge at $url');
    }
    return (status: res.statusCode ?? 0, html: html, url: finalUrl);
  }

  Future<({int status, String html})> postForm(
    String url,
    Map<String, String> form, {
    bool preferGbk = false,
    Map<String, String>? headers,
  }) async {
    final res = await _dio.post<List<int>>(
      url,
      data: form,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.bytes,
        followRedirects: true,
        validateStatus: (s) => s != null && s < 600,
        headers: {
          if (defaultReferer != null) 'Referer': defaultReferer!,
          ...?headers,
        },
      ),
    );
    final bytes = Uint8List.fromList(res.data ?? const []);
    return (
      status: res.statusCode ?? 0,
      html: decodeHtmlBytes(bytes, preferGbk: preferGbk),
    );
  }
}
