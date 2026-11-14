import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/book_source/book_source.dart';
import 'package:novvera/foundation/res.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/network/app_dio.dart';
import 'package:novvera/network/cloudflare.dart';
import 'package:novvera/utils/io.dart';

const _base = 'https://www.wenku8.net';
const _relay = 'https://wenku8-relay.mewx.org/';
const _apiAppVer = '1.29';
const _apiAppCode = 'digital-bento';
/// Official App relay — must stay Dalvik; Chrome UA breaks the API.
const _apiUa =
    'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 6 Build/TQ3A.230805.001)';
/// Website HTML (home / login / register) — desktop Chrome 124, same as CF Verify.
const _htmlUa = webUA;
const _loginRefreshInterval = Duration(hours: 1);
const _searchPageSize = 10;

const _rankTypes = <String, String>{
  'allvisit': '总点击排行',
  'allvote': '总推荐排行',
  'monthvisit': '月点击排行',
  'monthvote': '月推荐排行',
  'weekvisit': '周点击排行',
  'weekvote': '周推荐排行',
  'dayvisit': '日点击排行',
  'dayvote': '日推荐排行',
  'postdate': '最新入库',
  'lastupdate': '最近更新',
  'goodnum': '总收藏量排行',
  'size': '字数排行',
  'done': '完结小说列表',
};

const _watermark = [
  '本文来自',
  '最新最全的日本动漫轻小说',
  '最新最全的日本動漫輕小說',
];

const _imageEntry = '<!--image-->';

/// Markdown-form inline illustration, e.g.
/// `![图片](  https://host/x.png<!--image-->   ?w=580&h=836)`.
///
/// Wenku8 serves two shapes for the same thing. The paired-marker form
/// `<!--image-->url<!--image-->` is handled by the scan below; this one carries
/// a **single** marker, so that scan hits its "no closing marker" branch and
/// pushes the whole line in as body text — the URL is lost and the Markdown
/// syntax leaks into the chapter.
///
/// Captured here first; the match is then removed from the line so the paired
/// scan never sees it.
final _markdownImageRe = RegExp(
  r'!\[[^\]]*\]\(\s*(https?://[^\s)]+?)\s*<!--image-->\s*[^)]*\)',
  caseSensitive: false,
);

