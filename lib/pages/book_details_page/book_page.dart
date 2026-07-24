import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:shimmer_animation/shimmer_animation.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:novvera/components/components.dart';
import 'package:novvera/components/rich_comment_content.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/book_source/book_source.dart';
import 'package:novvera/foundation/book_type.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/favorites.dart';
import 'package:novvera/foundation/history.dart';
import 'package:novvera/foundation/image_provider/cached_image.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/foundation/res.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/foundation/novel_source/builtin_sources.dart';
import 'package:novvera/foundation/novel_source/novel_paginator.dart';
import 'package:novvera/network/download.dart';
import 'package:novvera/network/cache.dart';
import 'package:novvera/network/images.dart';
import 'package:novvera/pages/favorites/favorites_page.dart';
import 'package:novvera/pages/reader/reader.dart';
import 'package:novvera/utils/file_type.dart';
import 'package:novvera/utils/io.dart';
import 'package:novvera/utils/tags_translation.dart';
import 'package:novvera/utils/translations.dart';
import 'dart:math' as math;

part 'comments_page.dart';

part 'chapters.dart';

part 'thumbnails.dart';

part 'favorite.dart';

part 'comments_preview.dart';

part 'actions.dart';

part 'cover_viewer.dart';

class BookPage extends StatefulWidget {
  const BookPage({
    super.key,
    required this.id,
    required this.sourceKey,
    this.cover,
    this.title,
    this.heroID,
  });

  final String id;

  final String sourceKey;

  final String? cover;

  final String? title;

