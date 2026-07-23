import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/huanmeng_client.dart';
import 'package:novvera/foundation/novel_backend/linovelib_client.dart';
import 'package:novvera/foundation/novel_backend/wenku8_client.dart';

/// In-process novel backend (Dart). Keeps the same `get(source, path)` shape
/// used by builtin sources; no Python sidecar.
class NovelApiClient {
  NovelApiClient._();

  static final NovelApiClient instance = NovelApiClient._();

  bool _inited = false;

  Future<void> init() async {
    if (_inited) return;
    // Isolate per-source bootstrap failures so one site's CF/login block
    // cannot keep `_inited` false and hijack Verify URLs for other sources.
    Future<void> safe(String name, Future<void> Function() run) async {
      try {
        await run();
      } catch (e) {
        Log.warning('NovelApi', '$name init: $e');
      }
    }

    await Future.wait([
      safe('wenku8', Wenku8Client.instance.init),
      safe('linovelib', LinovelibClient.instance.init),
      safe('huanmeng', HuanmengClient.instance.init),
    ]);
    _inited = true;
  }

  Future<bool> healthCheck() async => true;

  Future<void> ensureAccount() async {
    try {
      await init();
      await Wenku8Client.instance.ensureAccount();
    } catch (e) {
      Log.warning('NovelApi', 'ensure-account failed: $e');
    }
  }

  /// Route `/api/{source}/...` style paths to Dart clients.
  Future<Map<String, dynamic>> get(
    String source,
    String path, {
    Map<String, dynamic>? query,
  }) async {
    await init();
    final q = query ?? const {};
    try {
      if (source == 'wenku8') {
        return await _wenku8(path, q);
      }
      if (source == 'linovelib') {
        return await _linovelib(path, q);
      }
      if (source == 'huanmeng') {
        return await _huanmeng(path, q);
      }
      throw Exception('Unknown source: $source');
    } catch (e, s) {
      Log.error('NovelApi', '$source$path\n$e\n$s');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _wenku8(
    String path,
    Map<String, dynamic> q,
  ) async {
    final c = Wenku8Client.instance;
    if (path == '/meta/rank-types') {
      return c.rank(
        (q['type'] ?? 'allvisit').toString(),
        int.tryParse('${q['page'] ?? 1}') ?? 1,
      );
    }
    if (path == '/meta/home' || path == '/home') {
      return c.home();
    }
    if (path == '/search') {
      return c.search(
        (q['keyword'] ?? '').toString(),
        (q['type'] ?? 'articlename').toString(),
        int.tryParse('${q['page'] ?? 1}') ?? 1,
      );
    }
    final book = RegExp(r'^/books/([^/]+)$').firstMatch(path);
    if (book != null) {
      return c.bookDetail(book.group(1)!);
    }
    final catalog = RegExp(r'^/books/([^/]+)/catalog$').firstMatch(path);
    if (catalog != null) {
      return c.catalog(catalog.group(1)!);
    }
    final chap =
        RegExp(r'^/books/([^/]+)/chapters/(\d+)/(\d+)$').firstMatch(path);
    if (chap != null) {
      return c.chapter(
        chap.group(1)!,
        int.parse(chap.group(2)!),
        int.parse(chap.group(3)!),
      );
    }
    throw Exception('Unknown path: $path');
  }

  Future<Map<String, dynamic>> _linovelib(
    String path,
    Map<String, dynamic> q,
  ) async {
    final c = LinovelibClient.instance;
    if (path == '/meta/rank-types') {
      return c.rank(
        (q['type'] ?? 'allvisit').toString(),
        int.tryParse('${q['page'] ?? 1}') ?? 1,
      );
    }
    if (path == '/meta/home' || path == '/home') {
      return c.home();
    }
    if (path == '/search') {
      return c.search(
        (q['keyword'] ?? '').toString(),
        (q['type'] ?? 'articlename').toString(),
        int.tryParse('${q['page'] ?? 1}') ?? 1,
      );
    }
    final book = RegExp(r'^/books/([^/]+)$').firstMatch(path);
    if (book != null) {
      return c.bookDetail(book.group(1)!);
    }
    final catalog = RegExp(r'^/books/([^/]+)/catalog$').firstMatch(path);
    if (catalog != null) {
      return c.catalog(catalog.group(1)!);
    }
    final chap =
        RegExp(r'^/books/([^/]+)/chapters/(\d+)/(\d+)$').firstMatch(path);
    if (chap != null) {
      return c.chapter(
        chap.group(1)!,
        int.parse(chap.group(2)!),
        int.parse(chap.group(3)!),
      );
    }
    throw Exception('Unknown path: $path');
  }

  Future<Map<String, dynamic>> _huanmeng(
    String path,
    Map<String, dynamic> q,
  ) async {
    final c = HuanmengClient.instance;
    if (path == '/meta/rank-types') {
      return c.rank(
        (q['type'] ?? 'allvisit').toString(),
        int.tryParse('${q['page'] ?? 1}') ?? 1,
      );
    }
    if (path == '/meta/home' || path == '/home') {
      return c.home();
    }
    if (path == '/search') {
      return c.search(
        (q['keyword'] ?? '').toString(),
        (q['type'] ?? 'articlename').toString(),
        int.tryParse('${q['page'] ?? 1}') ?? 1,
      );
    }
    final book = RegExp(r'^/books/([^/]+)$').firstMatch(path);
    if (book != null) {
      return c.bookDetail(book.group(1)!);
    }
    final catalog = RegExp(r'^/books/([^/]+)/catalog$').firstMatch(path);
    if (catalog != null) {
      return c.catalog(catalog.group(1)!);
    }
    final chap =
        RegExp(r'^/books/([^/]+)/chapters/(\d+)/(\d+)$').firstMatch(path);
    if (chap != null) {
      return c.chapter(
        chap.group(1)!,
        int.parse(chap.group(2)!),
        int.parse(chap.group(3)!),
      );
    }
    throw Exception('Unknown path: $path');
  }
}
