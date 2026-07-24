import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/cloudflare.dart';

const _base = 'https://www.huanmengacg.com';

/// Official bookapi password from the site's published Legado source (9.0).
const _apiPassword = 'chiyu666';

const _apiUa =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/// Board + genre labels (match site nav / category pages).
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
  'tag_50': '暂未分类',
};

final _rankPaths = <String, String>{
  'top': '/index.php/custom/top',
  'done': '/index.php/book/category/finish/2',
  for (var i = 1; i <= 50; i++) 'tag_$i': '/index.php/book/category/tags/$i',
};

final _aidRe = RegExp(r'/book/info/(\d+)');
final _volPrefixRe = RegExp(
  r'^(第.+?卷|特别篇|番外|短篇|全一卷|幕间)',
);
final _spaceRe = RegExp(r'\s+');
final _rankPrefixRe = RegExp(r'^\d+[、．.\s]+');
final _watermarkUrlRe = RegExp(
  r'^\(?https?://(www\.)?huanmengacg\.com/?\)?$',
  caseSensitive: false,
);
final _htmlEntityRe = RegExp(r'&#(\d+);');

const _junkNames = {'书籍详情', '立刻阅读', '立即阅读', '更多'};

/// Huanmeng: homepage + category via HTML; search/detail/toc/body via bookapi.
class HuanmengClient {
  HuanmengClient._();
  static final HuanmengClient instance = HuanmengClient._();

  final _http = NovelHttp(defaultReferer: '$_base/');
  final _bookCache = <String, Map<String, dynamic>>{};
  final _catalogCache = <String, Map<String, dynamic>>{};

  bool _sessionReady = false;
  DateTime? _sessionAt;

  Map<String, String> get _headers => {
        'User-Agent': _apiUa,
        'Referer': '$_base/',
      };