  final int? heroID;

  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends LoadingState<BookPage, BookDetails>
    with _BookPageActions {
  @override
  History? history;

  bool showAppbarTitle = false;

  var scrollController = ScrollController();

  bool isDownloaded = false;

  bool showFAB = false;

  @override
  void onReadEnd() {
    history ??= HistoryManager().find(
      widget.id,
      BookType(widget.sourceKey.hashCode),
    );
    update();
  }

  @override
  Widget buildLoading() {
    return _BookPageLoadingPlaceHolder(
      cover: widget.cover,
      title: widget.title,
      sourceKey: widget.sourceKey,
      cid: widget.id,
      heroID: widget.heroID,
    );
  }

  @override
  Widget buildError() {
    final isDownloaded = LocalManager().isDownloaded(
      widget.id,
      BookType.fromKey(widget.sourceKey),
    );
    Widget? action;
    if (isDownloaded) {
      action = FilledButton.tonal(
        child: Text("Read".tl),
        onPressed: () {
          final localBook = LocalManager().find(
            widget.id,
            BookType.fromKey(widget.sourceKey),
          );
          if (localBook == null) {
            context.showMessage(message: "Local book not found".tl);
            return;
          }
          localBook.read();
        },
      );
    }
    return NetworkError(message: error!, retry: retry, action: action);
  }

  @override
  void initState() {
    scrollController.addListener(onScroll);
    LocalManager().addListener(_onLocalChange);
    super.initState();
  }

  @override
  void dispose() {
    scrollController.removeListener(onScroll);
    LocalManager().removeListener(_onLocalChange);
    super.dispose();
  }

  void _onLocalChange() {
    if (!mounted || data == null) return;
    _refreshDownloadedFlag();
    setState(() {});
  }

  void _refreshDownloadedFlag() {
    final c = data;
    if (c == null) return;
    if (c.chapters == null) {
      isDownloaded =
          LocalManager().isDownloaded(c.id, c.bookType, 0);
      return;
    }
    final local = LocalManager().find(c.id, c.bookType);
    if (local == null) {
      isDownloaded = false;
      return;
    }
    isDownloaded =
        local.downloadedChapters.length >= c.chapters!.length;
  }

  @override
  void update() {
    setState(() {});
  }

  @override
  BookDetails get book => data!;

  void onScroll() {
    var offset =
        scrollController.position.pixels -
        scrollController.position.minScrollExtent;
    var showFAB = offset > 0;
    if (showFAB != this.showFAB) {
      setState(() {
        this.showFAB = showFAB;
      });
    }
    if (offset > 100) {
      if (!showAppbarTitle) {
        setState(() {
          showAppbarTitle = true;
        });
      }
    } else {
      if (showAppbarTitle) {
        setState(() {
          showAppbarTitle = false;
        });
      }
    }
  }

  var isFirst = true;

  @override
  Widget buildContent(BuildContext context, BookDetails data) {
    return Scaffold(
      floatingActionButton: showFAB
          ? FloatingActionButton(
              onPressed: () {
                scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.ease,
                );
              },
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: SmoothCustomScrollView(
        controller: scrollController,
        slivers: [
          ...buildTitle(),
          buildActions(),
          buildDescription(),
          buildInfo(),
          buildChapters(),
          buildComments(),
          buildThumbnails(),
          buildRecommend(),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: context.padding.bottom + 80,
            ), // Add additional padding for FAB
          ),
        ],
      ),
    );
  }

  @override
  Future<Res<BookDetails>> loadData() async {
    if (widget.sourceKey == 'local') {
      var localBook = LocalManager().find(widget.id, BookType.local);
      if (localBook == null) {
        return const Res.error('Local book not found');
      }
      var history = HistoryManager().find(widget.id, BookType.local);
      if (isFirst) {
        Future.microtask(() {
          App.rootContext.to(() {
            return Reader(
              type: BookType.local,
              cid: widget.id,
              name: localBook.title,
              chapters: localBook.chapters,
              initialPage: history?.page,
              initialChapter: history?.ep,
              initialChapterGroup: history?.group,
              history:
                  history ??
                  History.fromModel(model: localBook, ep: 0, page: 0),
              author: localBook.subTitle ?? '',
              tags: localBook.tags,
            );
          });
          App.mainNavigatorKey!.currentContext!.pop();
        });
        isFirst = false;
      }
      await Future.delayed(const Duration(milliseconds: 200));
      return const Res.error('Local book');
    }
    var bookSource = BookSource.find(widget.sourceKey);
    if (bookSource == null) {
      return const Res.error('Book source not found');
    }
    isAddToLocalFav = LocalFavoritesManager().isExist(
      widget.id,
      BookType(widget.sourceKey.hashCode),
    );
    history = HistoryManager().find(
      widget.id,
      BookType(widget.sourceKey.hashCode),
    );
    return bookSource.loadBookInfo!(widget.id);
  }

  /// Prefer freshly loaded cover over the optional hero/history cover.
  /// History may hold a stale/junk URL (e.g. huanmeng og:image bait).
  String get _displayCover {
    final loaded = book.cover.trim();
    if (loaded.isNotEmpty) return loaded;
    return (widget.cover ?? '').trim();
  }

  @override
  Future<void> onDataLoaded() async {
    isLiked = book.isLiked ?? false;
    isFavorite = book.isFavorite ?? false;
    // Refresh history cover when detail has a better URL.
    final hist = history;
    final loaded = book.cover.trim();
    if (hist != null &&
        loaded.isNotEmpty &&
        hist.cover.trim() != loaded) {
      hist.cover = loaded;
      hist.title = book.title;
      if (book.subTitle != null && book.subTitle!.isNotEmpty) {
        hist.subtitle = book.subTitle!;
      }
      HistoryManager().addHistory(hist);
    }
    // For sources with multi-folder favorites, prefer querying folders to get accurate favorite status
    // Some sources may not set isFavorite reliably when multi-folder is enabled
    if (bookSource.favoriteData?.loadFolders != null && bookSource.isLogged) {
      var res = await bookSource.favoriteData!.loadFolders!(book.id);
      if (!res.error) {
        if (res.subData is List) {
          var list = List<String>.from(res.subData);
          isFavorite = list.isNotEmpty;
          update();
        }
      }
    }
    if (book.chapters == null) {
      isDownloaded = LocalManager().isDownloaded(book.id, book.bookType, 0);
    } else {
      _refreshDownloadedFlag();
    }
  }

  Iterable<Widget> buildTitle() sync* {
    yield SliverAppbar(
      title: AnimatedOpacity(
        opacity: showAppbarTitle ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Text(book.title),
      ),
      actions: [
        IconButton(
          onPressed: showMoreActions,
          icon: const Icon(Icons.more_horiz),
        ),
      ],
    );

    yield const SliverPadding(padding: EdgeInsets.only(top: 8));

    yield SliverLazyToBoxAdapter(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 16),
          GestureDetector(
            onTap: () => _viewCover(context),
            onLongPress: () => _saveCover(context),
            child: Hero(
              tag: "cover${widget.heroID}",
              child: Container(
                decoration: BoxDecoration(
                  color: context.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: context.colorScheme.outlineVariant,
                      blurRadius: 1,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                height: 144,
                width: 144 * 0.72,
                clipBehavior: Clip.antiAlias,
                child: AnimatedImage(
                  image: CachedImageProvider(
                    _displayCover,
                    sourceKey: book.sourceKey,
                    cid: book.id,
                  ),
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(book.title, style: ts.s18),
                if (book.subTitle != null)
                  SelectableText(
                    book.subTitle!,
                    style: ts.s14,
                  ).paddingVertical(4),
                Text(
                  (BookSource.find(book.sourceKey)?.name) ?? '',
                  style: ts.s12,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    bool isMobile = context.width < changePoint;
    bool hasHistory = history != null && (history!.ep > 1 || history!.page > 1);
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (hasHistory && !isMobile)
                _ActionButton(
                  icon: const Icon(Icons.menu_book),
                  text: 'Continue'.tl,
                  onPressed: continueRead,
                  iconColor: context.useTextColor(Colors.yellow),
                ),
              if (!isMobile || hasHistory)
                _ActionButton(
                  icon: const Icon(Icons.play_circle_outline),
                  text: 'Start'.tl,
                  onPressed: read,
                  iconColor: context.useTextColor(Colors.orange),
                ),
              if (!isMobile && !isDownloaded)
                _ActionButton(
                  icon: const Icon(Icons.download),
                  text: 'Download'.tl,
                  onPressed: download,
                  iconColor: context.useTextColor(Colors.cyan),
                ),
              if (data!.isLiked != null)
                _ActionButton(
                  icon: const Icon(Icons.favorite_border),
                  activeIcon: const Icon(Icons.favorite),
                  isActive: isLiked,
                  text:
                      ((data!.likesCount != null)
                              ? (data!.likesCount! + (isLiked ? 1 : 0))
                              : (isLiked ? 'Liked'.tl : 'Like'.tl))
                          .toString(),
                  isLoading: isLiking,
                  onPressed: likeOrUnlike,
                  iconColor: context.useTextColor(Colors.red),
                ),
              _ActionButton(
                icon: const Icon(Icons.bookmark_outline_outlined),
                activeIcon: const Icon(Icons.bookmark),
                isActive: isFavorite || isAddToLocalFav,
                text: 'Favorite'.tl,
                onPressed: openFavPanel,
                onLongPressed: quickFavorite,
                iconColor: context.useTextColor(Colors.purple),
              ),
              if (bookSource.commentsLoader != null)
                _ActionButton(
                  icon: const Icon(Icons.comment),
                  text: (book.commentCount ?? 'Comments'.tl).toString(),
                  onPressed: showComments,
                  iconColor: context.useTextColor(Colors.green),
                ),
              _ActionButton(
                icon: const Icon(Icons.share),
                text: 'Share'.tl,
                onPressed: share,
                iconColor: context.useTextColor(Colors.blue),
              ),
            ],
          ).fixHeight(48),
          if (isMobile)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: download,
                    child: Text("Download".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: hasHistory
                      ? FilledButton(
                          onPressed: continueRead,
                          child: Text("Continue".tl),
                        )
                      : FilledButton(onPressed: read, child: Text("Read".tl)),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          if (history != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, color: context.useTextColor(Colors.teal)),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (context) {
                      bool haveChapter = book.chapters != null;
                      var page = history!.page;
                      var ep = history!.ep;
                      var group = history!.group;
                      String text;
                      if (haveChapter) {
                        var epName = "E$ep";
                        String? groupName;
                        try {
                          if (group == null) {
                            epName = book.chapters!.titles.elementAt(
                              math.min(ep - 1, book.chapters!.length - 1),
                            );
                          } else {
                            groupName = book.chapters!.groups.elementAt(
                              group - 1,
                            );
                            epName = book.chapters!
                                .getGroupByIndex(group - 1)
                                .values
                                .elementAt(ep - 1);
                          }
                        } catch (e) {
                          // ignore
                        }
                        text = groupName == null
                            ? isNovelSource(book.sourceKey)
                                ? "${"Last Reading".tl}: $epName"
                                : "${"Last Reading".tl}: $epName P$page"
                            : isNovelSource(book.sourceKey)
                                ? "${"Last Reading".tl}: $groupName $epName"
                                : "${"Last Reading".tl}: $groupName $epName P$page";
                      } else {
                        text = isNovelSource(book.sourceKey)
                            ? "Last Reading".tl
                            : "${"Last Reading".tl}: P$page";
                      }
                      return Text(text);
                    },
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
          const Divider(),
        ],
      ).paddingTop(16),
    );
  }

  Widget buildDescription() {
    if (book.description == null || book.description!.trim().isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListTile(title: Text("Description".tl)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(book.description!).fixWidth(double.infinity),
          ),
          const SizedBox(height: 16),
          const Divider(),
        ],
      ),
    );
  }

  Widget buildInfo() {
    if (book.tags.isEmpty &&
        book.uploader == null &&
        book.uploadTime == null &&
        book.uploadTime == null &&
        book.maxPage == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }

    int i = 0;

    Widget buildTag({
      required String text,
      VoidCallback? onTap,
      bool isTitle = false,
    }) {
      Color color;
      if (isTitle) {
        const colors = [
          Colors.blue,
          Colors.cyan,
          Colors.red,
          Colors.pink,
          Colors.purple,
          Colors.indigo,
          Colors.teal,
          Colors.green,
          Colors.lime,
          Colors.yellow,
        ];
        color = context.useBackgroundColor(colors[(i++) % (colors.length)]);
      } else {
        color = context.colorScheme.surfaceContainerLow;
      }

      final borderRadius = BorderRadius.circular(12);

      const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 6);

      if (onTap != null) {
        return Material(
          color: color,
          borderRadius: borderRadius,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: onTap,
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: text));
              context.showMessage(message: "Copied".tl);
            },
            onSecondaryTapDown: (details) {
              showMenuX(context, details.globalPosition, [
                MenuEntry(
                  icon: Icons.remove_red_eye,
                  text: "View".tl,
                  onClick: onTap,
                ),
                MenuEntry(
                  icon: Icons.copy,
                  text: "Copy".tl,
                  onClick: () {
                    Clipboard.setData(ClipboardData(text: text));
                    context.showMessage(message: "Copied".tl);
                  },
                ),
              ]);
            },
            child: Text(text).padding(padding),
          ),
        );
      } else {
        return Container(
          decoration: BoxDecoration(color: color, borderRadius: borderRadius),
          child: Text(text).padding(padding),
        );
      }
    }

    String formatTime(String time) {
      if (int.tryParse(time) != null) {
        var t = int.tryParse(time);
        if (t! > 1000000000000) {
          return DateTime.fromMillisecondsSinceEpoch(
            t,
          ).toString().substring(0, 19);
        } else {
          return DateTime.fromMillisecondsSinceEpoch(
            t * 1000,
          ).toString().substring(0, 19);
        }
      }
      if (time.contains('T') || time.contains('Z')) {
        var t = DateTime.parse(time);
        return t.toString().substring(0, 19);
      }
      return time;
    }

    Widget buildWrap({required List<Widget> children}) {
      return Wrap(
        runSpacing: 8,
        spacing: 8,
        children: children,
      ).paddingHorizontal(16).paddingBottom(8);
    }

    bool enableTranslation =
        App.locale.languageCode == 'zh' && bookSource.enableTagsTranslate;

    return SliverLazyToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text("Information".tl)),
          if (book.stars != null)
            Row(
              children: [
                StarRating(value: book.stars!, size: 24, onTap: starRating),
                const SizedBox(width: 8),
                Text(book.stars!.toStringAsFixed(2)),
              ],
            ).paddingLeft(16).paddingVertical(8),
          for (var e in book.tags.entries)
            buildWrap(
              children: [
                if (e.value.isNotEmpty)
                  buildTag(text: e.key.ts(bookSource.key), isTitle: true),
                for (var tag in e.value)
                  buildTag(
                    text: enableTranslation
                        ? TagsTranslation.translationTagWithNamespace(
                            tag,
                            e.key.toLowerCase(),
                          )
                        : tag,
                    onTap: bookSource.handleClickTagEvent
                                ?.call(e.key, tag) !=
                            null
                        ? () => onTapTag(tag, e.key)
                        : null,
                  ),
              ],
            ),
          if (book.uploader != null)
            buildWrap(
              children: [
                buildTag(text: 'Uploader'.tl, isTitle: true),
                buildTag(text: book.uploader!),
              ],
            ),
          if (book.uploadTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Upload Time'.tl, isTitle: true),
                buildTag(text: formatTime(book.uploadTime!)),
              ],
            ),
          if (book.updateTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Update Time'.tl, isTitle: true),
                buildTag(text: formatTime(book.updateTime!)),
              ],
            ),
          if (book.maxPage != null)
            buildWrap(
              children: [
                buildTag(text: 'Pages'.tl, isTitle: true),
                buildTag(text: book.maxPage.toString()),
              ],
            ),
          const SizedBox(height: 12),
          const Divider(),
        ],
      ),
    );
  }

  Widget buildChapters() {
    if (book.chapters == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _BookChapters(
      history: history,
      groupedMode: book.chapters!.isGrouped,
    );
  }

  Widget buildThumbnails() {
    if (book.thumbnails == null && bookSource.loadBookThumbnail == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return const _BookThumbnails();
  }

  Widget buildRecommend() {
    if (book.recommend == null || book.recommend!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: ListTile(title: Text("Related".tl))),
        SliverGridBooks(books: book.recommend!),
      ],
    );
  }

  Widget buildComments() {
    if (book.comments == null || book.comments!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _CommentsPart(comments: book.comments!, showMore: showComments);
  }

  void _viewCover(BuildContext context) {
    final imageProvider = CachedImageProvider(
      _displayCover,
      sourceKey: book.sourceKey,
      cid: book.id,
    );

    context.to(
      () => _CoverViewer(
        imageProvider: imageProvider,
        title: book.title,
        heroTag: "cover${widget.heroID}",
      ),
    );
  }

  void _saveCover(BuildContext context) async {
    try {
      final imageProvider = CachedImageProvider(
        _displayCover,
        sourceKey: book.sourceKey,
        cid: book.id,
      );

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<Uint8List>();

      imageStream.addListener(
        ImageStreamListener((ImageInfo info, bool _) async {
          final byteData = await info.image.toByteData(
            format: ImageByteFormat.png,
          );
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          }
        }),
      );

      final data = await completer.future;
      final fileType = detectFileType(data);
      await saveFile(filename: "cover${fileType.ext}", data: data);
    } catch (e) {
      if (context.mounted) {
        context.showMessage(message: "Error".tl);
      }
    }
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    this.onLongPressed,
    this.activeIcon,
    this.isActive,
    this.isLoading,
    this.iconColor,
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool? isActive;

  final String text;

  final void Function() onPressed;

  final bool? isLoading;

  final Color? iconColor;

  final void Function()? onLongPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (!(isLoading ?? false)) {
            onPressed();
          }
        },
        onLongPress: onLongPressed,
        borderRadius: BorderRadius.circular(18),
        child: IconTheme.merge(
          data: IconThemeData(size: 20, color: iconColor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading ?? false)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                (isActive ?? false) ? (activeIcon ?? icon) : icon,
              const SizedBox(width: 8),
              Text(text),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}

