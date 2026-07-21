import 'dart:collection';

import 'package:novvera/foundation/comic_source/comic_source.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/novel_api/novel_api_client.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/foundation/novel_source/novel_page_cache.dart';
import 'package:novvera/foundation/res.dart';

const kNovelSourceKeys = {'wenku8', 'linovelib'};

bool isNovelSource(String? key) => key != null && kNovelSourceKeys.contains(key);

/// Built-in light-novel sources backed by in-process Dart scrapers.
///
/// - **发现 (Explore)**: homepage recommendation sections (multipart)
/// - **分类 (Categories)**: rank types via Ranking page
List<ComicSource> createBuiltinNovelSources() {
  return [
    _buildSource(name: '轻小说文库', key: 'wenku8'),
    _buildSource(name: '哔哩轻小说', key: 'linovelib'),
  ];
}

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

ComicSource _buildSource({
  required String name,
  required String key,
}) {
  final ranking = RankingData(
    Map<String, String>.from(_rankTypes),
    (option, page) => _loadRank(key, option, page),
    null,
  );

  // Show every rank type as a tap target on the Categories page (not a single
  // "排行" chip that hides the options one click deeper).
  final rankTags = _rankTypes.entries
      .map(
        (e) => CategoryItem(
          e.value,
          PageJumpTarget(key, 'category', {
            'category': e.value,
            'param': e.key,
          }),
        ),
      )
      .toList();

  final categoryData = CategoryData(
    title: name,
    key: key,
    categories: [
      FixedCategoryPart('排行榜', rankTags),
    ],
    enableRankingPage: false,
  );

  final categoryComicsData = CategoryComicsData(
    options: const [],
    load: (category, param, options, page) {
      final type = _resolveRankType(category, param, options);
      return _loadRank(key, type, page);
    },
    rankingData: ranking,
  );

  // Explore = site homepage recommendations (like Venera 包子漫画 multipart)
  final explorePages = [
    ExplorePageData(
      name,
      ExplorePageType.singlePageWithMultiPart,
      null,
      null,
      () => _loadHome(key),
      null,
    ),
  ];

  final searchOptions = [
    SearchOptions(
      LinkedHashMap.from({
        'articlename': '书名',
        'author': '作者',
        'tag': '标签',
      }),
      '搜索类型',
      'select',
      'articlename',
    ),
  ];

  return ComicSource(
    name,
    key,
    null,
    categoryData,
    categoryComicsData,
    null,
    explorePages,
    SearchPageData(
      searchOptions,
      (keyword, page, options) => _loadSearch(
        key,
        keyword,
        page,
        options.isNotEmpty ? options.first : 'articlename',
      ),
      null,
    ),
    null,
    (id) => _loadComicInfo(key, id),
    null,
    (id, ep) => _loadChapterPages(key, id, ep),
    (imageKey, comicId, epId) async => _imageLoadingConfig(key, imageKey),
    (imageKey) => _imageLoadingConfig(key, imageKey),
    'builtin:$key',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    (namespace, tag) => PageJumpTarget(key, 'search', {
      'text': tag,
      'options': ['tag'],
    }),
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

Map<String, dynamic> _imageLoadingConfig(String sourceKey, String imageKey) {
  final referer = sourceKey == 'wenku8'
      ? 'https://www.wenku8.net/'
      : 'https://www.linovelib.com/';
  final url = normalizeNovelImageUrl(imageKey);
  return {
    'url': url,
    'headers': {
      'user-agent': webUA,
      'Referer': referer,
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    },
  };
}

Comic _itemToComic(Map<String, dynamic> item, String sourceKey) {
  final aid = '${item['aid'] ?? ''}';
  final title = (item['name'] ?? item['title'] ?? '').toString();
  var cover = preferHttps((item['cover'] ?? '').toString());
  if (cover.isEmpty && aid.isNotEmpty) {
    cover = sourceKey == 'wenku8'
        ? wenku8CoverUrl(aid)
        : linovelibCoverUrl(aid);
  }
  final authorRaw = (item['author_raw'] ?? '').toString();
  final author = authorRaw.isNotEmpty
      ? authorRaw
      : (item['author'] ?? '').toString();
  final tags = <String>[];
  final tagStr = item['tags']?.toString();
  if (tagStr != null && tagStr.isNotEmpty) {
    tags.addAll(
      tagStr.split(RegExp(r'[\s,/|]+')).where((e) => e.trim().isNotEmpty),
    );
  }
  final status = item['status']?.toString();
  if (status != null && status.isNotEmpty) {
    tags.add(status);
  }
  final desc = (item['last_chapter'] ?? item['intro'] ?? item['hot_text'] ?? '')
      .toString();
  return Comic(
    title,
    cover,
    aid,
    author,
    tags.isEmpty ? null : tags,
    desc,
    sourceKey,
    null,
    null,
  );
}

Future<Res<List<ExplorePagePart>>> _loadHome(String source) async {
  try {
    final data = await NovelApiClient.instance.get(source, '/meta/home');
    final sections = (data['sections'] as List? ?? []).whereType<Map>();
    final parts = <ExplorePagePart>[];
    for (final sec in sections) {
      final title = (sec['title'] ?? '').toString();
      if (title.isEmpty) continue;
      final comics = (sec['items'] as List? ?? [])
          .whereType<Map>()
          .map((e) => _itemToComic(Map<String, dynamic>.from(e), source))
          .where((c) => c.id.isNotEmpty && c.title.isNotEmpty)
          .toList();
      if (comics.isEmpty) continue;
      parts.add(ExplorePagePart(title, comics, null));
    }
    if (parts.isEmpty) {
      return Res.error('主页暂无推荐分区');
    }
    return Res(parts);
  } catch (e) {
    return Res.error(e.toString());
  }
}

Future<Res<List<Comic>>> _loadRank(String source, String type, int page) async {
  try {
    final data = await NovelApiClient.instance.get(
      source,
      '/meta/rank-types',
      query: {'type': type, 'page': page, 'fmt': 'utf8'},
    );
    final items = (data['items'] as List? ?? [])
        .whereType<Map>()
        .map((e) => _itemToComic(Map<String, dynamic>.from(e), source))
        .toList();
    final pagerMax = int.tryParse('${data['pager_max'] ?? ''}');
    final maxPage = inferMaxPage(
      page,
      items.length,
      fullPageSize: source == 'linovelib' ? 20 : 10,
      parsed: pagerMax ?? int.tryParse('${data['max_page'] ?? ''}'),
    );
    return Res(items, subData: maxPage);
  } catch (e) {
    return Res.error(e.toString());
  }
}

String _resolveRankType(String category, String? param, List<String> options) {
  if (param != null && _rankTypes.containsKey(param)) {
    return param;
  }
  if (options.isNotEmpty && _rankTypes.containsKey(options.first)) {
    return options.first;
  }
  for (final e in _rankTypes.entries) {
    if (e.value == category || e.key == category) {
      return e.key;
    }
  }
  return _rankTypes.keys.first;
}

Future<Res<List<Comic>>> _loadSearch(
  String source,
  String keyword,
  int page,
  String type,
) async {
  try {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      return const Res([], subData: 1);
    }
    final searchType = const {'articlename', 'author', 'tag'}.contains(type)
        ? type
        : 'articlename';
    final data = await NovelApiClient.instance.get(
      source,
      '/search',
      query: {
        'keyword': kw,
        'type': searchType,
        'page': page,
        'fmt': 'utf8',
      },
    );
    final items = (data['items'] as List? ?? [])
        .whereType<Map>()
        .map((e) => _itemToComic(Map<String, dynamic>.from(e), source))
        .where((c) => c.id.isNotEmpty)
        .toList();
    final pagerMax = int.tryParse('${data['pager_max'] ?? ''}');
    final maxPage = inferMaxPage(
      page,
      items.length,
      fullPageSize: source == 'linovelib' ? 20 : 10,
      parsed: pagerMax ?? int.tryParse('${data['max_page'] ?? ''}'),
    );
    return Res(items, subData: maxPage);
  } catch (e) {
    return Res.error(e.toString());
  }
}

Future<Res<ComicDetails>> _loadComicInfo(String source, String id) async {
  try {
    final info = await NovelApiClient.instance.get(
      source,
      '/books/$id',
      query: {'fmt': 'utf8'},
    );
    final catalog = await NovelApiClient.instance.get(
      source,
      '/books/$id/catalog',
      query: {'fmt': 'utf8'},
    );

    final title = (info['name'] ?? catalog['title'] ?? '').toString();
    var cover = preferHttps((info['cover'] ?? '').toString());
    if (cover.isEmpty) {
      cover = source == 'wenku8'
          ? wenku8CoverUrl(id)
          : linovelibCoverUrl(id);
    }
    final authorRaw = (info['author_raw'] ?? '').toString();
    final category = (info['category'] ?? '').toString();
    final intro = (info['intro'] ?? '').toString();
    final status = (info['status'] ?? '').toString();
    final updateTime = info['update_time']?.toString();
    final tags = <String, List<String>>{};
    if (authorRaw.isNotEmpty) {
      tags['作者'] = [authorRaw];
    }
    if (category.isNotEmpty) {
      tags['分类'] = [category];
    }
    if (status.isNotEmpty) {
      tags['状态'] = [status];
    }
    final tagStr = info['tags']?.toString();
    if (tagStr != null && tagStr.isNotEmpty) {
      tags['标签'] = tagStr
          .split(RegExp(r'[\s,/|]+'))
          .where((e) => e.trim().isNotEmpty)
          .toList();
    }

    final grouped = <String, Map<String, String>>{};
    final volumes = catalog['volumes'] as List? ?? [];
    for (final vol in volumes) {
      if (vol is! Map) continue;
      final volNum = vol['vol_num'];
      final volName = (vol['name'] ?? '卷$volNum').toString();
      final chapters = <String, String>{};
      for (final chap in (vol['chapters'] as List? ?? [])) {
        if (chap is! Map) continue;
        final seq = chap['seq'];
        final chapTitle = (chap['title'] ?? '').toString();
        chapters['$volNum-$seq'] = chapTitle;
      }
      if (chapters.isNotEmpty) {
        grouped[volName] = chapters;
      }
    }

    final details = ComicDetails.fromJson({
      'title': title,
      'subtitle': authorRaw,
      'cover': cover,
      'description': intro,
      'tags': tags,
      'chapters': grouped,
      'sourceKey': source,
      'comicId': id,
      'isFavorite': false,
      'updateTime': updateTime,
      'url': null,
    });
    return Res(details);
  } catch (e) {
    return Res.error(e.toString());
  }
}

/// Fetch chapter text+images. [epId] is `"vol-chap"`.
Future<Res<Map<String, dynamic>>> loadNovelChapter(
  String source,
  String aid,
  String epId,
) async {
  try {
    final parts = epId.split('-');
    if (parts.length < 2) {
      return Res.error('Invalid chapter id: $epId');
    }
    final vol = int.tryParse(parts[0]);
    final chap = int.tryParse(parts.sublist(1).join('-'));
    if (vol == null || chap == null) {
      return Res.error('Invalid chapter id: $epId');
    }
    final data = await NovelApiClient.instance.get(
      source,
      '/books/$aid/chapters/$vol/$chap',
      query: {'fmt': 'utf8', 'json': true},
    );
    return Res(data);
  } catch (e) {
    return Res.error(e.toString());
  }
}

/// Build Venera Reader pages: text blocks as `noveltxt://` keys, images as URLs.
Future<Res<List<String>>> _loadChapterPages(
  String source,
  String aid,
  String? epId,
) async {
  try {
    final ep = (epId == null || epId.isEmpty) ? '1-1' : epId;
    final res = await loadNovelChapter(source, aid, ep);
    if (res.error) {
      return Res.error(res.errorMessage ?? 'load chapter failed');
    }
    NovelPageCache.clear();
    final data = res.data;
    final text = (data['content'] ?? '').toString();
    final images = (data['images'] as List? ?? [])
        .map((e) => normalizeNovelImageUrl(e.toString()))
        .where((e) => e.startsWith('http'))
        .toList();

    final pages = <String>[];
    final seenImages = <String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        final url = normalizeNovelImageUrl(trimmed);
        if (url.startsWith('http') && seenImages.add(url)) {
          pages.add(url);
        }
        continue;
      }
      pages.add(NovelPageCache.put(line));
    }
    for (final url in images) {
      if (seenImages.add(url)) {
        pages.add(url);
      }
    }
    if (pages.isEmpty) {
      pages.add(NovelPageCache.put('（本章无内容）'));
    }
    return Res(pages);
  } catch (e) {
    return Res.error(e.toString());
  }
}
