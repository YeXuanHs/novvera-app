import 'dart:io';

import 'package:html/dom.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/chapterlog.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/cloudflare.dart';
import 'package:novvera/network/cookie_jar.dart';

const _base = 'https://www.linovelib.com';

const _rankTypes = <String, String>{
  'allvisit': '总点击榜',
  'allvote': '总推荐榜',
  'monthvisit': '月点击榜',
  'monthvote': '月推荐榜',
  'weekvisit': '周点击榜',
  'weekvote': '周推荐榜',
  'dayvisit': '日点击榜',
  'dayvote': '日推荐榜',
  'postdate': '新书一览',
  'lastupdate': '最近更新',
  'goodnum': '总收藏榜',
  'size': '字数排行',
  'done': '完结全本',
};

const _rankPaths = <String, String>{
  'allvisit': '/topfull/allvisit/{page}.html',
  'allvote': '/top/monthvote/{page}.html',
  'monthvisit': '/top/monthvisit/{page}.html',
  'monthvote': '/top/monthvote/{page}.html',
  'weekvisit': '/top/weekvisit/{page}.html',
  'weekvote': '/top/weekvote/{page}.html',
  'dayvisit': '/top/weekvisit/{page}.html',
  'dayvote': '/top/weekvote/{page}.html',
  'postdate': '/top/postdate/{page}.html',
  'lastupdate': '/top/lastupdate/{page}.html',
  'goodnum': '/top/goodnum/{page}.html',
  'size': '/top/newhot/{page}.html',
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
    await _http.getHtml('$_base/');
    _sessionReady = true;
    _sessionAt = DateTime.now();
    try {
      await passSearchGuard();
    } catch (_) {}
    return true;
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
    final c = Cookie(name, value)
      ..domain = '.linovelib.com'
      ..path = '/';
    jar.saveFromResponse(Uri.parse('$_base/'), [c]);
  }

  Future<bool> passSearchGuard() async {
    try {
      await _http.getHtml('$_base/');
      await _http.getHtml('$_base/S6/?search_guard=css');
      final js = await _http.getHtml('$_base/S6/?search_guard=js');
      final m = _searchJsCookieRe.firstMatch(js.html);
      if (m != null) {
        final part = m.group(1)!.split(';').first;
        final eq = part.indexOf('=');
        if (eq > 0) {
          _setCookie(part.substring(0, eq), part.substring(eq + 1));
        }
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      await _http.getHtml('$_base/S6/?search_guard=redeem&r=$ts');
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
    final res = await _http.getHtml('$_base$path');
    final doc = parseHtml(res.html);
    final items = _parseRank(doc);
    final pagerMax = parseHtmlMaxPage(doc);
    final maxPage = inferMaxPage(
      page,
      items.length,
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

  /// Homepage recommendation blocks (.top-title / .top-title-two).
  Future<Map<String, dynamic>> home() async {
    await ensureSession();
    final res = await _http.getHtml('$_base/');
    final doc = parseHtml(res.html);
    final sections = <Map<String, dynamic>>[];
    final seenTitles = <String>{};
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
      final items = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final a in section.querySelectorAll('a[href*="/novel/"]')) {
        final href = a.attributes['href'] ?? '';
        final aid = _extractAid(href);
        if (aid.isEmpty || !seen.add(aid)) continue;
        final name = cleanText(a.attributes['title'] ?? a.text);
        if (name.length < 2) continue;
        final book = a.parent;
        final img = book?.querySelector('img') ??
            a.querySelector('img');
        var cover = absUrl(
          _base,
          img?.attributes['data-original'] ?? img?.attributes['src'],
        );
        if (cover.isEmpty) {
          cover = linovelibCoverUrl(aid);
        } else {
          cover = preferHttps(cover);
        }
        items.add({
          'aid': aid,
          'name': name,
          'cover': cover,
          'author': '',
          'author_raw': '',
        });
      }
      if (items.length < 3) continue;
      sections.add({'title': title, 'items': items});
    }
    return {'sections': sections};
  }

  List<Map<String, dynamic>> _parseRank(Document doc) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('.rank_d_b_name a')) {
      final href = a.attributes['href'] ?? '';
      final aid = _extractAid(href);
      if (aid.isEmpty || seen.contains(aid)) continue;
      seen.add(aid);
      var author = '';
      Element? intro = a.parent;
      while (intro != null) {
        final cls = intro.classes;
        if (cls.contains('rank_d_book_intro') || cls.contains('rank_d_list')) {
          break;
        }
        intro = intro.parent;
      }
      final cate = intro?.querySelector('.rank_d_b_cate');
      if (cate != null) author = cleanText(cate.text);
      Element? book = a.parent;
      while (book != null && !book.classes.contains('rank_d_book_intro') &&
          !book.classes.contains('rank_d_list')) {
        book = book.parent;
      }
      final img = book?.querySelector('img') ??
          a.parent?.querySelector('img');
      var cover = preferHttps(absUrl(
        _base,
        img?.attributes['data-original'] ?? img?.attributes['src'],
      ));
      if (cover.isEmpty) {
        cover = linovelibCoverUrl(aid);
      }
      items.add({
        'name': cleanText(a.text),
        'author': author,
        'author_raw': author,
        'aid': aid,
        'cover': cover,
      });
    }
    return items;
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
      final res = await _http.getHtml(url);
      var items = _parseSearch(parseHtml(res.html));
      if (items.isEmpty) {
        final seen = <String>{};
        for (final a in parseHtml(res.html).querySelectorAll("a[href*='/novel/']")) {
          final href = a.attributes['href'] ?? '';
          if (!_aidRe.hasMatch(href)) continue;
          final aid = _extractAid(href);
          final name = cleanText(a.text);
          if (aid.isEmpty || name.isEmpty || seen.contains(aid)) continue;
          seen.add(aid);
          items.add({
            'name': name,
            'author': keyword,
            'author_raw': keyword,
            'aid': aid,
            'cover': linovelibCoverUrl(aid),
          });
        }
      }
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
    var res = await _http.postForm(
      '$_base/S6/',
      {'searchkey': keyword},
      headers: {
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
          'Origin': _base,
          'Referer': '$_base/',
        },
      );
    }
    final doc = parseHtml(res.html);
    final items = _parseSearch(doc);
    final pagerMax = parseHtmlMaxPage(doc);
    final maxPage = inferMaxPage(
      page,
      items.length,
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

  List<Map<String, dynamic>> _parseSearch(Document doc) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    final blocks = doc.querySelectorAll(
      '.search-result-list .se-result-book, .se-result-book',
    );
    for (final block in blocks) {
      Element? titleA;
      for (final a in block.querySelectorAll("a[href*='/novel/']")) {
        final href = a.attributes['href'] ?? '';
        if (!_aidRe.hasMatch(href)) continue;
        final text = cleanText(a.text);
        if (text.isNotEmpty && text != '书籍详情' && text != '加入书架') {
          titleA = a;
          break;
        }
      }
      titleA ??= block.querySelector("a[href*='/novel/']");
      if (titleA == null) continue;
      final aid = _extractAid(titleA.attributes['href'] ?? '');
      final name = cleanText(titleA.text);
      if (aid.isEmpty || name.isEmpty || seen.contains(aid)) continue;
      seen.add(aid);
      final infoEl = block.querySelector(
        '.bookinfo, .se-result-infos p, .se-result-infos',
      );
      var author = '';
      if (infoEl != null) {
        final info = cleanText(infoEl.text);
        if (info.contains('|')) {
          author = cleanText(info.split('|').first);
        }
      }
      final img = block.querySelector('img');
      var cover = preferHttps(absUrl(
        _base,
        img?.attributes['data-original'] ?? img?.attributes['src'],
      ));
      if (cover.isEmpty) {
        cover = linovelibCoverUrl(aid);
      }
      items.add({
        'name': name,
        'author': author,
        'author_raw': author,
        'aid': aid,
        'cover': cover,
      });
    }
    if (items.isEmpty) {
      for (final a in doc.querySelectorAll("a[href*='/novel/']")) {
        final href = a.attributes['href'] ?? '';
        if (!_aidRe.hasMatch(href)) continue;
        final aid = _extractAid(href);
        final name = cleanText(a.text);
        if (aid.isEmpty || name.isEmpty || seen.contains(aid)) continue;
        if (name == '书籍详情' || name == '加入书架') continue;
        seen.add(aid);
        items.add({
          'name': name,
          'author': '',
          'author_raw': '',
          'aid': aid,
          'cover': linovelibCoverUrl(aid),
        });
      }
    }
    return items;
  }

  Future<Map<String, dynamic>> bookDetail(String aid) async {
    if (_bookCache.containsKey(aid)) return Map.from(_bookCache[aid]!);
    final res = await _http.getHtml('$_base/novel/$aid.html');
    final doc = parseHtml(res.html);
    var name = _meta(doc, ['og:novel:book_name', 'og:title']) ?? '';
    if (name.isEmpty) {
      final h1 = doc.querySelector('h1.book-name') ?? doc.querySelector('h1');
      name = cleanText(h1?.text);
    }
    final authorRaw = _meta(doc, ['og:novel:author', 'author']) ?? '';
    var category = _meta(doc, ['og:novel:category']) ?? '';
    final status = _meta(doc, ['og:novel:status']) ?? '';
    final updateTime = _meta(doc, ['og:novel:update_time', 'update']);
    final lastChapter = _meta(doc, ['og:novel:latest_chapter_name']);
    final tags = _meta(doc, ['og:novel:tags']);
    var cover = preferHttps(absUrl(_base, _meta(doc, ['og:image', 'pic'])));
    if (cover.isEmpty) {
      cover = linovelibCoverUrl(aid);
    }
    var intro = _meta(doc, ['og:description', 'description']) ?? '';
    if (intro.isEmpty) {
      final dec = doc.querySelector('.book-dec p') ?? doc.querySelector('.book-dec');
      intro = cleanText(dec?.text);
    }
    String? wordCount;
    String? hotText;
    final nums = doc.querySelector('.nums');
    if (nums != null) {
      final text = cleanText(nums.text);
      final wm = RegExp(r'字数[:：]\s*([^\s]+)').firstMatch(text);
      if (wm != null) wordCount = wm.group(1);
      final hm = RegExp(r'总推荐[:：]\s*([^\s]+)').firstMatch(text);
      if (hm != null) hotText = '总推荐：${hm.group(1)}';
    }
    var anime = '否';
    final label = doc.querySelector('.book-label');
    if (label != null && label.text.contains('动画')) anime = '是';
    if (category.contains(' ')) {
      final parts = category.split(RegExp(r'\s+'));
      category = parts.isNotEmpty ? parts.last : category;
    }
    final data = <String, dynamic>{
      'aid': aid,
      'name': name.isEmpty ? '小说_$aid' : name,
      'category': category,
      'author_raw': authorRaw,
      'author': '作者:$authorRaw/分类:$category',
      'status': status,
      'update_time': updateTime,
      'word_count': wordCount,
      'last_chapter': lastChapter,
      'anime': anime,
      'tags': tags,
      'hot_text': hotText,
      'cover': cover,
      'intro': intro,
    };
    _bookCache[aid] = Map.from(data);
    return data;
  }

  Future<Map<String, dynamic>> catalog(String aid) async {
    if (_catalogCache.containsKey(aid)) {
      return _catalogSummary(_catalogCache[aid]!);
    }
    final res = await _http.getHtml('$_base/novel/$aid/catalog');
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

    final pTexts = <String>[];
    for (final node in tc.nodes) {
      if (node is! Element) continue;
      if (node.localName == 'p') {
        final txt = node.text;
        if (txt.replaceAll(_spaceRe, '').isEmpty) continue;
        pTexts.add(cleanText(txt));
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
      if (raw.isNotEmpty) lines.add(raw);
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
      final res = await _http.getHtml(url);
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
}