class _NovelChapterPick {
  const _NovelChapterPick({
    required this.volume,
    required this.id,
    required this.title,
  });
  final String volume;
  final String id;
  final String title;
}

class _NovelDownloadVolume {
  const _NovelDownloadVolume({required this.name, required this.chapters});
  final String name;
  final List<_NovelChapterPick> chapters;
}

class _SelectNovelEpubDownload extends StatefulWidget {
  const _SelectNovelEpubDownload({
    required this.volumes,
    required this.onConfirm,
  });

  final List<_NovelDownloadVolume> volumes;
  final void Function(List<_NovelChapterPick>) onConfirm;

  @override
  State<_SelectNovelEpubDownload> createState() =>
      _SelectNovelEpubDownloadState();
}

class _SelectNovelEpubDownloadState extends State<_SelectNovelEpubDownload> {
  late final Set<String> selectedIds;

  @override
  void initState() {
    super.initState();
    selectedIds = {};
  }

  Iterable<_NovelChapterPick> get _allChapters sync* {
    for (final v in widget.volumes) {
      yield* v.chapters;
    }
  }

  bool _volumeFullySelected(_NovelDownloadVolume vol) {
    if (vol.chapters.isEmpty) return false;
    return vol.chapters.every((c) => selectedIds.contains(c.id));
  }