/// Port of MewX [OldNovelContentParser.parseNovelContent].
///
/// Official reader (Wenku8 Android 1.29):
/// - splits on `\r\n` only (do not pre-normalize `\r` → `\n`, that invents blanks)
/// - skips lines that are empty or ASCII-spaces only
/// - each remaining line → one TEXT element (`trim`), or IMAGE from
///   `<!--image-->url<!--image-->` (multiple per line allowed)
/// - Markdown-form `![…](  url<!--image-->   ?w=…)` is lifted out first
/// - [WenkuReaderPaginator] later skips elements whose text length is 0
///
/// Returns ordered segments: text paragraphs and image URLs (http…).
List<String> parseWenku8NovelContent(String raw) {
  final result = <String>[];
  void addText(String text) {
    final t = text.trim();
    if (t.isEmpty) return; // paginator would skip length-0 anyway
    if (_watermark.any(t.contains)) return;
    result.add(t);
  }

  for (final rawLine in raw.split('\r\n')) {
    var line = rawLine;
    // Same emptiness check as Java: only ASCII space counts as empty padding.
    var onlySpaces = true;
    for (var i = 0; i < line.length; i++) {
      if (line.codeUnitAt(i) != 0x20) {
        onlySpaces = false;
        break;
      }
    }
    if (onlySpaces) continue;

    // Markdown-form illustrations first: emit the URL where it sits and keep
    // only the leftover prose, so the paired-marker scan below only ever sees
    // well-formed pairs. Emitting in place preserves reading order on lines
    // that mix prose and an illustration.
    if (_markdownImageRe.hasMatch(line)) {
      final kept = StringBuffer();
      var last = 0;
      for (final m in _markdownImageRe.allMatches(line)) {
        addText(line.substring(last, m.start));
        final url = normalizeNovelImageUrl(
          preferHttps((m.group(1) ?? '').trim()),
        );
        if (url.startsWith('http')) result.add(url);
        last = m.end;
      }
      kept.write(line.substring(last));
      line = kept.toString();
      // A line that was nothing but an illustration keeps no prose.
      if (line.trim().isEmpty) continue;
    }

    final imgAt = line.indexOf(_imageEntry);
    if (imgAt < 0) {
      addText(line);
      continue;
    }

    // One line may hold several <!--image-->url<!--image--> pairs.
    var temp = 0;
    while (true) {
      temp = line.indexOf(_imageEntry, temp);
      if (temp < 0) break;
      final innerStart = temp + _imageEntry.length;
      final end = line.indexOf(_imageEntry, innerStart);
      if (end < 0) {
        addText(line);
        break;
      }
      final url = normalizeNovelImageUrl(
        preferHttps(line.substring(innerStart, end).trim()),
      );
      if (url.startsWith('http')) result.add(url);
      temp = end + _imageEntry.length;
    }
  }
  return result;
}

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

  /// 用户自己填的账号，优先于自动注册机生成的号。
  String? userUsername;
  String? userPassword;

  /// 当前会话是不是在用用户自己的账号。
  bool usingUserAccount = false;

  bool get hasUserAccount =>
      (userUsername?.isNotEmpty ?? false) &&
      (userPassword?.isNotEmpty ?? false);

  DateTime? _lastLoginAt;
  Timer? _refreshTimer;
  String? _phpSessionId;

  File get _accountFile => File('${App.dataPath}/wenku8_account.json');

  Future<void> init() async {
    await _loadAccount();
    // 每次启动都重新登录一次：cookie 有效期一年，主动续一次比带着可能
    // 过期的 cookie 跑更可靠。只有明确认证失败才回退注册机账号。
    try {
      await ensureAccount(forceLogin: true);
    } catch (e) {
      Log.warning('Wenku8', 'startup login deferred: $e');
    }
  }

  void _armRefreshTimer() {
    if (_refreshTimer != null) return;
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
      userUsername = appdata.implicitData['wenku8_user']?.toString();
      userPassword = appdata.implicitData['wenku8_pass']?.toString();
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
      // 1) 用户自己填的账号优先
      if (hasUserAccount) {
        if (await _login(userUsername!, userPassword!, isUser: true)) {
          usingUserAccount = true;
          return true;
        }
        usingUserAccount = false;
        Log.warning(
          'Wenku8',
          'user account invalid; falling back to auto-registered account',
        );
      }
      // 2) 注册机保存的账号
      if (username != null &&
          password != null &&
          username!.isNotEmpty &&
          password!.isNotEmpty) {
        if (await _login(username!, password!)) {
          usingUserAccount = false;
          return true;
        }
      }
      // 3) 都没有就注册一个新号
      for (var i = 0; i < 3; i++) {
        final u = _randUser();
        final p = _randPass();
        if (await _register(u, p) && await _login(u, p)) {
          username = u;
          password = p;
          await _saveAccount();
          usingUserAccount = false;
          return true;
        }
      }
    } on CloudflareException catch (e) {
      Log.warning('Wenku8', 'ensureAccount blocked by Cloudflare (${e.url})');
      rethrow;
    } catch (e) {
      // 网络/解析异常不等于"账号失效"：上抛，避免误切到注册机账号。
      Log.warning('Wenku8', 'ensureAccount network error: $e');
      rethrow;
    }
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
        headers: {
          'User-Agent': _htmlUa,
          'Referer': '$_base/register.php',
        },
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

  Future<bool> _login(String user, String pass, {bool isUser = false}) async {
    try {
      await _http.getHtml(
        '$_base/login.php',
        preferGbk: true,
        headers: {'User-Agent': _htmlUa},
      );
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
          'User-Agent': _htmlUa,
          'Referer':
              '$_base/login.php?jumpurl=${Uri.encodeComponent('$_base/index.php')}',
        },
      );
      final ok = res.html.contains('欢迎您') || res.html.contains('用户面板');
      if (ok) {
        if (!isUser) {
          username = user;
          password = pass;
          await _saveAccount();
        }
        usingUserAccount = isUser;
        _lastLoginAt = DateTime.now();
        _armRefreshTimer();
        Log.info('Wenku8', 'login ok ($user)');
      } else {
        Log.warning('Wenku8', 'login failed ($user)');
      }
      return ok;
    } on CloudflareException {
      rethrow;
    } catch (e) {
      // 网络异常 ≠ 密码错误，必须区分开，否则会误回退。
      Log.warning('Wenku8', 'login network error: $e');
      rethrow;
    }
  }

  /// 设置/清除用户自己的账号。传空则回到注册机账号。
  Future<bool> setUserAccount(String? user, String? password) async {
    userUsername = user?.trim();
    userPassword = password;
    appdata.implicitData['wenku8_user'] = userUsername ?? '';
    appdata.implicitData['wenku8_pass'] = userPassword ?? '';
    appdata.writeImplicitData();
    _lastLoginAt = null;
    if (!hasUserAccount) {
      usingUserAccount = false;
      return ensureAccount(forceLogin: true);
    }
    final ok = await _login(userUsername!, userPassword!, isUser: true);
    if (ok) {
      usingUserAccount = true;
      return true;
    }
    // 走到这里说明是明确的认证失败（密码改了/账号不存在）→ 回退注册机账号；
    // 网络异常会直接抛出，不会误判成失效。
    usingUserAccount = false;
    return ensureAccount(forceLogin: true);
  }

  // ---------------------------------------------------------------------------
  // 网络收藏（网页书架）
  //
  // 实测 wenku8.net 行为：
  //   列表  GET /modules/article/bookcase.php        （table.grid，每行一个书架项）
  //   加入  GET /modules/article/addbookcase.php?bid={aid}
  //   移除  GET /modules/article/bookcase.php?delid={书架项 bid}
  // 书架项的 bid 与书的 aid 不是一个东西，增删分别用这两个。
  // ---------------------------------------------------------------------------

  static final _shelfAidRe = RegExp(r'aid=(\d+)');
  static final _shelfBidRe = RegExp(r'bid=(\d+)');

  Map<String, String> get _webHeaders => {
        'User-Agent': _htmlUa,
        'Referer': '$_base/index.php',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      };

  /// 拉取网页书架。
  Future<Res<List<Book>>> loadBookshelf() async {
    try {
      if (!await ensureAccount()) {
        return Res.error('文库8 未登录');
      }
      final res = await _http.getHtml(
        '$_base/modules/article/bookcase.php',
        preferGbk: true,
        headers: _webHeaders,
      );
      final doc = parseHtml(res.html);
      final books = <Book>[];
      for (final tr in doc.querySelectorAll('table.grid tr')) {
        final a = tr.querySelector('a[href*="readbookcase.php?aid="]');
        if (a == null) continue;
        final href = a.attributes['href'] ?? '';
        final aid = _shelfAidRe.firstMatch(href)?.group(1) ?? '';
        final bid = _shelfBidRe.firstMatch(href)?.group(1) ?? '';
        if (aid.isEmpty) continue;
        final tds = tr.querySelectorAll('td');
        final author = tds.length > 2
            ? (tds[2].querySelector('a')?.text ?? '').trim()
            : '';
        final update = tds.length > 5 ? tds[5].text.trim() : '';
        final status = (tr.querySelector('span.hottext')?.text ?? '').trim();
        books.add(Book.fromJson({
          'title': a.text.trim(),
          'cover': '',
          'id': aid,
          'subTitle': author,
          'tags': status.isEmpty ? <String>[] : [status],
          'description': '',
          'updateTime': update,
          'favoriteId': bid,
        }, 'wenku8'));
      }
      return Res(books);
    } on CloudflareException catch (e) {
      return Res.error(e.toString());
    } catch (e) {
      Log.warning('Wenku8', 'loadBookshelf: $e');
      return Res.error(e.toString());
    }
  }

  /// 加入书架。[aid] 是书的 id（网页 /book/{aid}.htm）。
  Future<Res<String>> addToBookshelf(String aid) async {
    try {
      if (!await ensureAccount()) {
        return Res.error('文库8 未登录');
      }
      final res = await _http.getHtml(
        '$_base/modules/article/addbookcase.php?bid=$aid',
        preferGbk: true,
        headers: {..._webHeaders, 'Referer': '$_base/book/$aid.htm'},
      );
      final ok = res.html.contains('处理成功') ||
          res.html.contains('已经在书架') ||
          res.html.contains('已在书架');
      Log.info('Wenku8', 'addbookshelf($aid) -> $ok');
      return ok ? const Res('') : Res.error('加入书架失败');
    } on CloudflareException catch (e) {
      return Res.error(e.toString());
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// 移出书架。[bid] 是书架项 id（列表里 readbookcase.php?bid= 那个）。
  Future<Res<String>> removeFromBookshelf(String bid) async {
    if (bid.isEmpty) return Res.error('缺少书架项 id');
    try {
      if (!await ensureAccount()) {
        return Res.error('文库8 未登录');
      }
      final res = await _http.getHtml(
        '$_base/modules/article/bookcase.php?delid=$bid',
        preferGbk: true,
        headers: _webHeaders,
      );
      // 删除成功后会重定向回书架页；只要还是书架页就算成功。
      final ok = res.html.contains('bookcase.php') || res.html.contains('书架');
      Log.info('Wenku8', 'removebookshelf($bid) -> $ok');
      return ok ? const Res('') : Res.error('移出书架失败');
    } on CloudflareException catch (e) {
      return Res.error(e.toString());
    } catch (e) {
      return Res.error(e.toString());
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
    final bytes = await _appApiBytes(plain);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Raw App API response (covers are JPEG, not text).
  Future<Uint8List> _appApiBytes(String plain) async {
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
      return Uint8List.fromList(res.data ?? const []);
    } on DioException catch (e) {
      throw Exception('wenku8 API failed: $e');
    }
  }

  /// Cover JPEG via official App relay (`action=book&do=cover`).
  Future<Uint8List> fetchCoverBytes(String aid) async {
    final bytes = await _appApiBytes('action=book&do=cover&aid=$aid&t=0');
    if (bytes.length < 8 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      throw Exception('wenku8 cover is not JPEG (aid=$aid, len=${bytes.length})');
    }
    return bytes;
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
      final updateTime = _xmlDataAttr(block, 'LastUpdate', 'value');
      if (updateTime.isEmpty) {
        // Fallback: some endpoints use text content instead of attribute
        final tv = _xmlDataValue(block, 'LastUpdate');
        if (tv.isNotEmpty) {
          items.add({
            'aid': aid,
            'name': name,
            'author': author,
            'author_raw': author,
            'status': status,
            'tags': tags.isEmpty ? null : tags,
            'update_time': tv,
            'cover': wenku8CoverUrl(aid),
          });
          continue;
        }
      }
      items.add({
        'aid': aid,
        'name': name,
        'author': author,
        'author_raw': author,
        'status': status,
        'tags': tags.isEmpty ? null : tags,
        'update_time': updateTime.isEmpty ? null : updateTime,
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
  /// Homepage blocks — scrape book IDs only; name/author/cover from App API.
  Future<Map<String, dynamic>> home() async {
    await ensureAccount();
    final res = await _http.getHtml(
      '$_base/index.php',
      preferGbk: true,
      headers: {'User-Agent': _htmlUa},
    );
    final doc = parseHtml(res.html);
    final sectionAids = <({String title, List<String> aids})>[];
    final allAids = <String>[];
    final allSeen = <String>{};
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
      final aids = <String>[];
      final seen = <String>{};
      for (final a in content.querySelectorAll('a[href]')) {
        final href = a.attributes['href'] ?? '';
        final aid = _extractAid(href);
        if (aid == null || !seen.add(aid)) continue;
        final label = cleanText(a.attributes['title'] ?? a.text);
        if (RegExp(r'更多|查看|登录|注册|首页').hasMatch(label)) continue;
        aids.add(aid);
        if (allSeen.add(aid)) allAids.add(aid);
      }
      if (aids.length < 3) continue;
      sectionAids.add((title: title, aids: aids));
    }

    final enriched = await _enrichAids(allAids);
    final byId = {for (final b in enriched) '${b['aid']}': b};
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

  /// Fill name/author/cover from App API [bookDetail] (covers via [wenku8CoverUrl]).
  /// All aids are fetched concurrently (no concurrency cap).
  Future<List<Map<String, dynamic>>> _enrichAids(List<String> aids) async {
    if (aids.isEmpty) return [];
    return Future.wait(aids.map((aid) async {
      try {
        final info = await bookDetail(aid);
        final author = '${info['author_raw'] ?? info['author'] ?? ''}';
        return {
          'aid': aid,
          'name': '${info['name'] ?? ''}',
          'author': author,
          'author_raw': author,
          'cover': '${info['cover'] ?? ''}'.isNotEmpty
              ? '${info['cover']}'
              : wenku8CoverUrl(aid),
          'status': '${info['status'] ?? ''}',
          'intro': '${info['intro'] ?? ''}',
        };
      } catch (e) {
        Log.warning('Wenku8', 'enrich aid=$aid: $e');
        return {
          'aid': aid,
          'name': '小说_$aid',
          'author': '',
          'author_raw': '',
          'cover': wenku8CoverUrl(aid),
        };
      }
    }));
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

    // Only fields consumed by _loadBookInfo / cards. No PressId/分类.
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
    // Match MewX OldNovelContentParser — not a homemade blank/page-number filter.
    final segments = parseWenku8NovelContent(raw);
    final images = <String>[
      for (final s in segments)
        if (s.startsWith('http://') || s.startsWith('https://')) s,
    ];

    return {
      'images': images,
      'content': segments.join('\n'),
    };
  }
}
