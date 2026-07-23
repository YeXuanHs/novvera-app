import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/app_dio.dart';
import 'package:novvera/network/cloudflare.dart';
import 'package:novvera/utils/io.dart';

const _base = 'https://www.wenku8.net';
const _relay = 'https://wenku8-relay.mewx.org/';
const _apiAppVer = '1.29';
const _apiAppCode = 'digital-bento';
const _apiUa =
    'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 6 Build/TQ3A.230805.001)';
const _loginRefreshInterval = Duration(hours: 1);
const _searchPageSize = 10;

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

const _watermark = [
  '本文来自',
  '最新最全的日本动漫轻小说',
  '最新最全的日本動漫輕小說',
];

/// Dart-side wenku8 client.
///
/// Official App relay API for rankings / book meta / catalog / chapter text /
/// title·author·tag search. Homepage discover still uses website HTML
/// (with auto-register). Only fields consumed by the UI are returned.
class Wenku8Client {
  Wenku8Client._();
  static final Wenku8Client instance = Wenku8Client._();

  final _http = NovelHttp(defaultReferer: '$_base/');
  final _dio = AppDio();
  final _bookCache = <String, Map<String, dynamic>>{};
  final _catalogCache = <String, Map<String, dynamic>>{};

  String? username;
  String? password;
  DateTime? _lastLoginAt;
  Timer? _refreshTimer;
  String? _phpSessionId;

  File get _accountFile => File('${App.dataPath}/wenku8_account.json');