  Future<void> init() async {
    try {
      await ensureSession();
      Log.info('Huanmeng', 'session ready (HTML + bookapi)');
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

  // ── HTML helpers (发现 / 分类) ───────────────────────────────────────────

  String _extractAid(String href) {
    final m = _aidRe.firstMatch(href);
    return m?.group(1) ?? '';
  }

  String _imgSrc(Element? img) {
    if (img == null) return '';
    var cover = lazyImgSrc(img, _base);
    if (cover.isEmpty ||
        cover.contains('/template/') ||
        _isJunkCover(cover) ||
        _isPlaceholderCover(cover)) {
      return '';
    }
    return cover;
  }

  bool _isPlaceholderCover(String url) {
    final u = url.toLowerCase();
    if (u.startsWith('data:')) return true;
    const bad = [
      'placeholder',
      'loading',
      'lazy',
      'nopic',
      'no_cover',
      'nocover',
      'default_cover',
      'blank',
      'spacer',
      '1x1',
      'pixel.gif',
      'transparent',
    ];
    for (final b in bad) {
      if (u.contains(b)) return true;
    }
    return false;
  }

  bool _isJunkCover(String url) {
    final u = url.toLowerCase();
    if (u.contains('/img/48028.')) return true;
    if (RegExp(r'/img/\d+\.(jpe?g|png|webp)(\?|$)').hasMatch(u)) return true;
    return false;
  }

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

    for (final dl in doc.querySelectorAll('dl')) {
      final a = dl.querySelector(
        'a.bigpic-book-name, a.book-name, a[href*="/book/info/"]',
      );
      if (a == null) continue;
      put(_extractAid(a.attributes['href'] ?? ''), _authorInCard(dl));
    }

    return map;
  }

  List<Map<String, dynamic>> _parseBookCards(Document doc) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    final coverIndex = _buildCoverIndex(doc);
    final authorIndex = _buildAuthorIndex(doc);

    for (final a in doc.querySelectorAll('a.bigpic-book-name')) {
      final href = a.attributes['href'] ?? '';
      final aid = _extractAid(href);
      var name = cleanText(a.text).replaceFirst(_rankPrefixRe, '');
      if (aid.isEmpty || name.isEmpty || !seen.add(aid)) continue;
      if (_junkNames.contains(name)) continue;

      Element? block = a.parent;
      for (var i = 0; i < 6 && block != null; i++) {
        if (block.localName == 'dl') break;
        block = block.parent;
      }
      block ??= a.parent;

      var author = _authorInCard(block!);
      if (author.isEmpty) author = authorIndex[aid] ?? '';
      final status = cleanText(block.querySelector('.red-lxa, .red-lx')?.text);
      var cover = _coverInCard(block, aid);
      if (cover.isEmpty) cover = coverIndex[aid] ?? '';
      if (cover.isEmpty) cover = huanmengCoverUrl(aid);

      items.add({
        'aid': aid,
        'name': name,
        'author': author,
        'author_raw': author,
        'cover': cover,
        'status': status,
      });
    }

    if (items.isNotEmpty) return items;

    for (final a in doc.querySelectorAll('a[href*="/book/info/"]')) {
      final href = a.attributes['href'] ?? '';
      final aid = _extractAid(href);
      var name = cleanText(a.attributes['title'] ?? a.text)
          .replaceFirst(_rankPrefixRe, '');
      if (aid.isEmpty || name.length < 2 || !seen.add(aid)) continue;
      if (_junkNames.contains(name)) continue;
      Element? block = a.parent;
      for (var i = 0; i < 5 && block != null; i++) {
        if (block.localName == 'li' || block.localName == 'dl') break;
        block = block.parent;
      }
      block ??= a.parent;
      var cover = block != null ? _coverInCard(block, aid) : '';
      if (cover.isEmpty) cover = coverIndex[aid] ?? '';
      if (cover.isEmpty) cover = huanmengCoverUrl(aid);
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
    if (path.contains('/custom/top')) return '$_base$path';
    return '$_base$path/page/$page';
  }

  /// Category / board pages (排行、完本、题材 tags).
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

  /// Homepage recommendation blocks (热门书籍 / 本周好书 / …).
  Future<Map<String, dynamic>> home() async {
    await ensureSession();
    final res = await _http.getHtml('$_base/');
    final doc = parseHtml(res.html);
    final coverIndex = _buildCoverIndex(doc);
    final authorIndex = _buildAuthorIndex(doc);
    final sections = <Map<String, dynamic>>[];
    final seenTitles = <String>{};

    Element? sectionBox(Element h2) {
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
            cls.contains('Update-book') ||
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

    Map<String, dynamic>? itemFromCard(
      Element card,
      String aid,
      String name,
    ) {
      if (name.length < 2 || _junkNames.contains(name)) return null;
      var cover = _coverInCard(card, aid);
      if (cover.isEmpty) cover = coverIndex[aid] ?? '';
      if (cover.isEmpty) cover = huanmengCoverUrl(aid);
      var author = _authorInCard(card);
      if (author.isEmpty) author = authorIndex[aid] ?? '';
      return {
        'aid': aid,
        'name': name,
        'author': author,
        'author_raw': author,
        'cover': cover,
      };
    }

    for (final h2 in doc.querySelectorAll('h2')) {
      var title = cleanText(h2.text).replaceAll('更多', '').trim();
      if (title.isEmpty || title.length > 24) continue;
      if (!seenTitles.add(title)) continue;
      final box = sectionBox(h2);
      if (box == null) continue;

      final items = <Map<String, dynamic>>[];
      final seen = <String>{};

      // Prefer titled cards (精品推荐 / 排行样式).
      for (final a in box.querySelectorAll('a.bigpic-book-name')) {
        // Skip swiper clones when present.
        Element? host = a.parent;
        var skip = false;
        for (var i = 0; i < 5 && host != null; i++) {
          if (host.className.contains('swiper-slide-duplicate')) {
            skip = true;
            break;
          }
          host = host.parent;
        }
        if (skip) continue;

        final aid = _extractAid(a.attributes['href'] ?? '');
        final name = cleanText(a.text).replaceFirst(_rankPrefixRe, '');
        if (aid.isEmpty || !seen.add(aid)) continue;
        Element? card = a.parent;
        for (var i = 0; i < 6 && card != null; i++) {
          if (card.localName == 'dl' ||
              card.localName == 'li' ||
              card.className.contains('dg-wrapper') ||
              card.className.contains('book-block') ||
              card.className.contains('item')) {
            break;
          }
          card = card.parent;
        }
        card ??= a.parent!;
        final item = itemFromCard(card, aid, name);
        if (item != null) items.add(item);
      }

      // Fallback: any book/info link in section.
      if (items.length < 3) {
        for (final a in box.querySelectorAll('a[href*="/book/info/"]')) {
          Element? host = a.parent;
          var skip = false;
          for (var i = 0; i < 5 && host != null; i++) {
            if (host.className.contains('swiper-slide-duplicate')) {
              skip = true;
              break;
            }
            host = host.parent;
          }
          if (skip) continue;

          final aid = _extractAid(a.attributes['href'] ?? '');
          var name = cleanText(a.attributes['title'] ?? a.text)
              .replaceFirst(_rankPrefixRe, '');
          if (aid.isEmpty || name.length < 2 || !seen.add(aid)) continue;
          if (_junkNames.contains(name)) continue;
          Element? card = a.parent;
          for (var i = 0; i < 5 && card != null; i++) {
            if (card.localName == 'li' ||
                card.localName == 'dl' ||
                card.className.contains('img-box') ||
                card.className.contains('item') ||
                card.className.contains('dg-wrapper')) {
              break;
            }
            card = card.parent;
          }
          card ??= a.parent!;
          // Prefer img alt as title when link text is empty/short.
          if (name.length < 2) {
            name = cleanText(card.querySelector('img')?.attributes['alt']);
          }
          final item = itemFromCard(card, aid, name);
          if (item != null) items.add(item);
        }
      }

      if (items.length < 3) continue;
      sections.add({'title': title, 'items': items});
    }

    return {'sections': sections};
  }

  // ── bookapi (搜索 / 详情 / 目录 / 正文) ─────────────────────────────────

  String _apiUrl(String path, Map<String, String> query) {
    final q = <String, String>{'password': _apiPassword, ...query};
    return Uri.parse('$_base$path').replace(queryParameters: q).toString();
  }

  Future<Map<String, dynamic>> _apiGet(
    String path,
    Map<String, String> query,
  ) async {
    final url = _apiUrl(path, query);
    final json = await _http.getJson(url, headers: _headers);
    final code = json['code'];
    if (code != null &&
        code != 0 &&
        code != 200 &&
        code != '0' &&
        code != '200' &&
        code != 1 &&
        code != '1') {
      final msg = (json['msg'] ?? json['message'] ?? 'API error').toString();
      throw Exception(msg);
    }
    return json;
  }

  String _decodeEntities(String s) {
    var out = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&#8231;', '·')
        .replaceAll('&#8231', '·');
    out = out.replaceAllMapped(_htmlEntityRe, (m) {
      final n = int.tryParse(m.group(1)!);
      if (n == null) return m.group(0)!;
      return String.fromCharCode(n);
    });
    return cleanText(out);
  }

  bool _isWatermark(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    if (t.contains('本文来自') && t.contains('幻梦')) return true;
    if (_watermarkUrlRe.hasMatch(t)) return true;
    if (t.contains('书籍已下架') || t.contains('因版权问题')) return true;
    if (t.contains('书籍下架通知')) return true;
    if (t.contains('aifun.ltd') || t.contains('AI风月')) return true;
    return false;
  }

  Map<String, dynamic> _mapBook(Map raw) {
    final aid = '${raw['id'] ?? ''}'.trim();
    final name = _decodeEntities('${raw['name'] ?? ''}');
    final author = _decodeEntities('${raw['author'] ?? ''}');
    var cover = preferHttps('${raw['pic'] ?? raw['picx'] ?? ''}'.trim());
    if (cover.isEmpty && aid.isNotEmpty) cover = huanmengCoverUrl(aid);
    final status = _decodeEntities('${raw['state'] ?? ''}');
    final tags = _decodeEntities('${raw['tags'] ?? raw['kind'] ?? ''}');
    final intro = _decodeEntities('${raw['intro'] ?? ''}');
    return {
      'aid': aid,
      'name': name,
      'author': author,
      'author_raw': author,
      'cover': cover,
      'status': status,
      'tags': tags,
      'intro': intro,
    };
  }

  Future<({List<Map<String, dynamic>> items, int maxPage, int? total})>
      _searchApi({
    String? key,
    required int page,
    int size = 20,
  }) async {
    final q = <String, String>{
      'page': '$page',
      'size': '$size',
    };
    if (key != null && key.isNotEmpty) q['key'] = key;
    final json = await _apiGet('/index.php/bookapi/search', q);
    final data = json['data'];
    final list = <Map<String, dynamic>>[];
    int? total;
    int pages = 1;
    if (data is Map) {
      total = int.tryParse('${data['total'] ?? ''}');
      pages = int.tryParse('${data['pages'] ?? 1}') ?? 1;
      final rawList = data['list'];
      if (rawList is List) {
        for (final e in rawList) {
          if (e is Map) list.add(_mapBook(Map<String, dynamic>.from(e)));
        }
      }
    }
    return (items: list, maxPage: pages < 1 ? 1 : pages, total: total);
  }

  Future<Map<String, dynamic>> search(
    String keyword,
    String type,
    int page,
  ) async {
    final key = keyword.trim();
    if (key.isEmpty) {
      return {
        'keyword': key,
        'type': type,
        'page': page,
        'max_page': 1,
        'items': <Map<String, dynamic>>[],
      };
    }
    final res = await _searchApi(key: key, page: page);
    return {
      'keyword': key,
      'type': type,
      'page': page,
      'pager_max': res.maxPage,
      'max_page': res.maxPage,
      'total': res.total,
      'items': res.items,
    };
  }

  Future<Map<String, dynamic>> bookDetail(String aid) async {
    if (_bookCache.containsKey(aid)) return Map.from(_bookCache[aid]!);
    final json = await _apiGet('/index.php/bookapi/detail', {'id': aid});
    final data = json['data'];
    if (data is! Map) throw Exception('详情为空');
    final mapped = _mapBook(Map<String, dynamic>.from(data));
    final kind = _decodeEntities('${data['kind'] ?? ''}');
    final tags = <String>[];
    for (final part in kind.split(RegExp(r'[,，、]'))) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('总字数') || t.startsWith('总点击')) continue;
      if (t == '连载' || t == '完结') continue;
      tags.add(t);
    }
    final info = <String, dynamic>{
      ...mapped,
      'update_time': '${data['addtime'] ?? ''}',
      'intro': mapped['intro'],
      'tags': tags.isEmpty ? mapped['tags'] : tags.join(','),
      'kind': kind,
      'hits': '${data['hits'] ?? ''}',
      'text_num': '${data['text_num'] ?? data['text'] ?? ''}',
    };
    _bookCache[aid] = Map.from(info);
    return info;
  }

