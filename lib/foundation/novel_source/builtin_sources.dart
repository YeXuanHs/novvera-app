import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/comic_source/comic_source.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/novel_api/novel_api_client.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/foundation/novel_source/novel_page_cache.dart';
import 'package:novvera/foundation/novel_source/novel_paginator.dart';
import 'package:novvera/foundation/res.dart';

const kNovelSourceKeys = {'wenku8', 'linovelib', 'huanmeng'};

bool isNovelSource(String? key) => key != null && kNovelSourceKeys.contains(key);

/// Canonical work page URL for share / open-in-browser.
String novelBookUrl(String sourceKey, String aid) {
  if (aid.isEmpty) return '';
  return switch (sourceKey) {
    'wenku8' => 'https://www.wenku8.net/book/$aid.htm',
    'linovelib' => 'https://www.linovelib.com/novel/$aid.html',
    'huanmeng' => 'https://www.huanmengacg.com/index.php/book/info/$aid',
    _ => '',
  };
}

/// Built-in light-novel sources backed by in-process Dart scrapers.
///
/// - **发现 (Explore)**: homepage recommendation sections (multipart)
/// - **分类 (Categories)**: per-source ranks / tags matching the site or App API
List<ComicSource> createBuiltinNovelSources() {
  return [
    _buildSource(name: '轻小说文库', key: 'wenku8'),
    _buildSource(name: '哔哩轻小说', key: 'linovelib'),
    _buildSource(name: '幻梦轻小说', key: 'huanmeng'),
  ];
}