  Future<void> init() async {
    await _loadAccount();
    // Must not throw: NovelApiClient.init() Future.wait-s all sources.
    // A wenku8 CF block used to poison every later huanmeng/linovelib call
    // (init never marked ready → re-ran ensureAccount → Verify opened wenku8).
    try {
      await ensureAccount();
    } on CloudflareException catch (e) {
      Log.warning(
        'Wenku8',
        'Cloudflare on bootstrap (${e.url}); verify when browsing wenku8',
      );
    } catch (e) {
      Log.warning('Wenku8', 'bootstrap: $e');
    }
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_loginRefreshInterval, (_) {
      ensureAccount(forceLogin: true).catchError((Object e) {
        Log.warning('Wenku8', 'periodic ensureAccount: $e');
      });
    });
  }

  Future<void> _loadAccount() async {
    try {
      if (!await _accountFile.exists()) return;
      final map = jsonDecode(await _accountFile.readAsString()) as Map;
      username = map['username']?.toString();
      password = map['password']?.toString();
    } catch (e) {
      Log.warning('Wenku8', 'load account: $e');
    }
  }

  Future<void> _saveAccount() async {
    await Directory(App.dataPath).create(recursive: true);
    await _accountFile.writeAsString(jsonEncode({
      'username': username,
      'password': password,
      'saved_at': DateTime.now().toIso8601String(),
    }));
  }

  Future<bool> ensureAccount({bool forceLogin = false}) async {
    if (!forceLogin &&
        _lastLoginAt != null &&
        DateTime.now().difference(_lastLoginAt!) < _loginRefreshInterval) {
      return true;
    }
    try {
      if (username != null &&
          password != null &&
          username!.isNotEmpty &&
          password!.isNotEmpty) {
        if (await _login(username!, password!)) return true;
      }
      for (var i = 0; i < 3; i++) {
        final u = _randUser();
        final p = _randPass();
        if (await _register(u, p) && await _login(u, p)) {
          username = u;
          password = p;
          await _saveAccount();
          return true;
        }
      }
    } on CloudflareException catch (e) {
      Log.warning('Wenku8', 'ensureAccount blocked by Cloudflare (${e.url})');
      rethrow;
    }
    Log.warning('Wenku8', 'ensureAccount failed; continuing without login');
    return _lastLoginAt != null;
  }

  String _randUser() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return 'nv${List.generate(10, (_) => chars[r.nextInt(chars.length)]).join()}';
  }

  String _randPass() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random();
    return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<bool> _register(String user, String pass) async {
    try {
      final email = '$user${Random().nextInt(90) + 10}@gmail.com';
      final res = await _http.postForm(
        '$_base/register.php',
        {
          'username': user,
          'password': pass,
          'repassword': pass,
          'email': email,
          'viewemail': '1',
          'sex': '0',
          'qq': '',
          'url': '',
          'action': 'newuser',
          'submit': '注 册',
        },
        preferGbk: true,
        headers: {'Referer': '$_base/register.php'},
      );
      final ok = res.html.contains('注册成功') ||
          res.html.contains('恭喜') ||
          res.html.contains('欢迎您') ||
          res.html.contains('用户面板');
      Log.info('Wenku8', 'register $user -> $ok');
      return ok;
    } on CloudflareException {
      rethrow;
    } catch (e) {
      Log.warning('Wenku8', 'register: $e');
      return false;
    }
  }

  Future<bool> _login(String user, String pass) async {
    try {
      await _http.getHtml('$_base/login.php', preferGbk: true);
      final res = await _http.postForm(
        '$_base/login.php?do=submit&jumpurl=${Uri.encodeComponent('$_base/index.php')}',
        {
          'username': user,
          'password': pass,
          'usecookie': '315360000',
          'action': 'login',
          'submit': '登 录',
        },
        preferGbk: true,
        headers: {
          'Referer':
              '$_base/login.php?jumpurl=${Uri.encodeComponent('$_base/index.php')}',
        },
      );
      final ok = res.html.contains('欢迎您') || res.html.contains('用户面板');
      if (ok) {
        username = user;
        password = pass;
        _lastLoginAt = DateTime.now();
        await _saveAccount();
        Log.info('Wenku8', 'login ok ($user)');
      } else {
        Log.warning('Wenku8', 'login failed ($user)');
      }
      return ok;
    } on CloudflareException {
      rethrow;
    } catch (e) {
      Log.warning('Wenku8', 'login: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Official App relay API (MewX APK protocol)
  // ---------------------------------------------------------------------------

  String _buildAppVer() {
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ 60;
    final msg = '$_apiAppVer|$_apiAppCode|$bucket';
    final digest = Hmac(sha256, utf8.encode(_apiAppCode))
        .convert(utf8.encode(msg))
        .toString();
    return '$_apiAppVer-$_apiAppCode-${digest.substring(12, 20)}';
  }

  Future<String> _appApi(String plain) async {
    final request = base64.encode(utf8.encode(plain));
    final body =
        '&appver=${_buildAppVer()}&request=$request&timetoken=${DateTime.now().millisecondsSinceEpoch}';
    try {
      final res = await _dio.post<List<int>>(
        _relay,
        data: body,
        options: Options(
          responseType: ResponseType.bytes,
          contentType: 'application/x-www-form-urlencoded',
          headers: {
            'User-Agent': _apiUa,
            'Accept-Encoding': 'gzip',
            if (_phpSessionId != null && _phpSessionId!.isNotEmpty)
              'Cookie': 'PHPSESSID=$_phpSessionId',
          },
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null) {
        for (final c in setCookie) {
          final m = RegExp(r'PHPSESSID=([^;]+)').firstMatch(c);
          if (m != null && m.group(1)!.isNotEmpty) {
            _phpSessionId = m.group(1);
          }
        }
      }
      if ((res.statusCode ?? 0) != 200) {
        final err = utf8.decode(res.data ?? const [], allowMalformed: true);
        throw Exception('wenku8 API HTTP ${res.statusCode}: $err');
      }
      final bytes = Uint8List.fromList(res.data ?? const []);
      return utf8.decode(bytes, allowMalformed: true);
    } on DioException catch (e) {
      throw Exception('wenku8 API failed: $e');
    }
  }

  String _xmlAttr(String tag, String name) {
    final m = RegExp(
      '$name=[\'"]([^\'"]*)[\'"]',
      caseSensitive: false,
    ).firstMatch(tag);
    return m?.group(1) ?? '';
  }

  String _xmlDataValue(String block, String name) {
    final re = RegExp(
      '<data\\s+name=[\'"]$name[\'"]([^>]*)>(?:<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>|([^<]*))?</data>',
      caseSensitive: false,
    );
    final m = re.firstMatch(block);
    if (m == null) return '';
    final attrs = m.group(1) ?? '';
    final cdata = (m.group(2) ?? '').trim();
    if (cdata.isNotEmpty) return cdata;
    final text = (m.group(3) ?? '').trim();
    if (text.isNotEmpty) return text;
    return _xmlAttr(attrs, 'value');
  }

  String _xmlDataAttr(String block, String name, String attr) {
    final re = RegExp(
      '<data\\s+name=[\'"]$name[\'"]([^>/]*)/?>',
      caseSensitive: false,
    );
    final m = re.firstMatch(block);
    if (m == null) return '';
    return _xmlAttr(m.group(1) ?? '', attr);
  }

  List<Map<String, dynamic>> _parseNovelListItems(String xml) {
    final items = <Map<String, dynamic>>[];
    final re = RegExp(
      r'''<item\s+aid=['"](\d+)['"]>([\s\S]*?)</item>''',
      caseSensitive: false,
    );
    for (final m in re.allMatches(xml)) {
      final aid = m.group(1)!;
      final block = m.group(2)!;
      final name = _xmlDataValue(block, 'Title');
      final author = _xmlDataValue(block, 'Author').isNotEmpty
          ? _xmlDataValue(block, 'Author')
          : _xmlDataAttr(block, 'Author', 'value');
      final status = _xmlDataValue(block, 'BookStatus').isNotEmpty
          ? _xmlDataValue(block, 'BookStatus')
          : _xmlDataAttr(block, 'BookStatus', 'value');
      final tags = _xmlDataAttr(block, 'Tags', 'value');
      items.add({
        'aid': aid,
        'name': name,
        'author': author,
        'author_raw': author,
        'status': status,
        'tags': tags.isEmpty ? null : tags,
        'cover': wenku8CoverUrl(aid),
      });
    }
    // Fallback: bare <item aid='N'/>
    if (items.isEmpty) {
      for (final m in RegExp(r'''aid=['"](\d+)['"]''').allMatches(xml)) {
        final aid = m.group(1)!;
        items.add({
          'aid': aid,
          'name': '',
          'author': '',
          'author_raw': '',
          'cover': wenku8CoverUrl(aid),
        });
      }
    }
    return items;
  }

  int? _parsePageNum(String xml) {
    final m = RegExp(r'''<page\s+num=['"](\d+)['"]''').firstMatch(xml);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Map UI rank key → API sort. `done` uses `fullflag`.
  String _apiSort(String type) => type == 'done' ? 'fullflag' : type;

  Future<Map<String, dynamic>> rank(String type, int page) async {
    final xml = await _appApi(
      'action=novellist&sort=${_apiSort(type)}&page=$page&t=0',
    );
    final items = _parseNovelListItems(xml);
    final pagerMax = _parsePageNum(xml);
    final maxPage = inferMaxPage(
      page,
      items.length,
      fullPageSize: 10,
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

  /// Homepage recommendation blocks — still website HTML (discover unchanged).
  Future<Map<String, dynamic>> home() async {
    await ensureAccount();
    final res = await _http.getHtml('$_base/index.php', preferGbk: true);
    final doc = parseHtml(res.html);
    final sections = <Map<String, dynamic>>[];
    const skip = [
      '公告',
      '登录',
      '书架',
      '搜索',
      '入口',
      'Telegram',
      '大赏',
      '醒目',
    ];
    for (final titleEl in doc.querySelectorAll('.blocktitle')) {
      var title = cleanText(titleEl.text);
      if (title.isEmpty) continue;
      if (skip.any((s) => title.contains(s))) continue;
      final cut = title.indexOf('(');
      if (cut > 2) title = title.substring(0, cut).trim();
      Element? content = titleEl.nextElementSibling;
      if (content == null ||
          !(content.classes.contains('blockcontent') ||
              (content.className).contains('blockcontent'))) {
        content = titleEl.parent;
      }
      if (content == null) continue;
      final items = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final a in content.querySelectorAll('a[href]')) {
        final href = a.attributes['href'] ?? '';
        final aid = _extractAid(href);
        if (aid == null || !seen.add(aid)) continue;
        var name = cleanText(a.attributes['title'] ?? a.text);
        if (name.length < 2) continue;
        if (RegExp(r'更多|查看|登录|注册|首页').hasMatch(name)) continue;
        final img = a.querySelector('img') ?? a.parent?.querySelector('img');
        var cover = absUrl(_base, img?.attributes['src']);
        if (cover.isEmpty) {
          cover = wenku8CoverUrl(aid);
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

  /// Search via App API.
  ///
  /// - `tag`: `searchtype=tags` (real tag filter; same as website tags.php)
  /// - `mixed` / default: articlename + author merge (MewX homepage)
  /// - `articlename`: title-only
  /// - `author`: author-only (detail author chip)
  ///
  /// Note: `searchtype=tag` (singular) is *not* a tag filter — same as
  /// articlename. Must use plural `tags`.
  Future<Map<String, dynamic>> search(
    String keyword,
    String type,
    int page,
  ) async {
    final key = Uri.encodeQueryComponent(keyword);
    Future<List<Map<String, dynamic>>> one(String apiType) async {
      final xml = await _appApi(
        'action=search&searchtype=$apiType&searchkey=$key&t=0',
      );
      if (xml.trim() == '19' || xml.trim().isEmpty) return [];
      return _parseNovelListItems(xml);
    }

    late final List<Map<String, dynamic>> all;
    if (type == 'tag') {
      all = await one('tags');
    } else if (type == 'author') {
      all = await one('author');
    } else if (type == 'articlename') {
      all = await one('articlename');
    } else {
      // mixed (default): same merge order as MewX SearchResultActivity
      final byTitle = await one('articlename');
      final byAuthor = await one('author');
      final authorAids = {
        for (final e in byAuthor) e['aid']?.toString() ?? '',
      }..remove('');
      all = [
        for (final e in byTitle)
          if (!authorAids.contains(e['aid']?.toString())) e,
        ...byAuthor,
      ];
    }

    for (final item in all) {
      if ((item['name'] as String?)?.isNotEmpty == true) continue;
      final aid = item['aid']?.toString() ?? '';
      if (aid.isEmpty) continue;
      try {
        final infoXml = await _appApi('action=book&do=info&aid=$aid&t=0');
        item['name'] = _xmlDataValue(infoXml, 'Title');
        final author = _xmlDataAttr(infoXml, 'Author', 'value');
        if (author.isNotEmpty) {
          item['author'] = author;
          item['author_raw'] = author;
        }
      } catch (_) {}
    }

    final total = all.length;
    final maxPage =
        total == 0 ? 1 : ((total + _searchPageSize - 1) ~/ _searchPageSize);
    final start = (page - 1) * _searchPageSize;
    final slice = start >= total
        ? <Map<String, dynamic>>[]
        : all.sublist(start, min(start + _searchPageSize, total));
    return {
      'type': type,
      'keyword': keyword,
      'page': page,
      'pager_max': maxPage,
      'max_page': maxPage,
      'items': slice,
    };
  }

  String? _extractAid(String href) {
    final book = RegExp(r'/book/(\d+)\.htm').firstMatch(href);
    if (book != null) return book.group(1);
    final novel = RegExp(r'/novel/\d+/(\d+)/').firstMatch(href);
    if (novel != null) return novel.group(1);
    final m = RegExp(r'(\d+)').allMatches(href).toList();
    if (m.isEmpty) return null;
    return m.last.group(1);
  }

  Future<Map<String, dynamic>> bookDetail(String aid) async {
    if (_bookCache.containsKey(aid)) return Map.from(_bookCache[aid]!);

    final metaXml = await _appApi('action=book&do=meta&aid=$aid&t=0');
    final introText = await _appApi('action=book&do=intro&aid=$aid&t=0');

    final name = _xmlDataValue(metaXml, 'Title');
    final author = _xmlDataAttr(metaXml, 'Author', 'value');
    final status = _xmlDataAttr(metaXml, 'BookStatus', 'value');
    final updateTime = _xmlDataAttr(metaXml, 'LastUpdate', 'value');
    final tags = _xmlDataAttr(metaXml, 'Tags', 'value');
    final intro = introText.trim();

    // Only fields consumed by _loadComicInfo / cards. No PressId/分类.
    final data = <String, dynamic>{
      'aid': aid,
      'name': name.isEmpty ? '未知书名' : name,
      'author_raw': author,
      'status': status,
      'update_time': updateTime.isEmpty ? null : updateTime,
      'cover': wenku8CoverUrl(aid),
      'intro': intro,
      'tags': tags.isEmpty ? null : tags,
    };

    _bookCache[aid] = Map.from(data);
    return data;
  }

  Future<Map<String, dynamic>> catalog(String aid) async {
    if (_catalogCache.containsKey(aid)) {
      return _catalogSummary(_catalogCache[aid]!);
    }
    final xml = await _appApi('action=book&do=list&aid=$aid&t=0');
    final catalog = <String, dynamic>{
      'aid': aid,
      'title': '小说_$aid',
      'volumes': <Map<String, dynamic>>[],
    };

    // Prefer meta title if cached.
    final cached = _bookCache[aid];
    if (cached != null && (cached['name'] as String?)?.isNotEmpty == true) {
      catalog['title'] = cached['name'];
    }

    final volRe = RegExp(
      r'''<volume\s+vid=["'](\d+)["']>([\s\S]*?)</volume>''',
      caseSensitive: false,
    );
    for (final vm in volRe.allMatches(xml)) {
      final block = vm.group(2)!;
      final volNameM =
          RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(block);
      // Volume CDATA is before first <chapter>; take text before <chapter.
      var volName = '';
      final beforeChap =
          block.split(RegExp(r'<chapter', caseSensitive: false)).first;
      final cdata =
          RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(beforeChap);
      volName = cleanText(cdata?.group(1) ?? volNameM?.group(1) ?? '');
      if (volName.isEmpty) {
        volName = '卷${(catalog['volumes'] as List).length + 1}';
      }

      final chapters = <Map<String, dynamic>>[];
      final chapRe = RegExp(
        r'''<chapter\s+cid=["'](\d+)["']><!\[CDATA\[([\s\S]*?)\]\]></chapter>''',
        caseSensitive: false,
      );
      var seq = 0;
      for (final cm in chapRe.allMatches(block)) {
        seq++;
        chapters.add({
          'seq': seq,
          'title': cleanText(cm.group(2) ?? ''),
          'cid': cm.group(1)!,
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
    final raw = await _appApi('action=book&do=text&aid=$aid&cid=$cid&t=0');
    final images = <String>[];
    final lines = <String>[];

    // App API embeds images as <!--image-->url<!--image-->
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = text.replaceAllMapped(
      RegExp(r'<!--image-->([^<]+)<!--image-->', caseSensitive: false),
      (m) {
        final url = normalizeNovelImageUrl(preferHttps(m.group(1)!.trim()));
        if (url.isNotEmpty && !images.contains(url)) images.add(url);
        return '\n$url\n';
      },
    );

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trimRight();
      if (_watermark.any((m) => line.contains(m))) continue;
      lines.add(line);
    }
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }

    // Reader only consumes content + images.
    return {
      'images': images,
      'content': lines.join('\n'),
    };
  }
}
