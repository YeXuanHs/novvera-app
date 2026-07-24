import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/cloudflare.dart';

const _base = 'https://www.huanmengacg.com';

/// Official bookapi password from the site's published Legado source (9.0).
const _apiPassword = 'chiyu666';

/// Legado-published UA for bookapi.
const _apiUa =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/// Always scrape desktop HTML — mobile/WebView UA yields different markup
/// (broken titles / missing authors / different home sections).
const _htmlUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

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
final _watermarkUrlRe = RegExp(
  r'^\(?https?://(www\.)?huanmengacg\.com/?\)?$',
  caseSensitive: false,
);
final _htmlEntityRe = RegExp(r'&#(\d+);');
/// Site watermark bars only (`————————`, `====…`). Length ≥4 so normal
/// dialogue like `——这下…` / short `——` scene breaks are kept.
final _sepOnlyRe = RegExp(r'^[\s\-—–_=━─═]{4,}$');

/// Huanmeng: discover/category scrape **IDs only** (desktop HTML);
/// name/author/cover/intro via bookapi; search/detail/toc/body via bookapi.
class HuanmengClient {
  HuanmengClient._();
  static final HuanmengClient instance = HuanmengClient._();

  final _http = NovelHttp(defaultReferer: '$_base/');
  final _bookCache = <String, Map<String, dynamic>>{};
  final _catalogCache = <String, Map<String, dynamic>>{};

  bool _sessionReady = false;
  DateTime? _sessionAt;

  Map<String, String> get _apiHeaders => {
        'User-Agent': _apiUa,
        'Referer': '$_base/',
      };

  Map<String, String> get _htmlHeaders => {
        'User-Agent': _htmlUa,
        'Referer': '$_base/',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      };

  Future<void> init() async {
    try {
      await ensureSession();
      Log.info('Huanmeng', 'session ready (HTML ids + bookapi)');
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
    await _http.getHtml('$_base/', headers: _htmlHeaders);
    _sessionReady = true;
    _sessionAt = DateTime.now();
    return true;
  }

  // ── HTML: IDs only ──────────────────────────────────────────────────────

  String _extractAid(String href) => _aidRe.firstMatch(href)?.group(1) ?? '';

  bool _inSwiperClone(Element a) {
    Element? host = a.parent;
    for (var i = 0; i < 6 && host != null; i++) {
      if (host.className.contains('swiper-slide-duplicate')) return true;
      host = host.parent;
    }
    return false;
  }

  /// Ordered unique book IDs from a document or section subtree.
  List<String> _extractAids(Element root) {
    final aids = <String>[];
    final seen = <String>{};

    void consider(Element a) {
      if (_inSwiperClone(a)) return;
      final aid = _extractAid(a.attributes['href'] ?? '');
      if (aid.isEmpty || !seen.add(aid)) return;
      aids.add(aid);
    }

    final titled = root.querySelectorAll('a.bigpic-book-name');
    if (titled.isNotEmpty) {
      for (final a in titled) {
        consider(a);
      }
      return aids;
    }
    for (final a in root.querySelectorAll('a[href*="/book/info/"]')) {
      consider(a);
    }
    return aids;
  }

  Element? _sectionBox(Element h2) {
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

  String _listUrl(String path, int page) {
    if (page <= 1) return '$_base$path';
    if (path.contains('/custom/top')) return '$_base$path';
    return '$_base$path/page/$page';
  }

  /// Fill name/author/cover from bookapi detail (cached).
  Future<List<Map<String, dynamic>>> _enrichAids(List<String> aids) async {
    if (aids.isEmpty) return [];
    const chunk = 8;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < aids.length; i += chunk) {
      final end = (i + chunk > aids.length) ? aids.length : i + chunk;
      final slice = aids.sublist(i, end);
      final parts = await Future.wait(slice.map((aid) async {
        try {
          final info = await bookDetail(aid);
          return {
            'aid': aid,
            'name': '${info['name'] ?? ''}',
            'author': '${info['author'] ?? ''}',
            'author_raw': '${info['author'] ?? ''}',
            'cover': '${info['cover'] ?? ''}'.isNotEmpty
                ? '${info['cover']}'
                : huanmengCoverUrl(aid),
            'status': '${info['status'] ?? ''}',
            'intro': '${info['intro'] ?? ''}',
          };
        } catch (e) {
          Log.warning('Huanmeng', 'enrich aid=$aid: $e');
          return {
            'aid': aid,
            'name': '小说_$aid',
            'author': '',
            'author_raw': '',
            'cover': huanmengCoverUrl(aid),
          };
        }
      }));
      out.addAll(parts);
    }
    return out;
  }

  /// Category / board pages — scrape IDs, enrich via API.
  Future<Map<String, dynamic>> rank(String type, int page) async {
    await ensureSession();
    final path = _rankPaths[type] ?? _rankPaths['top']!;
    final res = await _http.getHtml(
      _listUrl(path, page),
      headers: _htmlHeaders,
    );
    final doc = parseHtml(res.html);
    final aids = _extractAids(doc.documentElement ?? doc.body!);
    final items = await _enrichAids(aids);
    final pagerMax = parseHtmlMaxPage(doc);
    final isTop = path.contains('/custom/top');
    final maxPage = isTop
        ? 1
        : inferMaxPage(
            page,
            aids.length,
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

  /// Homepage blocks — scrape IDs per section, enrich via API.
  Future<Map<String, dynamic>> home() async {
    await ensureSession();
    final res = await _http.getHtml('$_base/', headers: _htmlHeaders);
    final doc = parseHtml(res.html);

    // Delete「限时免费」整块节点（swiper 易串封面/标题），不是循环里 continue。
    for (final h2 in List<Element>.from(doc.querySelectorAll('h2'))) {
      final title = cleanText(h2.text).replaceAll('更多', '').trim();
      if (title != '限时免费') continue;
      final box = _sectionBox(h2);
      (box ?? h2).remove();
    }

    final sectionAids = <({String title, List<String> aids})>[];
    final seenTitles = <String>{};
    final allAids = <String>[];
    final allSeen = <String>{};

    for (final h2 in doc.querySelectorAll('h2')) {
      final title = cleanText(h2.text).replaceAll('更多', '').trim();
      if (title.isEmpty || title.length > 24) continue;
      if (!seenTitles.add(title)) continue;
      final box = _sectionBox(h2);
      if (box == null) continue;
      final aids = _extractAids(box);
      if (aids.length < 3) continue;
      sectionAids.add((title: title, aids: aids));
      for (final id in aids) {
        if (allSeen.add(id)) allAids.add(id);
      }
    }

    final enriched = await _enrichAids(allAids);
    final byId = {
      for (final b in enriched) '${b['aid']}': b,
    };

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
    final json = await _http.getJson(url, headers: _apiHeaders);
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
    // `————————` / `====` site banners look like a horizontal rule in the reader.
    if (_sepOnlyRe.hasMatch(t)) return true;
    if (t.contains('本文来自') && t.contains('幻梦')) return true;
    if (t.contains('最新最全的日本动漫轻小说')) return true;
    if (t.contains('更多轻小说') && t.contains('幻梦')) return true;
    if (t.contains('TG群') || t.contains('t.me/huanmeng')) return true;
    if (_watermarkUrlRe.hasMatch(t)) return true;
    if (t.contains('huanmengacg.com')) return true;
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
