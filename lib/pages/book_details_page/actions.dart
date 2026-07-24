part of 'book_page.dart';

abstract mixin class _BookPageActions {
  void update();

  BookDetails get book;

  BookSource get bookSource => BookSource.find(book.sourceKey)!;

  History? get history;

  bool isLiking = false;

  bool isLiked = false;

  void likeOrUnlike() async {
    if (isLiking) return;
    isLiking = true;
    update();
    var res = await bookSource.likeOrUnlikeBook!(book.id, isLiked);
    if (res.error) {
      App.rootContext.showMessage(message: res.errorMessage!);
    } else {
      isLiked = !isLiked;
    }
    isLiking = false;
    update();
  }

  /// whether the book is added to local favorite
  bool isAddToLocalFav = false;

  /// whether the book is favorite on the server
  bool isFavorite = false;

  FavoriteItem _toFavoriteItem() {
    var tags = <String>[];
    for (var e in book.tags.entries) {
      tags.addAll(e.value.map((tag) => '${e.key}:$tag'));
    }
    return FavoriteItem(
      id: book.id,
      name: book.title,
      coverPath: book.cover,
      author: book.subTitle ?? book.uploader ?? '',
      type: book.bookType,
      tags: tags,
    );
  }

  void openFavPanel() {
    showSideBar(
      App.rootContext,
      _FavoritePanel(
        cid: book.id,
        type: book.bookType,
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
        updateTime: book.findUpdateTime(),
      ),
    );
  }

  void quickFavorite() {
    var folder = appdata.settings['quickFavorite'];
    if (folder is! String) {
      return;
    }
    LocalFavoritesManager().addBook(
      folder,
      _toFavoriteItem(),
      null,
      book.findUpdateTime(),
    );
    isAddToLocalFav = true;
    update();
    App.rootContext.showMessage(message: "Added".tl);
  }

  void share() {
    var text = book.title;
    final url = (book.url != null && book.url!.isNotEmpty)
        ? book.url!
        : (isNovelSource(book.sourceKey)
            ? novelBookUrl(book.sourceKey, book.id)
            : '');
    if (url.isNotEmpty) {
      text += '\n$url';
    }
    Share.shareText(text);
  }

  /// read the book
  ///
  /// [ep] the episode number, start from 1
  ///
  /// [page] the page number, start from 1
  ///
  /// [group] the chapter group number, start from 1
  void read([int? ep, int? page, int? group]) {
    final hist = history ?? History.fromModel(model: book, ep: 0, page: 0);
    final pageWidget = Reader(
      type: book.bookType,
      cid: book.id,
      name: book.title,
      chapters: book.chapters,
      initialChapter: ep,
      initialPage: page,
      initialChapterGroup: group,
      history: hist,
      author: book.findAuthor() ?? '',
      tags: book.plainTags,
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
    if (isNovelSource(book.sourceKey)) {
      await _downloadNovelOffline();
      return;
    }
    if (LocalManager().isDownloading(book.id, book.bookType)) {
      App.rootContext.showMessage(message: "The book is downloading".tl);
      return;
    }
    if (book.chapters == null &&
        LocalManager().isDownloaded(book.id, book.bookType, 0)) {
      App.rootContext.showMessage(message: "The book is downloaded".tl);
      return;
    }

    if (bookSource.archiveDownloader != null) {
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
                            bookSource.archiveDownloader!
                                .getArchives(book.id)
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
                          await bookSource.archiveDownloader!.getDownloadUrl(
                        book.id,
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
                            .addTask(ArchiveDownloadTask(res.data, book));
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

    if (book.chapters == null) {
      LocalManager().addTask(ImagesDownloadTask(
        source: bookSource,
        bookId: book.id,
        book: book,
      ));
    } else {
      List<int>? selected;
      var downloaded = <int>[];
      var localBook = LocalManager().find(book.id, book.bookType);
      if (localBook != null) {
        for (int i = 0; i < book.chapters!.length; i++) {
          if (localBook.downloadedChapters
              .contains(book.chapters!.ids.elementAt(i))) {
            downloaded.add(i);
          }
        }
      }
      await showSideBar(
        App.rootContext,
        _SelectDownloadChapter(
          book.chapters!.titles.toList(),
          (v) => selected = v,
          downloaded,
        ),
      );
      if (selected == null) return;
      LocalManager().addTask(ImagesDownloadTask(
        source: bookSource,
        bookId: book.id,
        book: book,
        chapters: selected!.map((i) {
          return book.chapters!.ids.elementAt(i);
        }).toList(),
      ));
    }
    App.rootContext.showMessage(message: "Download started".tl);
    update();
  }

  /// Offline novel → LocalManager with user-chosen folder.
  Future<void> _downloadNovelOffline() async {
    if (LocalManager().isDownloading(book.id, book.bookType)) {
      App.rootContext.showMessage(message: "The book is downloading".tl);
      return;
    }
    if (book.chapters == null || book.chapters!.length == 0) {
      App.rootContext.showMessage(message: "No chapters".tl);
      return;
    }

    final volumes = _novelDownloadVolumes(book.chapters!);
    List<_NovelChapterPick>? selected;
    await showSideBar(
      App.rootContext,
      _SelectNovelEpubDownload(
        volumes: volumes,
        onConfirm: (v) => selected = v,
      ),
    );
    if (selected == null || selected!.isEmpty) return;

    final picker = DirectoryPicker();
    final rootDir = await picker.pickDirectory();
    if (rootDir == null) return;

    LocalManager().addTask(NovelDownloadTask(
      source: bookSource,
      bookId: book.id,
      book: book,
      chapters: selected!.map((e) => e.id).toList(),
      saveRoot: saveRoot,
      bookTitle: book.title,
    ));
    App.rootContext.showMessage(message: "Download started".tl);
    update();
  }

  List<_NovelDownloadVolume> _novelDownloadVolumes(BookChapters chapters) {
    if (chapters.isGrouped) {
      return [
        for (final g in chapters.groups)
          _NovelDownloadVolume(
            name: g,
            chapters: [
              for (final e in chapters.getGroup(g).entries)
                _NovelChapterPick(volume: g, id: e.key, title: e.value),
            ],
          ),
      ];
    }
    const vol = '全一卷';
    return [
      _NovelDownloadVolume(
        name: vol,
        chapters: [
          for (var i = 0; i < chapters.length; i++)
            _NovelChapterPick(
              volume: vol,
              id: chapters.ids.elementAt(i),
              title: chapters.titles.elementAt(i),
            ),
        ],
      ),
    ];
  }

  void onTapTag(String tag, String namespace) {
    var target = bookSource.handleClickTagEvent?.call(namespace, tag);
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
              Clipboard.setData(ClipboardData(text: book.title));
              context.showMessage(message: "Copied".tl);
            },
          ),
          MenuEntry(
            icon: Icons.copy_rounded,
            text: "Copy ID".tl,
            onClick: () {
              Clipboard.setData(ClipboardData(text: book.id));
              context.showMessage(message: "Copied".tl);
            },
          ),
          ...() {
            final url = (book.url != null && book.url!.isNotEmpty)
                ? book.url!
                : (isNovelSource(book.sourceKey)
                    ? novelBookUrl(book.sourceKey, book.id)
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
        data: book,
        source: bookSource,
      ),
    );
  }

  void starRating() {
    if (!bookSource.isLogged) {
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
                          bookSource.starRatingFunc!(book.id, rating.round())
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
