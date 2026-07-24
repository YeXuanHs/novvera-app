import 'package:html/parser.dart' as html_parser;
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/cloudflare.dart';

const _base = 'https://www.huanmengacg.com';

/// Official bookapi password from the site's published Legado source (9.0).
const _apiPassword = 'chiyu666';

const _apiUa =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/// Genre tags + 排行 / 完本 (same IDs as site / bookapi `tags=`).
const _rankTypes = <String, String>{
  'top': '最新',
  'done': '完本',
  'serializing': '连载',
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

final _volPrefixRe = RegExp(
  r'^(第.+?卷|特别篇|番外|短篇|全一卷|幕间)',
);
final _spaceRe = RegExp(r'\s+');
final _watermarkUrlRe = RegExp(
  r'^\(?https?://(www\.)?huanmengacg\.com/?\)?$',
  caseSensitive: false,
);
final _htmlEntityRe = RegExp(r'&#(\d+);');

/// Huanmeng client via official `/index.php/bookapi/*` (Legado 9.0 API).
class HuanmengClient {
  HuanmengClient._();
  static final HuanmengClient instance = HuanmengClient._();

  final _http = NovelHttp(defaultReferer: '$_base/');
  final _bookCache = <String, Map<String, dynamic>>{};
  final _catalogCache = <String, Map<String, dynamic>>{};

  Map<String, String> get _headers => {
        'User-Agent': _apiUa,
        'Referer': '$_base/',
      };

  Future<void> init() async {
    try {
      // Warm cookies; CF may still challenge later.
      await _apiGet('/index.php/bookapi/search', {'page': '1', 'size': '1'});
      Log.info('Huanmeng', 'bookapi ready');
    } on CloudflareException catch (e) {
      Log.warning(
        'Huanmeng',
        'Cloudflare on bootstrap (${e.url}); verify when browsing',
      );
    } catch (e) {
      Log.warning('Huanmeng', 'bootstrap: $e');
    }
  }

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
    if (code != null && code != 0 && code != 200 && code != '0' && code != '200') {
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
    String? tags,
    String? state,
    required int page,
    int size = 20,
  }) async {
    final q = <String, String>{
      'page': '$page',
      'size': '$size',
    };
    if (key != null && key.isNotEmpty) q['key'] = key;
    if (tags != null && tags.isNotEmpty) q['tags'] = tags;
    if (state != null && state.isNotEmpty) q['state'] = state;
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

  Future<Map<String, dynamic>> rank(String type, int page) async {
    String? tags;
    String? state;
    if (type == 'done') {
      state = '2';
    } else if (type == 'serializing') {
      state = '1';
    } else if (type.startsWith('tag_')) {
      tags = type.substring(4);
    }
    // `top` / unknown → latest list (no filter)
    final res = await _searchApi(tags: tags, state: state, page: page);
    return {
      'type': type,
      'type_name': _rankTypes[type] ?? type,
      'page': page,
      'pager_max': res.maxPage,
      'max_page': res.maxPage,
      'items': res.items,
    };
  }

  Future<Map<String, dynamic>> home() async {
    final sections = <Map<String, dynamic>>[];
    Future<void> add(String title, Future<({List<Map<String, dynamic>> items, int maxPage, int? total})> Function() load) async {
      try {
        final r = await load();
        if (r.items.isEmpty) return;
        sections.add({'title': title, 'items': r.items});
      } catch (e) {
        Log.warning('Huanmeng', 'home $title: $e');
      }
    }

    await add('最新更新', () => _searchApi(page: 1, size: 20));
    await add('连载中', () => _searchApi(state: '1', page: 1, size: 20));
    await add('已完结', () => _searchApi(state: '2', page: 1, size: 20));
    await add('穿越', () => _searchApi(tags: '16', page: 1, size: 20));
    await add('恋爱', () => _searchApi(tags: '3', page: 1, size: 20));

    return {'sections': sections};
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

  /// Cover URL from detail API.
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