  Future<String> resolveCoverUrl(String aid) async {
    final info = await bookDetail(aid);
    final c = (info['cover'] ?? '').toString().trim();
    if (c.startsWith('http')) return c;
    throw Exception('huanmeng cover missing for aid=$aid');
  }

  (String volume, String title) _splitVolumeTitle(String rawName) {
    final name = _decodeEntities(rawName);
    final m = _volPrefixRe.firstMatch(name);
    if (m == null) {
      return ('正文', name);
    }
    final vol = m.group(1)!;
    var title = name.substring(m.end).trim();
    title = title.replaceFirst(RegExp(r'^[·\-—_\s]+'), '').trim();
    if (title.isEmpty) title = vol;
    return (vol, title);
  }

  Future<Map<String, dynamic>> catalog(String aid) async {
    if (_catalogCache.containsKey(aid)) {
      return _catalogSummary(_catalogCache[aid]!);
    }
    final detail = await bookDetail(aid);
    final json = await _apiGet('/index.php/bookapi/chapters', {
      'id': aid,
      'size': '5000',
    });
    final data = json['data'];
    final rawList = data is Map ? data['list'] : null;
    if (rawList is! List || rawList.isEmpty) {
      throw Exception('目录为空');
    }

    final volMap = <String, List<Map<String, dynamic>>>{};
    final volOrder = <String>[];
    for (final e in rawList) {
      if (e is! Map) continue;
      final cid = '${e['id'] ?? ''}'.trim();
      final fullName = '${e['name'] ?? ''}'.trim();
      if (cid.isEmpty || fullName.isEmpty) continue;
      final (vol, title) = _splitVolumeTitle(fullName);
      final bucket = volMap.putIfAbsent(vol, () {
        volOrder.add(vol);
        return <Map<String, dynamic>>[];
      });
      bucket.add({
        'seq': bucket.length + 1,
        'title': title,
        'cid': cid,
        'full_title': _decodeEntities(fullName),
      });
    }

    final volumes = <Map<String, dynamic>>[];
    for (var i = 0; i < volOrder.length; i++) {
      final name = volOrder[i];
      volumes.add({
        'vol_num': i + 1,
        'name': name,
        'chapters': volMap[name]!,
      });
    }

    final catalog = <String, dynamic>{
      'aid': aid,
      'title': detail['name'] ?? '小说_$aid',
      'volumes': volumes,
    };
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

  Map<String, dynamic> _parseContentHtml(String html, String fallbackTitle) {
    final doc = html_parser.parse('<div id="root">$html</div>');
    final root = doc.querySelector('#root') ?? doc.body;
    final lines = <String>[];
    final images = <String>[];
    if (root == null) {
      return {'page_title': fallbackTitle, 'lines': lines, 'images': images};
    }

    void addText(String raw) {
      final t = cleanText(raw.replaceAll(RegExp(r'<[^>]+>'), ''));
      final decoded = _decodeEntities(t);
      if (decoded.isEmpty || _isWatermark(decoded)) return;
      if (decoded.replaceAll(_spaceRe, '').isEmpty) return;
      lines.add(decoded);
    }

    void addImg(String? src) {
      final u = preferHttps(absUrl(_base, src));
      if (u.isEmpty) return;
      if (!images.contains(u)) images.add(u);
      if (!lines.contains(u)) lines.add(u);
    }

    for (final p in root.querySelectorAll('p')) {
      for (final img in p.querySelectorAll('img')) {
        addImg(
          img.attributes['data-src'] ??
              img.attributes['data-original'] ??
              img.attributes['src'],
        );
      }
      addText(p.text);
    }
    if (lines.isEmpty) {
      for (final img in root.querySelectorAll('img')) {
        addImg(
          img.attributes['data-src'] ??
              img.attributes['data-original'] ??
              img.attributes['src'],
        );
      }
      if (lines.isEmpty) addText(root.text);
    }
    return {
      'page_title': fallbackTitle,
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
    final json = await _apiGet('/index.php/bookapi/content', {
      'bid': aid,
      'cid': cid,
    });
    final data = json['data'];
    if (data is! Map) throw Exception('章节正文为空');
    final pageTitle = _decodeEntities(
      '${data['name'] ?? chap['full_title'] ?? chap['title'] ?? ''}',
    );
    final contentHtml = '${data['content'] ?? ''}';
    if (contentHtml.contains('书籍已下架') && !contentHtml.contains('<img')) {
      throw Exception('章节已下架或不可用');
    }
    final parsed = _parseContentHtml(
      contentHtml,
      pageTitle.isNotEmpty ? pageTitle : (chap['title']?.toString() ?? ''),
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
