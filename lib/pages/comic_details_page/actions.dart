part of 'comic_page.dart';

abstract mixin class _ComicPageActions {
  void update();

  ComicDetails get comic;

  ComicSource get comicSource => ComicSource.find(comic.sourceKey)!;

  History? get history;

  bool isLiking = false;

  bool isLiked = false;

  void likeOrUnlike() async {
    if (isLiking) return;
    isLiking = true;
    update();
    var res = await comicSource.likeOrUnlikeComic!(comic.id, isLiked);
    if (res.error) {
      App.rootContext.showMessage(message: res.errorMessage!);
    } else {
      isLiked = !isLiked;
    }
    isLiking = false;
    update();
  }

  /// whether the comic is added to local favorite
  bool isAddToLocalFav = false;

  /// whether the comic is favorite on the server
  bool isFavorite = false;

  FavoriteItem _toFavoriteItem() {
    var tags = <String>[];
    for (var e in comic.tags.entries) {
      tags.addAll(e.value.map((tag) => '${e.key}:$tag'));
    }
    return FavoriteItem(
      id: comic.id,
      name: comic.title,
      coverPath: comic.cover,
      author: comic.subTitle ?? comic.uploader ?? '',
      type: comic.comicType,
      tags: tags,
    );
  }

  void openFavPanel() {
    showSideBar(
      App.rootContext,
      _FavoritePanel(
        cid: comic.id,
        type: comic.comicType,
        isFavorite: isFavorite,
        onFavorite: (local, network) {
          if (network != null) {
            isFavorite = network;
          }
          if (local != null) {
            isAddToLocalFav = local;
          }
          update();
        },
        favoriteItem: _toFavoriteItem(),
        updateTime: comic.findUpdateTime(),
      ),
    );
  }

  void quickFavorite() {
    var folder = appdata.settings['quickFavorite'];
    if (folder is! String) {
      return;
    }
    LocalFavoritesManager().addComic(
      folder,
      _toFavoriteItem(),
      null,
      comic.findUpdateTime(),
    );
    isAddToLocalFav = true;
    update();
    App.rootContext.showMessage(message: "Added".tl);
  }

  void share() {
    var text = comic.title;
    final url = (comic.url != null && comic.url!.isNotEmpty)
        ? comic.url!
        : (isNovelSource(comic.sourceKey)
            ? novelBookUrl(comic.sourceKey, comic.id)
            : '');
    if (url.isNotEmpty) {
      text += '\n$url';
    }
    Share.shareText(text);
  }

  /// read the comic
  ///
  /// [ep] the episode number, start from 1
  ///
  /// [page] the page number, start from 1
  ///
  /// [group] the chapter group number, start from 1
  void read([int? ep, int? page, int? group]) {
    final hist = history ?? History.fromModel(model: comic, ep: 0, page: 0);
    final pageWidget = Reader(
      type: comic.comicType,
      cid: comic.id,
      name: comic.title,
      chapters: comic.chapters,
      initialChapter: ep,
      initialPage: page,
      initialChapterGroup: group,
      history: hist,
      author: comic.findAuthor() ?? '',
      tags: comic.plainTags,
    );
    App.rootContext.to(() => pageWidget).then((_) {
      onReadEnd();
    });
  }

  void continueRead() {
    var ep = history?.ep ?? 1;
    var page = history?.page ?? 1;
    var group = history?.group ?? 1;
    read(ep, page, group);
  }

  void onReadEnd();

  void download() async {
    if (isNovelSource(comic.sourceKey)) {
      await _downloadNovelAsEpub();
      return;
    }
    if (LocalManager().isDownloading(comic.id, comic.comicType)) {
      App.rootContext.showMessage(message: "The comic is downloading".tl);
      return;
    }
    if (comic.chapters == null &&
        LocalManager().isDownloaded(comic.id, comic.comicType, 0)) {
      App.rootContext.showMessage(message: "The comic is downloaded".tl);
      return;
    }

    if (comicSource.archiveDownloader != null) {
      bool useNormalDownload = false;
      List<ArchiveInfo>? archives;
      int selected = -1;
      bool isLoading = false;
      bool isGettingLink = false;
      await showDialog(
        context: App.rootContext,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setState) {
              return ContentDialog(
                title: "Download".tl,
                content: RadioGroup<int>(
                  groupValue: selected,
                  onChanged: (v) {
                    setState(() {
                      selected = v ?? selected;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<int>(
                        value: -1,
                        title: Text("Normal".tl),
                      ),
                      ExpansionTile(
                        title: Text("Archive".tl),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        collapsedShape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        onExpansionChanged: (b) {
                          if (!isLoading && b && archives == null) {
                            isLoading = true;
                            comicSource.archiveDownloader!
                                .getArchives(comic.id)
                                .then((value) {
                              if (value.success) {
                                archives = value.data;
                              } else {
                                App.rootContext
                                    .showMessage(message: value.errorMessage!);
                              }
                              setState(() {
                                isLoading = false;
                              });
                            });
                          }
                        },
                        children: [
                          if (archives == null)
                            const ListLoadingIndicator().toCenter()
                          else
                            for (int i = 0; i < archives!.length; i++)
                              RadioListTile<int>(
                                value: i,
                                title: Text(archives![i].title),
                                subtitle: Text(archives![i].description),
                              )
                        ],
                      )
                    ],
                  ),
                ),
                actions: [
                  Button.filled(
                    isLoading: isGettingLink,
                    onPressed: () async {
                      if (selected == -1) {
                        useNormalDownload = true;
                        context.pop();
                        return;
                      }
                      setState(() {
                        isGettingLink = true;
                      });
                      var res =
                          await comicSource.archiveDownloader!.getDownloadUrl(
                        comic.id,
                        archives![selected].id,
                      );
                      if (res.error) {
                        App.rootContext.showMessage(message: res.errorMessage!);
                        setState(() {
                          isGettingLink = false;
                        });
                      } else if (context.mounted) {
                        if (res.data.isNotEmpty) {
                          LocalManager()
                            .addTask(ArchiveDownloadTask(res.data, comic));
                          App.rootContext
                            .showMessage(message: "Download started".tl);
                        }
                        context.pop();
                      }
                    },
                    child: Text("Confirm".tl),
                  ),
                ],
              );
            },
          );
        },
      );
      if (!useNormalDownload) {
        return;
      }
    }

    if (comic.chapters == null) {
      LocalManager().addTask(ImagesDownloadTask(
        source: comicSource,
        comicId: comic.id,
        comic: comic,
      ));
    } else {
      List<int>? selected;
      var downloaded = <int>[];
      var localComic = LocalManager().find(comic.id, comic.comicType);
      if (localComic != null) {
        for (int i = 0; i < comic.chapters!.length; i++) {
          if (localComic.downloadedChapters
              .contains(comic.chapters!.ids.elementAt(i))) {
            downloaded.add(i);
          }
        }
      }
      await showSideBar(
        App.rootContext,
        _SelectDownloadChapter(
          comic.chapters!.titles.toList(),
          (v) => selected = v,
          downloaded,
        ),
      );
      if (selected == null) return;
      LocalManager().addTask(ImagesDownloadTask(
        source: comicSource,
        comicId: comic.id,
        comic: comic,
        chapters: selected!.map((i) {
          return comic.chapters!.ids.elementAt(i);
        }).toList(),
      ));
    }
    App.rootContext.showMessage(message: "Download started".tl);
    update();
  }

  /// Fetch selected chapters and save a text EPUB (not comic image packs).
  Future<void> _downloadNovelAsEpub() async {
    if (comic.chapters == null || comic.chapters!.length == 0) {
      App.rootContext.showMessage(message: "No chapters".tl);
      return;
    }

    List<int>? selected;
    await showSideBar(
      App.rootContext,
      _SelectDownloadChapter(
        comic.chapters!.titles.toList(),
        (v) => selected = v,
        const [],
      ),
    );
    if (selected == null || selected!.isEmpty) return;

    final chapterIds = selected!
        .map((i) => comic.chapters!.ids.elementAt(i))
        .toList();
    final chapterTitles = selected!
        .map((i) => comic.chapters!.titles.elementAt(i))
        .toList();

    var canceled = false;
    final loading = showLoadingDialog(
      App.rootContext,
      allowCancel: true,
      message: "${"Exporting".tl} 0/${chapterIds.length}",
      withProgress: true,
      onCancel: () => canceled = true,
    );

    try {
      // Cover
      List<int>? coverBytes;
      var coverExt = 'jpg';
      try {
        await for (final p in ImageDownloader.loadThumbnail(
          comic.cover,
          comic.sourceKey,
          comic.id,
        )) {
          if (p.imageBytes != null) {
            coverBytes = p.imageBytes;
            coverExt = detectFileType(p.imageBytes!).ext.replaceFirst('.', '');
            if (coverExt.isEmpty) coverExt = 'jpg';
            break;
          }
        }
      } catch (_) {}

      final chaptersHtml = <String, String>{};
      final imageCache = <String, String>{};
      var imgIndex = 0;
      final pendingImages = <({String url, String rel})>[];

      for (var i = 0; i < chapterIds.length; i++) {
        if (canceled) {
          loading.close();
          return;
        }
        loading.setMessage(
          "${"Exporting".tl} ${i + 1}/${chapterIds.length}",
        );
        loading.setProgress((i + 1) / (chapterIds.length + 1));

        final epId = chapterIds[i];
        final title = chapterTitles[i];
        final res = await loadNovelChapter(comic.sourceKey, comic.id, epId);
        if (res.error) {
          chaptersHtml[title] =
              '<p>${_xmlEsc(res.errorMessage ?? "load failed")}</p>';
          continue;
        }
        final data = res.data;
        final text = (data['content'] ?? '').toString();
        final trailing = (data['images'] as List? ?? [])
            .map((e) => e.toString())
            .where((e) => e.startsWith('http'))
            .toList();
        final blocks = parseNovelBlocks(text, trailingImages: trailing);
        final body = StringBuffer();
        for (final b in blocks) {
          if (b is NovelTextBlock) {
            for (final para in b.text.split(RegExp(r'\n+'))) {
              final t = para.trim();
              if (t.isEmpty) continue;
              body.writeln('    <p>${_xmlEsc(t)}</p>');
            }
          } else if (b is NovelImageBlock) {
            final url = normalizeNovelImageUrl(b.url);
            if (!url.startsWith('http')) continue;
            var rel = imageCache[url];
            if (rel == null) {
              final ext = _guessImageExt(url);
              rel = 'images/img$imgIndex.$ext';
              imageCache[url] = rel;
              pendingImages.add((url: url, rel: rel));
              imgIndex++;
            }
            body.writeln('    <p><img src="$rel" alt="illustration"/></p>');
          }
        }
        if (body.isEmpty) {
          body.writeln('    <p>（本章无内容）</p>');
        }
        var key = title;
        var n = 2;
        while (chaptersHtml.containsKey(key)) {
          key = '$title ($n)';
          n++;
        }
        chaptersHtml[key] = body.toString();
      }

      if (canceled) {
        loading.close();
        return;
      }
      loading.setMessage("Building EPUB…".tl);
      loading.setProgress(0.95);

      final embedded = <String, List<int>>{};
      for (final item in pendingImages) {
        if (canceled) {
          loading.close();
          return;
        }
        try {
          await for (final p in ImageDownloader.loadComicImage(
            item.url,
            comic.sourceKey,
            comic.id,
            '',
          )) {
            if (p.imageBytes != null) {
              embedded[item.rel] = p.imageBytes!;
              break;
            }
          }
        } catch (_) {}
      }

      final outName =
          '${sanitizeFileName(comic.title, maxLength: 80)}.epub';
      final outPath = FilePath.join(App.cachePath, outName);

      await createNovelEpubWithImages(
        NovelEpubData(
          title: comic.title,
          author: comic.findAuthor() ?? comic.subTitle ?? '',
          chapters: chaptersHtml,
          coverBytes: coverBytes,
          coverExt: coverExt,
        ),
        embedded,
        App.cachePath,
        outPath,
      );

      loading.close();
      await saveFile(file: File(outPath), filename: outName);
      try {
        File(outPath).deleteSync();
      } catch (_) {}
      App.rootContext.showMessage(message: "Saved".tl);
    } catch (e, s) {
      Log.error('NovelEpub', '$e\n$s');
      loading.close();
      App.rootContext.showMessage(message: e.toString());
    }
  }

  String _xmlEsc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String _guessImageExt(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    for (final e in ['.jpg', '.jpeg', '.png', '.webp', '.gif']) {
      if (path.contains(e)) return e.substring(1);
    }
    return 'jpg';
  }

  void onTapTag(String tag, String namespace) {
    var target = comicSource.handleClickTagEvent?.call(namespace, tag);
    var context = App.mainNavigatorKey!.currentContext!;
    target?.jump(context);
  }

  void showMoreActions() {
    var context = App.rootContext;
    showMenuX(
        context,
        Offset(
          context.width - 16,
          context.padding.top,
        ),
        [
          MenuEntry(
            icon: Icons.copy,
            text: "Copy Title".tl,
            onClick: () {
              Clipboard.setData(ClipboardData(text: comic.title));
              context.showMessage(message: "Copied".tl);
            },
          ),
          MenuEntry(
            icon: Icons.copy_rounded,
            text: "Copy ID".tl,
            onClick: () {
              Clipboard.setData(ClipboardData(text: comic.id));
              context.showMessage(message: "Copied".tl);
            },
          ),
          ...() {
            final url = (comic.url != null && comic.url!.isNotEmpty)
                ? comic.url!
                : (isNovelSource(comic.sourceKey)
                    ? novelBookUrl(comic.sourceKey, comic.id)
                    : '');
            if (url.isEmpty) return <MenuEntry>[];
            return [
              MenuEntry(
                icon: Icons.link,
                text: "Copy URL".tl,
                onClick: () {
                  Clipboard.setData(ClipboardData(text: url));
                  context.showMessage(message: "Copied".tl);
                },
              ),
              MenuEntry(
                icon: Icons.open_in_browser,
                text: "Open in Browser".tl,
                onClick: () {
                  launchUrlString(url);
                },
              ),
            ];
          }(),
        ]);
  }

  void showComments() {
    showSideBar(
      App.rootContext,
      CommentsPage(
        data: comic,
        source: comicSource,
      ),
    );
  }

  void starRating() {
    if (!comicSource.isLogged) {
      return;
    }
    var rating = 0.0;
    var isLoading = false;
    showDialog(
      context: App.rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => SimpleDialog(
          title: const Text("Rating"),
          alignment: Alignment.center,
          children: [
            SizedBox(
              height: 100,
              child: Center(
                child: SizedBox(
                  width: 210,
                  child: Column(
                    children: [
                      const SizedBox(
                        height: 10,
                      ),
                      RatingWidget(
                        padding: 2,
                        onRatingUpdate: (value) => rating = value,
                        value: 1,
                        selectable: true,
                        size: 40,
                      ),
                      const Spacer(),
                      Button.filled(
                        isLoading: isLoading,
                        onPressed: () {
                          setState(() {
                            isLoading = true;
                          });
                          comicSource.starRatingFunc!(comic.id, rating.round())
                              .then((value) {
                            if (value.success) {
                              App.rootContext
                                  .showMessage(message: "Success".tl);
                              Navigator.of(dialogContext).pop();
                            } else {
                              App.rootContext
                                  .showMessage(message: value.errorMessage!);
                              setState(() {
                                isLoading = false;
                              });
                            }
                          });
                        },
                        child: Text("Submit".tl),
                      )
                    ],
                  ),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}