/// Official wenku8 App / MewX rank tabs.
const _wenku8RankTypes = <String, String>{
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

/// https://www.linovelib.com/top.html sidebar.
const _linovelibRankTypes = <String, String>{
  'monthvisit': '月点击榜',
  'weekvisit': '周点击榜',
  'monthvote': '月推荐榜',
  'weekvote': '周推荐榜',
  'monthflower': '月鲜花榜',
  'weekflower': '周鲜花榜',
  'monthegg': '月鸡蛋榜',
  'weekegg': '周鸡蛋榜',
  'lastupdate': '最近更新',
  'postdate': '最新入库',
  'goodnum': '收藏榜',
  'newhot': '新书榜',
  'done': '全本',
};

/// https://www.huanmengacg.com — 排行 / 完本 + 题材 tags.
const _huanmengBoardTypes = <String, String>{
  'top': '排行',
  'done': '完本',
};

const _huanmengTagTypes = <String, String>{
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

Map<String, String> _rankTypesFor(String key) => switch (key) {
      'linovelib' => _linovelibRankTypes,
      'huanmeng' => {..._huanmengBoardTypes, ..._huanmengTagTypes},
      _ => _wenku8RankTypes,
    };

List<CategoryItem> _rankCategoryItems(String key, Map<String, String> types) {
  return types.entries
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
}

ComicSource _buildSource({
  required String name,
  required String key,
}) {
  final rankTypes = _rankTypesFor(key);
  final ranking = RankingData(
    Map<String, String>.from(rankTypes),
    (option, page) => _loadRank(key, option, page),
    null,
  );

  final List<BaseCategoryPart> categoryParts;
  if (key == 'huanmeng') {
    categoryParts = [
      FixedCategoryPart('榜单', _rankCategoryItems(key, _huanmengBoardTypes)),
      FixedCategoryPart('题材', _rankCategoryItems(key, _huanmengTagTypes)),
    ];
  } else if (key == 'linovelib') {
    categoryParts = [
      FixedCategoryPart('榜单', _rankCategoryItems(key, _linovelibRankTypes)),
    ];
  } else {
    categoryParts = [
      FixedCategoryPart('排行榜', _rankCategoryItems(key, _wenku8RankTypes)),
    ];
  }

  final categoryData = CategoryData(
    title: name,
    key: key,
    categories: categoryParts,
    enableRankingPage: false,
  );

  final categoryComicsData = CategoryComicsData(
    options: const [],
    load: (category, param, options, page) {
      final type = _resolveRankType(key, category, param, options);
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

  // wenku8 search UI has no type switch — App "综合" is articlename+author merge.
  // Author-only search is only reached via detail-page author chip (options=author).
  final List<SearchOptions>? searchOptions = null;

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
        options.isNotEmpty
            ? options.first
            : (key == 'wenku8' ? 'mixed' : 'articlename'),
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
    // Tag chips open search on the **same** source as the book.
    // 状态 / 更新时间 are metadata only (no jump). 分类 is not shown.
    (namespace, tag) {
      const nonSearch = {'状态', '更新时间', 'Upload Time', 'Update Time', '分类'};
      if (nonSearch.contains(namespace)) return null;
      final attrs = <String, dynamic>{'text': tag};
      if (key == 'wenku8') {
        if (namespace == '作者') {
          attrs['options'] = ['author'];
        } else if (namespace == '标签') {
          attrs['options'] = ['tag'];
        } else {
          attrs['options'] = ['mixed'];
        }
      }
      return PageJumpTarget(key, 'search', attrs);
    },
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

Map<String, dynamic> _imageLoadingConfig(String sourceKey, String imageKey) {
  final referer = switch (sourceKey) {
    'wenku8' => 'https://www.wenku8.net/',
    'huanmeng' => 'https://www.huanmengacg.com/',
    _ => 'https://www.linovelib.com/',
  };
  // Preserve custom cover schemes; only normalize http(s) novel images.
  final url = imageKey.startsWith('novvera://')
      ? imageKey
      : normalizeNovelImageUrl(imageKey);
  final ua = appdata.implicitData['ua'];
  return {
    'url': url,
    'headers': {
      'user-agent': (ua is String && ua.isNotEmpty) ? ua : webUA,
      'Referer': referer,
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    },
  };
}

String _fallbackCover(String sourceKey, String aid) {
  if (aid.isEmpty) return '';
  return switch (sourceKey) {
    'wenku8' => wenku8CoverUrl(aid),
    'linovelib' => linovelibCoverUrl(aid),
    'huanmeng' => huanmengCoverUrl(aid),
    _ => '',
  };
}

Comic _itemToComic(Map<String, dynamic> item, String sourceKey) {
  final aid = '${item['aid'] ?? ''}';
  final title = (item['name'] ?? item['title'] ?? '').toString();
  var cover = (item['cover'] ?? '').toString().trim();
  // Do not preferHttps custom schemes (novvera://wenku8/cover/…).
  if (cover.startsWith('http://') || cover.startsWith('https://')) {
    cover = preferHttps(cover);
  }
  if (cover.isEmpty && aid.isNotEmpty) {
    cover = _fallbackCover(sourceKey, aid);
  }
  // Wenku8 list payloads may still carry CDN links — force API cover scheme.
  if (sourceKey == 'wenku8' && aid.isNotEmpty) {
    cover = wenku8CoverUrl(aid);
  }
  var author = (item['author_raw'] ?? '').toString().trim();
  if (author.isEmpty) {
    author = (item['author'] ?? '').toString().trim();
  }
  // Flatten "作者:xxx/分类:yyy" from detail payloads reused in lists.
  final authorM = RegExp(r'^作者[:：]\s*([^/]+)').firstMatch(author);
  if (authorM != null) {
    author = authorM.group(1)!.trim();
  }
  author = author.replaceFirst(RegExp(r'^作者[:：]\s*'), '').trim();

  // List / search cards: title + author + cover only (no tag chips).
  return Comic(
    title,
    cover,
    aid,
    author,
    null,
    '',
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
      fullPageSize: source == 'linovelib'
          ? 20
          : source == 'huanmeng'
              ? 30
              : 10,
      parsed: pagerMax ?? int.tryParse('${data['max_page'] ?? ''}'),
    );
    return Res(items, subData: maxPage);
  } catch (e) {
    return Res.error(e.toString());
  }
}

String _resolveRankType(
  String source,
  String category,
  String? param,
  List<String> options,
) {
  final types = _rankTypesFor(source);
  if (param != null && types.containsKey(param)) {
    return param;
  }
  if (options.isNotEmpty && types.containsKey(options.first)) {
    return options.first;
  }
  for (final e in types.entries) {
    if (e.value == category || e.key == category) {
      return e.key;
    }
  }
  return types.keys.first;
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
    final searchType = const {'mixed', 'articlename', 'author'}.contains(type)
        ? type
        : (source == 'wenku8' ? 'mixed' : 'articlename');
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
      fullPageSize: source == 'linovelib'
          ? 20
          : source == 'huanmeng'
              ? 50
              : 10,
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
    var cover = (info['cover'] ?? '').toString().trim();
    if (source == 'wenku8') {
      cover = wenku8CoverUrl(id);
    } else {
      cover = preferHttps(cover);
      if (cover.isEmpty) {
        cover = _fallbackCover(source, id);
      }
    }
    final authorRaw = (info['author_raw'] ?? '').toString();
    var intro = (info['intro'] ?? '').toString().trim();
    if (intro.isEmpty) {
      intro = (info['description'] ?? '').toString().trim();
    }
    intro = intro.replaceFirst(RegExp(r'^.*?内容简介[：:]'), '').trim();
    final status = (info['status'] ?? '').toString();
    final updateTime = info['update_time']?.toString();
    final tags = <String, List<String>>{};
    if (authorRaw.isNotEmpty) {
      tags['作者'] = [authorRaw];
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
      'url': novelBookUrl(source, id),
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

/// Build Venera Reader pages for novels: ordered text/image blocks.
///
/// Returns an initial key list (paragraph-level text + images) so the comic
/// reader shell has something to show before gallery re-paginates to fill the
/// viewport. Continuous mode ignores per-line keys and uses [NovelPageCache.blocks].
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
    final trailingImages = (data['images'] as List? ?? [])
        .map((e) => normalizeNovelImageUrl(e.toString()))
        .where((e) => e.startsWith('http'))
        .toList();

    final blocks = parseNovelBlocks(
      text,
      trailingImages: trailingImages,
    );
    // Normalize image URLs in blocks.
    final normalized = <NovelBlock>[];
    for (final b in blocks) {
      if (b is NovelImageBlock) {
        final url = normalizeNovelImageUrl(b.url);
        if (url.startsWith('http')) {
          normalized.add(NovelImageBlock(url));
        }
      } else {
        normalized.add(b);
      }
    }
    NovelPageCache.setBlocks(normalized);

    // Seed reader.images: one key per block (text paragraphs / images).
    // Gallery mode will replace this with viewport-fill pages on layout.
    final pages = <String>[];
    for (final b in normalized) {
      if (b is NovelImageBlock) {
        pages.add(b.url);
      } else if (b is NovelTextBlock) {
        pages.add(NovelPageCache.put(b.text));
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
