import 'dart:collection';

import 'package:novvera/foundation/comic_source/comic_source.dart';
import 'package:novvera/foundation/novel_api/novel_api_client.dart';
import 'package:novvera/foundation/res.dart';

const kNovelSourceKeys = {'wenku8', 'linovelib'};

bool isNovelSource(String? key) => key != null && kNovelSourceKeys.contains(key);

/// Built-in light-novel sources backed by in-process Dart scrapers.
List<ComicSource> createBuiltinNovelSources() {
  return [
    _buildSource(
      name: '轻小说文库',
      key: 'wenku8',
      rankPrefix: '文库8',
    ),
    _buildSource(
      name: '哔哩轻小说',
      key: 'linovelib',
      rankPrefix: '哔哩',
    ),
  ];
}

const _rankTypes = <String, String>{
  'allvisit': '总点击',
  'allvote': '总推荐',
  'monthvisit': '月点击',
  'lastupdate': '最近更新',
  'postdate': '新书',
  'goodnum': '收藏',
  'done': '完结',
};

ComicSource _buildSource({
  required String name,
  required String key,
  required String rankPrefix,
}) {
  final explorePages = _rankTypes.entries
      .map(
        (e) => ExplorePageData(
          '$rankPrefix·${e.value}',
          ExplorePageType.multiPageComicList,
          (page) => _loadRank(key, e.key, page),
          null,
          null,
          null,
        ),
      )
      .toList();

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

  final source = ComicSource(
    name,
    key,
    null, // account
    null, // categoryData
    null, // categoryComicsData
    null, // favoriteData — local favorites only
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
    null, // settings
    (id) => _loadComicInfo(key, id),
    null, // loadComicThumbnail
    null, // loadComicPages — novel reader fetches text
    null, // getImageLoadingConfig
    null, // getThumbnailLoadingConfig
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
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
  return source;
}

Comic _itemToComic(Map<String, dynamic> item, String sourceKey) {
  final aid = '${item['aid'] ?? ''}';
  final title = (item['name'] ?? item['title'] ?? '').toString();
  final cover = (item['cover'] ?? '').toString();
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
    // Heuristic: empty page means no more; otherwise allow next
    final maxPage = items.isEmpty ? page : page + 1;
    return Res(items, subData: maxPage);
  } catch (e) {
    return Res.error(e.toString());
  }
}

Future<Res<List<Comic>>> _loadSearch(
  String source,
  String keyword,
  int page,
  String type,
) async {
  try {
    final data = await NovelApiClient.instance.get(
      source,
      '/search',
      query: {
        'keyword': keyword,
        'type': type,
        'page': page,
        'fmt': 'utf8',
      },
    );
    final items = (data['items'] as List? ?? [])
        .whereType<Map>()
        .map((e) => _itemToComic(Map<String, dynamic>.from(e), source))
        .toList();
    final maxPage = items.isEmpty ? page : page + 1;
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
    final cover = (info['cover'] ?? '').toString();
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
