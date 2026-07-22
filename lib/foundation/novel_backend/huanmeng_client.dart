import 'package:html/dom.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/cloudflare.dart';

const _base = 'https://www.huanmengacg.com';

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

/// Map builtin rank keys onto huanmeng list pages.
/// Site has Cloudflare; no dedicated wenku8-style rank API.
const _rankPaths = <String, String>{
  'allvisit': '/index.php/custom/top',
  'allvote': '/index.php/custom/top',
  'monthvisit': '/index.php/book/category/tags/1',
  'monthvote': '/index.php/book/category/tags/3',
  'weekvisit': '/index.php/book/category/tags/2',
  'weekvote': '/index.php/book/category/tags/4',
  'dayvisit': '/index.php/book/category/tags/10',
  'dayvote': '/index.php/book/category/tags/5',
  'postdate': '/index.php/book/category/tags/6',
  'lastupdate': '/index.php/book/category/tags/12',
  'goodnum': '/index.php/book/category/tags/11',
  'size': '/index.php/book/category/tags/7',
  'done': '/index.php/book/category/finish/2',
};

final _aidRe = RegExp(r'/book/info/(\d+)');
final _readRe = RegExp(r'/book_read_(\d+)_(\d+)\.html');
final _orderRe = RegExp(r'order\s*:\s*(-?\d+)');
final _spaceRe = RegExp(r'\s+');
final _searchCountRe = RegExp(r'相关搜索结果[（(](\d+)[)）]');
final _watermarkUrlRe = RegExp(
  r'^\(?https?://(www\.)?huanmengacg\.com/?\)?$',
  caseSensitive: false,
);

/// Dart-side www.huanmengacg.com client (anonymous HTML scrape).
class HuanmengClient {
  HuanmengClient._();
  static final HuanmengClient instance = HuanmengClient._();

  final _http = NovelHttp(defaultReferer: '$_base/');
  final _bookCache = <String, Map<String, dynamic>>{};
  final _catalogCache = <String, Map<String, dynamic>>{};

  bool _sessionReady = false;
  DateTime? _sessionAt;

  Future<void> init() async {
    try {
      await ensureSession();
      Log.info('Huanmeng', 'HTTP session ready');
    } on CloudflareException catch (e) {
      Log.warning(
        'Huanmeng',
        'Cloudflare on bootstrap (${e.url}); verify when browsing',
      );
    } catch (e) {
      Log.warning('Huanmeng', 'bootstrap: $e');
    }
  }

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

  String _coverOf(Element? root, String? fallbackHref) {
    final img = root?.querySelector('img');
    var cover = preferHttps(absUrl(
      _base,
      img?.attributes['data-original'] ?? img?.attributes['src'],
    ));
    if (cover.isEmpty && fallbackHref != null) {
      cover = preferHttps(absUrl(_base, fallbackHref));
    }
    if (cover.contains('/template/')) return '';
    return cover;
  }

  bool _isWatermark(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    if (t.contains('本文来自') && t.contains('幻梦')) return true;
    if (_watermarkUrlRe.hasMatch(t)) return true;
    if (t.contains('书籍已下架') || t.contains('因版权问题')) return true;
    if (t.contains('书籍下架通知')) return true;
    return false;
  }

