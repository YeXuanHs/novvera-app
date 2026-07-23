import 'package:html/dom.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/cloudflare.dart';

const _base = 'https://www.huanmengacg.com';

/// Site categories: genre tags + 排行 / 完本 (not wenku8-style click ranks).
const _rankTypes = <String, String>{
  'top': '排行',
  'done': '完本',
  'tag_1': '校园',
  'tag_2': '青春',
  'tag_3': '恋爱',
  'tag_4': '治愈',
  'tag_5': '群像',
  'tag_6': '竞技',
  'tag_7': '音乐',
  'tag_8': '美食',
  'tag_9': '旅行',
  'tag_10': '欢乐向',
  'tag_11': '经营',
  'tag_12': '职场',
  'tag_13': '斗智',
  'tag_14': '脑洞',
  'tag_15': '宅文化',
  'tag_16': '穿越',
  'tag_17': '奇幻',
  'tag_18': '魔法',
  'tag_19': '异能',
  'tag_20': '战斗',
  'tag_21': '科幻',
  'tag_22': '机战',
  'tag_23': '战争',
  'tag_24': '冒险',
  'tag_25': '龙傲天',
  'tag_26': '悬疑',
  'tag_27': '犯罪',
  'tag_28': '复仇',
  'tag_29': '黑暗',
  'tag_30': '猎奇',
  'tag_31': '惊悚',
  'tag_32': '间谍',
  'tag_33': '末日',
  'tag_34': '游戏',
  'tag_35': '大逃杀',
  'tag_36': '青梅竹马',
  'tag_37': '妹妹',
  'tag_38': '女儿',
  'tag_39': 'JK',
  'tag_40': 'JC',
  'tag_41': '大小姐',
  'tag_42': '性转',
  'tag_43': '伪娘',
  'tag_44': '人外',
  'tag_45': '后宫',
  'tag_46': '百合',
  'tag_47': '耽美',
  'tag_48': 'NTR',
  'tag_49': '女性视角',
};