  bool _volumePartiallySelected(_NovelDownloadVolume vol) {
    final n = vol.chapters.where((c) => selectedIds.contains(c.id)).length;
    return n > 0 && n < vol.chapters.length;
  }

  void _toggleVolume(_NovelDownloadVolume vol, bool? checked) {
    setState(() {
      if (checked == true) {
        for (final c in vol.chapters) {
          selectedIds.add(c.id);
        }
      } else {
        for (final c in vol.chapters) {
          selectedIds.remove(c.id);
        }
      }
    });
  }

  List<_NovelChapterPick> _selectedPicks() {
    final map = {for (final c in _allChapters) c.id: c};
    return [
      for (final c in _allChapters)
        if (selectedIds.contains(c.id)) map[c.id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.volumes.length,
              itemBuilder: (context, vi) {
                final vol = widget.volumes[vi];
                final full = _volumeFullySelected(vol);
                final partial = _volumePartiallySelected(vol);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CheckboxListTile(
                      title: Text(
                        vol.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${vol.chapters.length} ${"Chapters".tl}',
                      ),
                      value: full
                          ? true
                          : (partial ? null : false),
                      tristate: true,
                      onChanged: (_) {
                        _toggleVolume(vol, !full);
                      },
                    ),
                    for (final chap in vol.chapters)
                      CheckboxListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 36,
                          right: 16,
                        ),
                        title: Text(chap.title),
                        value: selectedIds.contains(chap.id),
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              selectedIds.add(chap.id);
                            } else {
                              selectedIds.remove(chap.id);
                            }
                          });
                        },
                      ),
                  ],
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      widget.onConfirm(_allChapters.toList());
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selectedIds.isEmpty
                        ? null
                        : () {
                            widget.onConfirm(_selectedPicks());
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(this.eps, this.finishSelect, this.downloadedEps);

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.eps.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      var res = <int>[];
                      for (int i = 0; i < widget.eps.length; i++) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(selected);
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _BookPageLoadingPlaceHolder extends StatelessWidget {
  const _BookPageLoadingPlaceHolder({
    this.cover,
    this.title,
    required this.sourceKey,
    required this.cid,
    this.heroID,
  });

  final String? cover;

  final String? title;

  final String sourceKey;

  final String cid;

  final int? heroID;

  @override
  Widget build(BuildContext context) {
    Widget buildContainer(
      double? width,
      double? height, {
      Color? color,
      double? radius,
    }) {
      return Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: color ?? context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(radius ?? 4),
        ),
      );
    }

    return Shimmer(
      color: context.isDarkMode ? Colors.grey.shade700 : Colors.white,
      child: Column(
        children: [
          Appbar(title: Text(""), backgroundColor: context.colorScheme.surface),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 16),
              buildImage(context),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Text(title ?? "", style: ts.s18)
                    else
                      buildContainer(200, 25),
                    const SizedBox(height: 8),
                    buildContainer(80, 20),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (context.width < changePoint)
            Row(
              children: [
                Expanded(child: buildContainer(null, 36, radius: 18)),
                const SizedBox(width: 16),
                Expanded(child: buildContainer(null, 36, radius: 18)),
              ],
            ).paddingHorizontal(16),
          const Divider(),
          const SizedBox(height: 8),
          Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
            ).fixHeight(24).fixWidth(24),
          ),
        ],
      ),
    );
  }

  Widget buildImage(BuildContext context) {
    Widget child;
    if (cover != null) {
      child = AnimatedImage(
        image: CachedImageProvider(cover!, sourceKey: sourceKey, cid: cid),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      );
    } else {
      child = const SizedBox();
    }

    return Hero(
      tag: "cover$heroID",
      child: Container(
        decoration: BoxDecoration(
          color: context.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: context.colorScheme.outlineVariant,
              blurRadius: 1,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        height: 144,
        width: 144 * 0.72,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