  List<Map<String, dynamic>> _parseBookCards(Document doc) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final a in doc.querySelectorAll('a.bigpic-book-name')) {
      final href = a.attributes['href'] ?? '';
      final aid = _extractAid(href);
      var name = cleanText(a.text).replaceFirst(RegExp(r'^\d+[、.．]\s*'), '');
      if (aid.isEmpty || name.isEmpty || !seen.add(aid)) continue;

      Element? block = a.parent;
      for (var i = 0; i < 6 && block != null; i++) {
        if (block.localName == 'dl' ||
            block.classes.contains('so-book') ||
            block.querySelector('img') != null) {
          break;
        }
        block = block.parent;
      }

      var author = '';
      final dd = block?.querySelector('dd');
      if (dd != null) {
        for (final p in dd.querySelectorAll('p')) {
          final t = cleanText(p.text);
          if (t.isEmpty) continue;
          if (p.querySelector('.red-lx, .red-lxa') != null) continue;
          if (p.classes.contains('big-book-info')) continue;
          if (t.length <= 40) {
            author = t;
            break;
          }
        }
      }

      final status = cleanText(block?.querySelector('.red-lxa')?.text);
      final tags = cleanText(block?.querySelector('.red-lx')?.text);
      final intro = cleanText(block?.querySelector('.big-book-info')?.text);
      final cover = _coverOf(block, null);

      items.add({
        'aid': aid,
        'name': name,
        'author': author,
        'author_raw': author,
        'cover': cover,
        'status': status,
        'tags': tags,
        'intro': intro,
      });
    }

    if (items.isNotEmpty) return items;

    for (final a in doc.querySelectorAll('a[href*="/book/info/"]')) {
      final href = a.attributes['href'] ?? '';
      final aid = _extractAid(href);
      final name = cleanText(a.attributes['title'] ?? a.text)
          .replaceFirst(RegExp(r'^\d+[、.．]\s*'), '');
      if (aid.isEmpty || name.length < 2 || !seen.add(aid)) continue;
      if (name == '书籍详情' || name == '立刻阅读' || name == '立即阅读') continue;
      Element? block = a.parent;
      for (var i = 0; i < 5 && block != null; i++) {
        if (block.querySelector('img') != null) break;
        block = block.parent;
      }
      items.add({
        'aid': aid,
        'name': name,
        'author': '',
        'author_raw': '',
        'cover': _coverOf(block, null),
      });
    }
    return items;
  }

  String _listUrl(String path, int page) {
    if (page <= 1) return '$_base$path';
    if (path.contains('/custom/top')) {
      return '$_base$path';
    }
    return '$_base$path/page/$page';
  }

  Future<Map<String, dynamic>> rank(String type, int page) async {
    await ensureSession();
    final path = _rankPaths[type] ?? _rankPaths['allvisit']!;
    final res = await _http.getHtml(_listUrl(path, page));
    final doc = parseHtml(res.html);
    final items = _parseBookCards(doc);
    final pagerMax = parseHtmlMaxPage(doc);
    final isTop = path.contains('/custom/top');
    final maxPage = isTop
        ? 1
        : inferMaxPage(
            page,
            items.length,
            fullPageSize: 30,
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

  Future<Map<String, dynamic>> home() async {
    await ensureSession();
    final res = await _http.getHtml('$_base/');
    final doc = parseHtml(res.html);
    final sections = <Map<String, dynamic>>[];
    final seenTitles = <String>{};

    for (final h2 in doc.querySelectorAll('h2')) {
      final title = cleanText(h2.text);
      if (title.isEmpty || title.length > 24) continue;
      if (!seenTitles.add(title)) continue;

      Element? box = h2.parent;
      for (var i = 0; i < 6 && box != null; i++) {
        if (box.querySelectorAll('a[href*="/book/info/"]').length >= 3) break;
        box = box.parent;
      }
      if (box == null) continue;

      final items = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final a in box.querySelectorAll('a[href*="/book/info/"]')) {
        final href = a.attributes['href'] ?? '';
        final aid = _extractAid(href);
        if (aid.isEmpty || !seen.add(aid)) continue;
        var name = cleanText(a.attributes['title'] ?? a.text);
        if (name.length < 2) {
          final img = a.querySelector('img');
          name = cleanText(img?.attributes['alt']);
        }
        if (name.length < 2 ||
            name == '书籍详情' ||
            name == '立刻阅读' ||
            name == '立即阅读') {
          continue;
        }
        Element? card = a.parent;
        for (var i = 0; i < 4 && card != null; i++) {
          if (card.querySelector('img') != null) break;
          card = card.parent;
        }
        items.add({
          'aid': aid,
          'name': name,
          'cover': _coverOf(card ?? a, null),
          'author': '',
          'author_raw': '',
        });
      }
      if (items.length < 3) continue;
      sections.add({'title': title, 'items': items});
    }
    return {'sections': sections};
  }

  Future<Map<String, dynamic>> search(
    String keyword,
    String type,
    int page,
  ) async {
    await ensureSession();
    // Site search form only exposes a single keyword box (title/author mixed).
    // Pagination is not reliably exposed in HTML; return first page only.
    final url =
        '$_base/index.php/book/search?action=search&key=${Uri.encodeQueryComponent(keyword)}';
    final res = await _http.getHtml(url);
    final doc = parseHtml(res.html);
    final items = _parseBookCards(doc);
    final countM = _searchCountRe.firstMatch(doc.body?.text ?? '');
    final total = int.tryParse(countM?.group(1) ?? '');
    // Without working page links, keep max_page at 1.
    return {
      'type': type,
      'keyword': keyword,
      'page': page <= 1 ? 1 : page,
      'total': total,
      'max_page': 1,
      'items': page <= 1 ? items : <Map<String, dynamic>>[],
    };
  }

  Future<Map<String, dynamic>> bookDetail(String aid) async {
    if (_bookCache.containsKey(aid)) return Map.from(_bookCache[aid]!);
    await ensureSession();
    final res = await _http.getHtml('$_base/index.php/book/info/$aid');
    final doc = parseHtml(res.html);
    var name = _meta(doc, ['og:novel:book_name', 'og:title']) ?? '';
    if (name.isEmpty) {
      name = cleanText(doc.querySelector('h1')?.text);
    }
    final authorRaw = _meta(doc, ['og:novel:author', 'author']) ?? '';
    final category = _meta(doc, ['og:novel:category']) ?? '';
    final status = _meta(doc, ['og:novel:status']) ?? '';
    final updateTime = _meta(doc, ['og:novel:update_time']);
    final lastChapter = _meta(doc, ['og:novel:latest_chapter_name']);
    var cover = preferHttps(absUrl(_base, _meta(doc, ['og:image'])));
    if (cover.contains('/template/')) cover = '';
    var intro = _meta(doc, ['og:description', 'description']) ?? '';
    if (intro.isEmpty) {
      final dec = doc.querySelector(
        '.book-intro, .intro, .book-dec, #intro, .big-book-info, .book-info',
      );
      intro = cleanText(dec?.text);
    }
    // Prefer longer on-page blurb if meta is truncated.
    for (final sel in [
      '.book-intro',
      '.intro',
      '.book-dec',
      '#intro',
      '.big-book-info',
    ]) {
      final el = doc.querySelector(sel);
      final t = cleanText(el?.text);
      if (t.length > intro.length) intro = t;
    }
    intro = intro.replaceFirst(RegExp(r'^.*?内容简介[：:]'), '').trim();
    // Drop site keyword stuffing from meta description.
    if (intro.contains('小说是作者') && intro.length < 80) {
      intro = '';
    }
    final data = <String, dynamic>{
      'aid': aid,
      'name': name.isEmpty ? '小说_$aid' : name,
      'category': category,
      'author_raw': authorRaw,
      'author': '作者:$authorRaw/分类:$category',
      'status': status,
      'update_time': updateTime,
      'last_chapter': lastChapter,
      'tags': category,
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
    await ensureSession();
    final res = await _http.getHtml('$_base/index.php/book/info/$aid');
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

    for (final vol in doc.querySelectorAll('.vol-group')) {
      final volName = cleanText(vol.querySelector('.vol-name')?.text);
      final chapters = <Map<String, dynamic>>[];
      var seq = 0;
      for (final a in vol.querySelectorAll('.vol-chapter-list a')) {
        final href = a.attributes['href'] ?? '';
        final m = _readRe.firstMatch(href);
        if (m == null || m.group(1) != aid) continue;
        final cid = m.group(2)!;
        final chapTitle = cleanText(a.text);
        if (chapTitle.isEmpty) continue;
        seq++;
        chapters.add({
          'seq': seq,
          'title': chapTitle,
          'cid': cid,
          'url': absUrl(_base, href),
        });
      }
      if (chapters.isEmpty) continue;
      (catalog['volumes'] as List).add({
        'vol_num': (catalog['volumes'] as List).length + 1,
        'name': volName.isEmpty
            ? '第${(catalog['volumes'] as List).length + 1}卷'
            : volName,
        'chapters': chapters,
      });
    }

    if ((catalog['volumes'] as List).isEmpty) {
      // Fallback: flat chapter list
      final chapters = <Map<String, dynamic>>[];
      var seq = 0;
      final seen = <String>{};
      for (final a in doc.querySelectorAll('a[href*="book_read_"]')) {
        final href = a.attributes['href'] ?? '';
        final m = _readRe.firstMatch(href);
        if (m == null || m.group(1) != aid) continue;
        final cid = m.group(2)!;
        if (!seen.add(cid)) continue;
        final chapTitle = cleanText(a.text);
        if (chapTitle.isEmpty || chapTitle == '立即阅读') continue;
        seq++;
        chapters.add({
          'seq': seq,
          'title': chapTitle,
          'cid': cid,
          'url': absUrl(_base, href),
        });
      }
      if (chapters.isNotEmpty) {
        (catalog['volumes'] as List).add({
          'vol_num': 1,
          'name': '目录',
          'chapters': chapters,
        });
      }
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

  String _chapterTitleFromDoc(Document doc, String fallback) {
    final title = cleanText(doc.querySelector('title')?.text);
    // 「书名_章节标题在线无广告版阅读-幻梦轻小说」
    final m = RegExp(r'_(.+?)在线').firstMatch(title);
    if (m != null) {
      final t = cleanText(m.group(1));
      if (t.isNotEmpty) return t;
    }
    for (final h in doc.querySelectorAll('h1, h2')) {
      final t = cleanText(h.text);
      if (t.isEmpty || _isWatermark(t) || t.contains('下架')) continue;
      return t;
    }
    return fallback;
  }

  Map<String, dynamic> _parseChapterPage(String html, String fallbackTitle) {
    final doc = parseHtml(html);
    final pageTitle = _chapterTitleFromDoc(doc, fallbackTitle);
    final content = doc.querySelector('#content') ?? doc.querySelector('#article');
    final lines = <String>[];
    final images = <String>[];

    if (content != null) {
      final ordered = <({int order, String text, List<String> imgs})>[];
      var fallbackIdx = 0;
      for (final p in content.querySelectorAll('p')) {
        final style = p.attributes['style'] ?? '';
        final om = _orderRe.firstMatch(style);
        final order = om != null ? int.parse(om.group(1)!) : (100000 + fallbackIdx);
        fallbackIdx++;
        final text = cleanText(p.text);
        final imgs = <String>[];
        for (final img in p.querySelectorAll('img')) {
          final src = preferHttps(absUrl(
            _base,
            img.attributes['data-src'] ??
                img.attributes['data-original'] ??
                img.attributes['src'],
          ));
          if (src.isNotEmpty) imgs.add(src);
        }
        if ((text.isEmpty || _isWatermark(text)) && imgs.isEmpty) continue;
        ordered.add((order: order, text: text, imgs: imgs));
      }
      ordered.sort((a, b) => a.order.compareTo(b.order));
      for (final row in ordered) {
        if (row.text.isNotEmpty && !_isWatermark(row.text)) {
          if (row.text.replaceAll(_spaceRe, '').isNotEmpty) {
            lines.add(row.text);
          }
        }
        for (final src in row.imgs) {
          if (!images.contains(src)) images.add(src);
          if (!lines.contains(src)) lines.add(src);
        }
      }

      if (lines.isEmpty) {
        for (final img in content.querySelectorAll('img')) {
          final src = preferHttps(absUrl(
            _base,
            img.attributes['data-src'] ??
                img.attributes['data-original'] ??
                img.attributes['src'],
          ));
          if (src.isNotEmpty && !images.contains(src)) {
            images.add(src);
            lines.add(src);
          }
        }
      }
    }

    return {
      'page_title': pageTitle,
      'lines': lines,
      'images': images,
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
    final url = '$_base/index.php/book_read_${aid}_$cid.html';
    final res = await _http.getHtml(url);
    if (res.html.contains('书籍已下架') &&
        !res.html.contains('style="order:')) {
      throw Exception('章节已下架或不可用');
    }
    final parsed = _parseChapterPage(
      res.html,
      chap['title']?.toString() ?? '',
    );
    final lines = (parsed['lines'] as List).cast<String>();
    if (lines.isEmpty) {
      throw Exception('章节正文为空');
    }
    return {
      'aid': aid,
      'cid': cid,
      'vol_num': volNum,
      'chap_num': chapNum,
      'title': parsed['page_title'],
      'volume': vol['name'],
      'content': lines.join('\n'),
      'lines': lines,
      'images': parsed['images'],
    };
  }
}