final _rankPaths = <String, String>{
  'top': '/index.php/custom/top',
  'done': '/index.php/book/category/finish/2',
  for (var i = 1; i <= 49; i++) 'tag_$i': '/index.php/book/category/tags/$i',
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

  String _imgSrc(Element? img) {
    if (img == null) return '';
    var cover = preferHttps(absUrl(
      _base,
      img.attributes['data-original'] ?? img.attributes['src'],
    ));
    if (cover.isEmpty || cover.contains('/template/') || _isJunkCover(cover)) {
      return '';
    }
    return cover;
  }

  /// Site-wide decoy / CF-bait assets that are not book covers.
  bool _isJunkCover(String url) {
    final u = url.toLowerCase();
    if (u.contains('/img/48028.')) return true;
    // Bare /img/<digits>.(jpg|jpeg|png|webp) — shared assets, not /image/zijian/.
    if (RegExp(r'/img/\d+\.(jpe?g|png|webp)(\?|$)').hasMatch(u)) return true;
    return false;
  }

  /// Cover must come from this card only — never climb to a section parent.
  String _coverInCard(Element card, String aid) {
    for (final a in card.querySelectorAll('a[href*="/book/info/"]')) {
      if (_extractAid(a.attributes['href'] ?? '') != aid) continue;
      final c = _imgSrc(a.querySelector('img'));
      if (c.isNotEmpty) return c;
    }
    final aids = <String>{};
    for (final a in card.querySelectorAll('a[href*="/book/info/"]')) {
      final id = _extractAid(a.attributes['href'] ?? '');
      if (id.isNotEmpty) aids.add(id);
    }
    if (aids.length == 1 && aids.contains(aid)) {
      return _imgSrc(card.querySelector('img'));
    }
    return '';
  }

  String _authorInCard(Element card) {
    final labeled = card.querySelector(
      '.book-author, .dg-booka2, .author, .author-text',
    );
    if (labeled != null) {
      final t = cleanText(labeled.text);
      if (t.isNotEmpty) return t;
    }
    final dd = card.querySelector('dd');
    final scope = dd ?? card;
    for (final p in scope.querySelectorAll('p')) {
      final t = cleanText(p.text);
      if (t.isEmpty || t.length > 40) continue;
      if (p.classes.contains('big-book-info')) continue;
      if (p.querySelector('.red-lx, .red-lxa, .red-2x, .fa-heart') != null) {
        continue;
      }
      if (RegExp(r'^[\d.]+$').hasMatch(t)) continue;
      if (t == '连载' || t == '完结') continue;
      return t;
    }
    return '';
  }

  /// Page-wide aid → cover from any `a[href*=book/info/N] img`.
  Map<String, String> _buildCoverIndex(Document doc) {
    final map = <String, String>{};
    for (final a in doc.querySelectorAll('a[href*="/book/info/"]')) {
      final aid = _extractAid(a.attributes['href'] ?? '');
      if (aid.isEmpty || map.containsKey(aid)) continue;
      final c = _imgSrc(a.querySelector('img'));
      if (c.isNotEmpty) map[aid] = c;
    }
    return map;
  }

  Map<String, String> _buildAuthorIndex(Document doc) {
    final map = <String, String>{};

    void put(String aid, String author) {
      if (aid.isEmpty || author.isEmpty || map.containsKey(aid)) return;
      map[aid] = author;
    }

    for (final el in doc.querySelectorAll('.book-author, .dg-booka2')) {
      final author = cleanText(el.text);
      Element? host = el.parent;
      for (var i = 0; i < 6 && host != null; i++) {
        final a = host.querySelector('a[href*="/book/info/"]');
        if (a != null) {
          put(_extractAid(a.attributes['href'] ?? ''), author);
          break;
        }
        host = host.parent;
      }
    }

    for (final li in doc.querySelectorAll('li')) {
      final a = li.querySelector(
            'h3 a[href*="/book/info/"], a.book-name, a.bigpic-book-name',
          ) ??
          li.querySelector('a[href*="/book/info/"]');
      if (a == null) continue;
      final aid = _extractAid(a.attributes['href'] ?? '');
      if (aid.isEmpty || map.containsKey(aid)) continue;
      final author = _authorInCard(li);
      put(aid, author);
    }

    for (final dl in doc.querySelectorAll('dl')) {
      final a = dl.querySelector(
        'a.bigpic-book-name, a.book-name, a[href*="/book/info/"]',
      );
      if (a == null) continue;
      put(_extractAid(a.attributes['href'] ?? ''), _authorInCard(dl));
    }

    return map;
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
    final coverIndex = _buildCoverIndex(doc);
    final authorIndex = _buildAuthorIndex(doc);

    for (final a in doc.querySelectorAll('a.bigpic-book-name')) {
      final href = a.attributes['href'] ?? '';
      final aid = _extractAid(href);
      var name = cleanText(a.text).replaceFirst(RegExp(r'^\d+[、.．]\s*'), '');
      if (aid.isEmpty || name.isEmpty || !seen.add(aid)) continue;

      Element? block = a.parent;
      for (var i = 0; i < 6 && block != null; i++) {
        if (block.localName == 'dl') break;
        block = block.parent;
      }
      block ??= a.parent;

      var author = _authorInCard(block!);
      if (author.isEmpty) author = authorIndex[aid] ?? '';

      final status = cleanText(block.querySelector('.red-lxa')?.text);
      final tags = cleanText(block.querySelector('.red-lx')?.text);
      var cover = _coverInCard(block, aid);
      if (cover.isEmpty) cover = coverIndex[aid] ?? '';

      items.add({
        'aid': aid,
        'name': name,
        'author': author,
        'author_raw': author,
        'cover': cover,
        'status': status,
        'tags': tags,
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
        if (block.localName == 'li' || block.localName == 'dl') break;
        block = block.parent;
      }
      block ??= a.parent;
      var cover = block != null ? _coverInCard(block, aid) : '';
      if (cover.isEmpty) cover = coverIndex[aid] ?? '';
      var author = block != null ? _authorInCard(block) : '';
      if (author.isEmpty) author = authorIndex[aid] ?? '';
      items.add({
        'aid': aid,
        'name': name,
        'author': author,
        'author_raw': author,
        'cover': cover,
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
    final path = _rankPaths[type] ?? _rankPaths['top']!;
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
    final coverIndex = _buildCoverIndex(doc);
    final authorIndex = _buildAuthorIndex(doc);
    final sections = <Map<String, dynamic>>[];
    final seenTitles = <String>{};

    Element? _sectionBox(Element h2) {
      // Prefer known section containers over climbing too far.
      Element? el = h2.parent;
      for (var i = 0; i < 8 && el != null; i++) {
        final cls = el.className;
        if (cls.contains('listBook3') ||
            cls.contains('alone2') ||
            cls.contains('swiper3') ||
            cls.contains('listTab') ||
            cls.contains('list-book') ||
            cls.contains('bk-book') ||
            cls.contains('ruku-book') ||
            cls.contains('gexin-book') ||
            cls.contains('book-jp') ||
            cls.contains('listBook')) {
          return el;
        }
        el = el.parent;
      }
      Element? box = h2.parent;
      for (var i = 0; i < 6 && box != null; i++) {
        if (box.querySelectorAll('a[href*="/book/info/"]').length >= 3) {
          return box;
        }
        box = box.parent;
      }
      return null;
    }

    Map<String, dynamic>? _itemFromCard(
      Element card,
      String aid,
      String name,
    ) {
      if (name.length < 2 ||
          name == '书籍详情' ||
          name == '立刻阅读' ||
          name == '立即阅读') {
        return null;
      }
      var cover = _coverInCard(card, aid);
      if (cover.isEmpty) cover = coverIndex[aid] ?? '';
      var author = _authorInCard(card);
      if (author.isEmpty) author = authorIndex[aid] ?? '';
      return {
        'aid': aid,
        'name': name,
        'cover': cover,
        'author': author,
        'author_raw': author,
      };
    }

    for (final h2 in doc.querySelectorAll('h2')) {
      final title = cleanText(h2.text);
      if (title.isEmpty || title.length > 24) continue;
      if (!seenTitles.add(title)) continue;
      final box = _sectionBox(h2);
      if (box == null) continue;

      final items = <Map<String, dynamic>>[];
      final seen = <String>{};

      // Carousel cards (限时免费): title attr is often wrong; use .dg-booka1.
      for (final a in box.querySelectorAll('.dg-wrapper > a')) {
        final href = a.attributes['href'] ?? '';
        final aid = _extractAid(href);
        if (aid.isEmpty || !seen.add(aid)) continue;
        var name = cleanText(a.querySelector('.dg-booka1')?.text);
        if (name.length < 2) {
          name = cleanText(a.attributes['title'] ?? a.text);
        }
        final item = _itemFromCard(a, aid, name);
        if (item != null) items.add(item);
      }

      // Normal cards: li / dl units (do not climb past card for cover).
      for (final card in box.querySelectorAll(
        'li, dl.book-block, dl.listBook1, dl',
      )) {
        // Prefer title link over cover-only link.
        final titleA = card.querySelector(
              'a.book-name, a.bigpic-book-name, a.shelf-box, a.book-list-f, h3 a',
            ) ??
            card.querySelector('a[href*="/book/info/"]');
        if (titleA == null) continue;
        final href = titleA.attributes['href'] ?? '';
        final aid = _extractAid(href);
        if (aid.isEmpty || !seen.add(aid)) continue;
        var name = cleanText(titleA.attributes['title'] ?? titleA.text);
        if (name.length < 2) {
          name = cleanText(card.querySelector('img')?.attributes['alt']);
        }
        final item = _itemFromCard(card, aid, name);
        if (item != null) items.add(item);
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
    // Site exposes genre via og:novel:category; show as 标签 (not 分类).
    final tags = _meta(doc, ['og:novel:category']) ?? '';
    final status = _meta(doc, ['og:novel:status']) ?? '';
    final updateTime = _meta(doc, ['og:novel:update_time']);
    // og:image is often a shared junk asset (e.g. /img/48028.jpeg) behind CF.
    // Prefer the real cover on the page (.pic-img), same as search cards.
    var cover = '';
    for (final sel in [
      '.pic-img img',
      '.pic img',
      'dt img',
      '.book-img img',
    ]) {
      cover = _imgSrc(doc.querySelector(sel));
      if (cover.isNotEmpty) break;
    }
    if (cover.isEmpty) {
      for (final a in doc.querySelectorAll('a[href*="/book/info/$aid"]')) {
        cover = _imgSrc(a.querySelector('img'));
        if (cover.isNotEmpty) break;
      }
    }
    if (cover.isEmpty) {
      final og = preferHttps(absUrl(_base, _meta(doc, ['og:image'])));
      if (og.isNotEmpty &&
          !og.contains('/template/') &&
          !_isJunkCover(og)) {
        cover = og;
      }
    }
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
    // Only fields consumed by _loadComicInfo / cards. No 分类.
    final data = <String, dynamic>{
      'aid': aid,
      'name': name.isEmpty ? '小说_$aid' : name,
      'author_raw': authorRaw,
      'status': status,
      'update_time': updateTime,
      'tags': tags.isEmpty ? null : tags,
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
