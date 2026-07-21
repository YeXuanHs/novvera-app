import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:html/dom.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/novel_backend/novel_http.dart';
import 'package:venera/utils/io.dart';

const _base = 'https://www.wenku8.net';
const _loginRefreshInterval = Duration(hours: 1);

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

/// Dart-side wenku8.net client (replaces Python sidecar).
class Wenku8Client {
  Wenku8Client._();
  static final Wenku8Client instance = Wenku8Client._();

  final _http = NovelHttp(defaultReferer: '$_base/');
  final _bookCache = <String, Map<String, dynamic>>{};
  final _catalogCache = <String, Map<String, dynamic>>{};

  String? username;
  String? password;
  DateTime? _lastLoginAt;
  Timer? _refreshTimer;

  File get _accountFile => File('${App.dataPath}/wenku8_account.json');

  Future<void> init() async {
    await _loadAccount();
    await ensureAccount();
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_loginRefreshInterval, (_) {
      ensureAccount(forceLogin: true);
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
    if (username != null &&
        password != null &&
        username!.isNotEmpty &&
        password!.isNotEmpty) {
      if (await _login(username!, password!)) return true;
    }
    // Try auto-register a few times
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
    } catch (e) {
      Log.warning('Wenku8', 'login: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> rank(String type, int page) async {
    await ensureAccount();
    final url = type == 'done'
        ? '$_base/modules/article/articlelist.php?fullflag=1&page=$page'
        : '$_base/modules/article/toplist.php?sort=$type&page=$page';
    final res = await _http.getHtml(url, preferGbk: true);
    final items = _parseRank(parseHtml(res.html));
    return {
      'type': type,
      'type_name': _rankTypes[type] ?? type,
      'page': page,
      'items': items,
    };
  }

  Future<Map<String, dynamic>> search(
    String keyword,
    String type,
    int page,
  ) async {
    await ensureAccount();
    final key = gbkQueryEncode(keyword);
    final url = type == 'tag'
        ? '$_base/modules/article/tags.php?t=$key&page=$page'
        : '$_base/modules/article/search.php?searchtype=$type&searchkey=$key&page=$page';
    final res = await _http.getHtml(url, preferGbk: true);
    if (res.url.contains('/book/') && res.url.endsWith('.htm')) {
      final aid = _extractAid(res.url);
      if (aid != null) {
        final info = await bookDetail(aid);
        return {
          'type': type,
          'keyword': keyword,
          'page': page,
          'items': [info],
        };
      }
    }
    final items = <Map<String, dynamic>>[];
    final doc = parseHtml(res.html);
    for (final div in doc.querySelectorAll(
      'table.grid div[style*="float:left;margin"]',
    )) {
      final a = div.querySelector('b a');
      if (a == null) continue;
      final ps = div.querySelectorAll('p');
      items.add({
        'name': cleanText(a.attributes['title'] ?? a.text),
        'author': ps.isNotEmpty ? cleanText(ps.first.text) : '',
        'author_raw': ps.isNotEmpty ? cleanText(ps.first.text) : '',
        'aid': _extractAid(a.attributes['href'] ?? '') ?? '',
        'cover': '',
      });
    }
    return {
      'type': type,
      'keyword': keyword,
      'page': page,
      'items': items,
    };
  }

  List<Map<String, dynamic>> _parseRank(Document doc) {
    final items = <Map<String, dynamic>>[];
    for (final div in doc.querySelectorAll(
      'table.grid div[style*="float:left;margin"]',
    )) {
      final a = div.querySelector('b a');
      if (a == null) continue;
      final ps = div.querySelectorAll('p');
      items.add({
        'name': cleanText(a.attributes['title'] ?? a.text),
        'author': ps.isNotEmpty ? cleanText(ps.first.text) : '',
        'author_raw': ps.isNotEmpty ? cleanText(ps.first.text) : '',
        'aid': _extractAid(a.attributes['href'] ?? '') ?? '',
        'cover': '',
      });
    }
    return items;
  }

  String? _extractAid(String href) {
    final m = RegExp(r'(\d+)').allMatches(href).toList();
    if (m.isEmpty) return null;
    // book/1234.htm or novel/1/1234/
    final book = RegExp(r'/book/(\d+)\.htm').firstMatch(href);
    if (book != null) return book.group(1);
    final novel = RegExp(r'/novel/\d+/(\d+)/').firstMatch(href);
    if (novel != null) return novel.group(1);
    return m.last.group(1);
  }

  Future<Map<String, dynamic>> bookDetail(String aid) async {
    await ensureAccount();
    if (_bookCache.containsKey(aid)) return Map.from(_bookCache[aid]!);
    final folder = int.parse(aid) ~/ 1000;
    final url = '$_base/book/$aid.htm';
    var res = await _http.getHtml(url, preferGbk: true);
    if (res.status != 200 || res.html.length < 200) {
      res = await _http.getHtml(
        '$_base/novel/$folder/$aid/index.htm',
        preferGbk: true,
      );
    }
    final doc = parseHtml(res.html);
    final data = <String, dynamic>{
      'aid': aid,
      'name': '未知书名',
      'category': '',
      'author_raw': '',
      'status': '',
      'update_time': null,
      'cover': '',
      'intro': '',
      'tags': null,
    };
    final title = doc.querySelector('title')?.text ?? '';
    if (title.isNotEmpty) {
      data['name'] = cleanText(title.split(' - ').first);
    }
    final imgTd = doc.querySelector('td[width="20%"][valign="top"] img');
    if (imgTd != null) {
      data['cover'] = absUrl(_base, imgTd.attributes['src']);
    }
    final pageText = doc.body?.text ?? '';
    for (final tr in doc.querySelectorAll('tr')) {
      final t = tr.text;
      if (t.contains('文库分类') && t.contains('小说作者') ||
          t.contains('文庫分類') && t.contains('小說作者')) {
        final tds = tr.querySelectorAll('td');
        data['category'] = _field(tds, ['文库分类：', '文庫分類：']);
        data['author_raw'] = _field(tds, ['小说作者：', '小說作者：']);
        data['status'] = _field(tds, ['文章状态：', '文章狀態：']);
        data['update_time'] = _field(tds, ['最后更新：', '最後更新：']);
        break;
      }
    }
    for (final sp in doc.querySelectorAll('span.hottext')) {
      final t = cleanText(sp.text);
      if (t.startsWith('作品Tags')) {
        data['tags'] = t.replaceFirst(RegExp(r'作品Tags[：:]'), '').trim();
      }
    }
    // intro
    for (final sp in doc.querySelectorAll('span')) {
      final t = cleanText(sp.text);
      if (t.startsWith('内容简介') || t.startsWith('內容簡介')) {
        final next = sp.nextElementSibling;
        if (next != null && next.localName == 'span') {
          data['intro'] = cleanText(next.text);
        }
        break;
      }
    }
    if (pageText.contains('动画化') || pageText.contains('動畫化')) {
      data['anime'] = '是';
    } else {
      data['anime'] = '否';
    }
    data['author'] =
        '作者:${data['author_raw'] ?? ''}/分类:${data['category'] ?? ''}';
    _bookCache[aid] = Map.from(data);
    return data;
  }

  String _field(List<Element> tds, List<String> labels) {
    for (final td in tds) {
      final t = cleanText(td.text);
      for (final label in labels) {
        if (t.contains(label.replaceAll('：', '')) || t.startsWith(label)) {
          return t.replaceFirst(RegExp('${RegExp.escape(label)}|${RegExp.escape(label.replaceAll('：', ''))}[：:]?'), '').trim();
        }
      }
    }
    return '';
  }

  Future<Map<String, dynamic>> catalog(String aid) async {
    await ensureAccount();
    if (_catalogCache.containsKey(aid)) {
      return _catalogSummary(_catalogCache[aid]!);
    }
    final folder = int.parse(aid) ~/ 1000;
    final res = await _http.getHtml(
      '$_base/novel/$folder/$aid/index.htm',
      preferGbk: true,
    );
    final doc = parseHtml(res.html);
    final title = cleanText(doc.getElementById('title')?.text ?? '小说_$aid');
    final catalog = <String, dynamic>{
      'aid': aid,
      'title': title,
      'volumes': <Map<String, dynamic>>[],
    };
    final table = doc.querySelector('table.css');
    if (table == null) {
      throw Exception('目录解析失败');
    }
    Map<String, dynamic>? currentVol;
    var chapSeq = 0;
    for (final td in table.querySelectorAll('td')) {
      final classes = td.classes;
      if (classes.contains('vcss')) {
        chapSeq = 0;
        currentVol = {
          'vol_num': (catalog['volumes'] as List).length + 1,
          'name': cleanText(td.text),
          'chapters': <Map<String, dynamic>>[],
        };
        (catalog['volumes'] as List).add(currentVol);
        continue;
      }
      if (!classes.contains('ccss') || currentVol == null) continue;
      final a = td.querySelector('a');
      final href = a?.attributes['href']?.trim() ?? '';
      if (a == null || !href.endsWith('.htm')) continue;
      var cid = href.substring(0, href.length - 4);
      if (cid.contains('/')) cid = cid.split('/').last;
      chapSeq++;
      (currentVol['chapters'] as List).add({
        'seq': chapSeq,
        'title': cleanText(a.text),
        'cid': cid,
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
    await ensureAccount();
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
    final folder = int.parse(aid) ~/ 1000;
    final res = await _http.getHtml(
      '$_base/novel/$folder/$aid/$cid.htm',
      preferGbk: true,
    );
    final doc = parseHtml(res.html);
    final contentDiv = doc.getElementById('content');
    final images = <String>[];
    final lines = <String>[];
    if (contentDiv != null) {
      for (final el in contentDiv.querySelectorAll('#contentdp')) {
        el.remove();
      }
      for (final div in contentDiv.querySelectorAll('div.divimage')) {
        final img = div.querySelector('img');
        var src = absUrl(_base, img?.attributes['src']);
        if (src.isEmpty) {
          src = absUrl(_base, div.querySelector('a')?.attributes['href']);
        }
        if (src.isNotEmpty) {
          images.add(src);
          div.replaceWith(Text('\n$src\n'));
        } else {
          div.remove();
        }
      }
      for (final img in contentDiv.querySelectorAll('img.imagecontent')) {
        final src = absUrl(_base, img.attributes['src']);
        if (src.isNotEmpty) {
          if (!images.contains(src)) images.add(src);
          img.replaceWith(Text('\n$src\n'));
        }
      }
      for (final br in contentDiv.querySelectorAll('br')) {
        br.replaceWith(Text('\n'));
      }
      final text = contentDiv.text.replaceAll('\u00a0', ' ');
      for (final raw in text.split('\n')) {
        final line = raw.replaceAll(RegExp(r'\r'), '').trimRight();
        if (_watermark.any((m) => line.contains(m))) continue;
        lines.add(line);
      }
      while (lines.isNotEmpty && lines.first.trim().isEmpty) {
        lines.removeAt(0);
      }
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
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
