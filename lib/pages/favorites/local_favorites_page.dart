part of 'favorites_page.dart';

const _localAllFolderLabel = '^_^[%local_all%]^_^';

/// If the number of comics in a folder exceeds this limit, it will be
/// fetched asynchronously.
const _asyncDataFetchLimit = 500;

class _LocalFavoritesPage extends StatefulWidget {
  const _LocalFavoritesPage({required this.folder, super.key});

  final String folder;

  @override
  State<_LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<_LocalFavoritesPage> {
  late _FavoritesPageState favPage;

  late List<FavoriteItem> books;

  String? networkSource;
  String? networkFolder;

  Map<Book, bool> selectedBooks = {};

  var selectedLocalFolders = <String>{};

  late List<String> added = [];

  String keyword = "";
  bool searchHasUpper = false;

  bool searchMode = false;

  bool multiSelectMode = false;

  int? lastSelectedIndex;

  bool get isAllFolder => widget.folder == _localAllFolderLabel;

  LocalFavoritesManager get manager => LocalFavoritesManager();

  bool isLoading = false;

  late String readFilterSelect;

  var searchResults = <FavoriteItem>[];

  void updateSearchResult() {
    setState(() {
      if (keyword.trim().isEmpty) {
        searchResults = books;
      } else {
        searchResults = [];
        for (var comic in books) {
          if (matchKeyword(keyword, comic) ||
              matchKeywordT(keyword, comic) ||
              matchKeywordS(keyword, comic)) {
            searchResults.add(comic);
          }
        }
      }
    });
  }

  void updateBooks() {
    if (isLoading) return;
    if (isAllFolder) {
      var totalBooks = manager.totalBooks;
      if (totalBooks < _asyncDataFetchLimit) {
        books = manager.getAllBooks();
      } else {
        isLoading = true;
        manager
            .getAllBooksAsync()
            .minTime(const Duration(milliseconds: 200))
            .then((value) {
          if (mounted) {
            setState(() {
              isLoading = false;
              books = value;
            });
          }
        });
      }
    } else {
      var folderBooks = manager.folderBooks(widget.folder);
      if (folderBooks < _asyncDataFetchLimit) {
        books = manager.getFolderBooks(widget.folder);
      } else {
        isLoading = true;
        manager
            .getFolderBooksAsync(widget.folder)
            .minTime(const Duration(milliseconds: 200))
            .then((value) {
          if (mounted) {
            setState(() {
              isLoading = false;
              books = value;
            });
          }
        });
      }
    }
    setState(() {});
  }

  List<FavoriteItem> filterBooks(List<FavoriteItem> curComics) {
    return curComics.where((comic) {
      var history =
          HistoryManager().find(comic.id, BookType(comic.sourceKey.hashCode));
      if (readFilterSelect == "UnCompleted") {
        return history == null || history.page != history.maxPage;
      } else if (readFilterSelect == "Completed") {
        return history != null && history.page == history.maxPage;
      }
      return true;
    }).toList();
  }

  bool matchKeyword(String keyword, FavoriteItem comic) {
    var list = keyword.split(" ");
    for (var k in list) {
      if (k.isEmpty) continue;
      if (checkKeyWordMatch(k, comic.title, false)) {
        continue;
      } else if (comic.subtitle != null && checkKeyWordMatch(k, comic.subtitle!, false)) {
        continue;
      } else if (comic.tags.any((tag) {
        if (checkKeyWordMatch(k, tag, true)) {
          return true;
        } else if (tag.contains(':') && checkKeyWordMatch(k, tag.split(':')[1], true)) {
          return true;
        } else if (App.locale.languageCode != 'en' &&
            checkKeyWordMatch(k, tag.translateTagsToCN, true)) {
          return true;
        }
        return false;
      })) {
        continue;
      } else if (checkKeyWordMatch(k, comic.author, true)) {
        continue;
      }
      return false;
    }
    return true;
  }

  bool checkKeyWordMatch(String keyword, String compare, bool needEqual) {
    String temp = compare;
    // 没有大写的话, 就转成小写比较, 避免搜索需要注意大小写
    if (!searchHasUpper) {
      temp = temp.toLowerCase();
    }
    if (needEqual) {
      return  keyword == temp;
    }
    return temp.contains(keyword);
  }
  // Convert keyword to traditional Chinese to match comics
  bool matchKeywordT(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseSimplified(keyword)) {
      return false;
    }
    keyword = OpenCC.simplifiedToTraditional(keyword);
    return matchKeyword(keyword, comic);
  }

  // Convert keyword to simplified Chinese to match comics
  bool matchKeywordS(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseTraditional(keyword)) {
      return false;
    }
    keyword = OpenCC.traditionalToSimplified(keyword);
    return matchKeyword(keyword, comic);
  }
  @override
  void initState() {
    readFilterSelect = appdata.implicitData["local_favorites_read_filter"] ??
        readFilterList[0];
    favPage = context.findAncestorStateOfType<_FavoritesPageState>()!;
    if (!isAllFolder) {
      var (a, b) = LocalFavoritesManager().findLinked(widget.folder);
      networkSource = a;
      networkFolder = b;
    } else {
      networkSource = null;
      networkFolder = null;
    }
    books = [];
    updateBooks();
    LocalFavoritesManager().addListener(updateBooks);
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    LocalFavoritesManager().removeListener(updateBooks);
  }

  void selectAll() {
    setState(() {
      if (searchMode) {
        selectedBooks = searchResults.asMap().map((k, v) => MapEntry(v, true));
      } else {
        selectedBooks = books.asMap().map((k, v) => MapEntry(v, true));
      }
    });
  }

  void invertSelection() {
    setState(() {
      if (searchMode) {
        for (var c in searchResults) {
          if (selectedBooks.containsKey(c)) {
            selectedBooks.remove(c);
          } else {
            selectedBooks[c] = true;
          }
        }
      } else {
        for (var c in books) {
          if (selectedBooks.containsKey(c)) {
            selectedBooks.remove(c);
          } else {
            selectedBooks[c] = true;
          }
        }
      }
    });
  }

  bool downloadBook(FavoriteItem c) {
    var source = c.type.bookSource;
    if (source != null) {
      bool isDownloaded = LocalManager().isDownloaded(
        c.id,
        (c).type,
      );
      if (isDownloaded) {
        return false;
      }
      LocalManager().addTask(ImagesDownloadTask(
        source: source,
        bookId: c.id,
        bookTitle: c.title,
      ));
      return true;
    }
    return false;
  }

  void downloadSelected() {
    int count = 0;
    for (var c in selectedBooks.keys) {
      if (downloadBook(c as FavoriteItem)) {
        count++;
      }
    }
    if (count > 0) {
      context.showMessage(
        message: "Added @c books to download queue.".tlParams({"c": count}),
      );
    }
  }

  var scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    var title = favPage.folder ?? "Unselected".tl;
    if (title == _localAllFolderLabel) {
      title = "All".tl;
    }

    Widget body = SmoothCustomScrollView(
      controller: scrollController,
      slivers: [
        if (!searchMode && !multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Folders".tl,
              child: context.width <= _kTwoPanelChangeWidth
                  ? IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: favPage.showFolderSelector,
                    )
                  : const SizedBox(),
            ),
            title: GestureDetector(
              onTap: context.width < _kTwoPanelChangeWidth
                  ? favPage.showFolderSelector
                  : null,
              child: Text(title),
            ),
            actions: [
              if (networkSource != null && !isAllFolder)
                Tooltip(
                  message: "Sync".tl,
                  child: Flyout(
                    flyoutBuilder: (context) {
                      final GlobalKey<_SelectUpdatePageNumState>
                          selectUpdatePageNumKey =
                          GlobalKey<_SelectUpdatePageNumState>();
                      var updatePageWidget = _SelectUpdatePageNum(
                        networkSource: networkSource!,
                        networkFolder: networkFolder,
                        key: selectUpdatePageNumKey,
                      );
                      return FlyoutContent(
                        title: "Sync".tl,
                        content: updatePageWidget,
                        actions: [
                          Button.filled(
                            child: Text("Update".tl),
                            onPressed: () {
                              context.pop();
                              importNetworkFolder(
                                networkSource!,
                                selectUpdatePageNumKey
                                    .currentState!.updatePageNum,
                                widget.folder,
                                networkFolder!,
                              ).then(
                                (value) {
                                  updateBooks();
                                },
                              );
                            },
                          ),
                        ],
                      );
                    },
                    child: Builder(builder: (context) {
                      return IconButton(
                        icon: const Icon(Icons.sync),
                        onPressed: () {
                          Flyout.of(context).show();
                        },
                      );
                    }),
                  ),
                ),
              Tooltip(
                message: "Filter".tl,
                child: IconButton(
                  icon: const Icon(Icons.sort_rounded),
                  color: readFilterSelect != readFilterList[0]
                      ? context.colorScheme.primaryContainer
                      : null,
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        return _LocalFavoritesFilterDialog(
                          initReadFilterSelect: readFilterSelect,
                          updateConfig: (readFilter) {
                            setState(() {
                              readFilterSelect = readFilter;
                            });
                            updateBooks();
                          },
                        );
                      },
                    );
                  },
                ),
              ),
              Tooltip(
                message: "Search".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      keyword = "";
                      searchMode = true;
                      updateSearchResult();
                    });
                  },
                ),
              ),
              if (!isAllFolder)
                MenuButton(
                  entries: [
                    MenuEntry(
                      icon: Icons.edit_outlined,
                      text: "Rename".tl,
                      onClick: () {
                        showInputDialog(
                          context: App.rootContext,
                          title: "Rename".tl,
                          hintText: "New Name".tl,
                          onConfirm: (value) {
                            var err = validateFolderName(value.toString());
                            if (err != null) {
                              return err;
                            }
                            LocalFavoritesManager().rename(
                              widget.folder,
                              value.toString(),
                            );
                            favPage.folderList?.updateFolders();
                            favPage.setFolder(false, value.toString());
                            return null;
                          },
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.reorder,
                      text: "Reorder".tl,
                      onClick: () {
                        context.to(
                          () {
                            return _ReorderBooksPage(
                              widget.folder,
                              (comics) {
                                this.books = comics;
                              },
                            );
                          },
                        ).then(
                          (value) {
                            if (mounted) {
                              setState(() {});
                            }
                          },
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.upload_file,
                      text: "Export".tl,
                      onClick: () {
                        var json = LocalFavoritesManager().folderToJson(
                          widget.folder,
                        );
                        saveFile(
                          data: utf8.encode(json),
                          filename: "${widget.folder}.json",
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.update,
                      text: "Update Books Info".tl,
                      onClick: () {
                        updateBooksInfo(widget.folder).then((newBooks) {
                          if (mounted) {
                            setState(() {
                              books = newBooks;
                            });
                          }
                        });
                      },
                    ),
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Folder".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        showConfirmDialog(
                          context: App.rootContext,
                          title: "Delete".tl,
                          content: "Delete folder '@f' ?".tlParams({
                            "f": widget.folder,
                          }),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            favPage.setFolder(false, null);
                            LocalFavoritesManager().deleteFolder(widget.folder);
                            favPage.folderList?.updateFolders();
                          },
                        );
                      },
                    ),
                  ],
                ),
            ],
          )
        else if (multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    multiSelectMode = false;
                    selectedBooks.clear();
                  });
                },
              ),
            ),
            title: Text(
                "Selected @c books".tlParams({"c": selectedBooks.length})),
            actions: [
              MenuButton(entries: [
                if (!isAllFolder)
                  MenuEntry(
                      icon: Icons.drive_file_move,
                      text: "Move to folder".tl,
                      onClick: () => favoriteOption('move')),
                if (!isAllFolder)
                  MenuEntry(
                      icon: Icons.copy,
                      text: "Copy to folder".tl,
                      onClick: () => favoriteOption('add')),
                MenuEntry(
                    icon: Icons.select_all,
                    text: "Select All".tl,
                    onClick: selectAll),
                MenuEntry(
                    icon: Icons.deselect,
                    text: "Deselect".tl,
                    onClick: _cancel),
                MenuEntry(
                    icon: Icons.flip,
                    text: "Invert Selection".tl,
                    onClick: invertSelection),
                if (!isAllFolder)
                  MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Book".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        showConfirmDialog(
                          context: context,
                          title: "Delete".tl,
                          content: "Delete @c books?"
                              .tlParams({"c": selectedBooks.length}),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            _deleteBookWithId();
                          },
                        );
                      }),
                MenuEntry(
                  icon: Icons.download,
                  text: "Download".tl,
                  onClick: downloadSelected,
                ),
                if (selectedBooks.length == 1)
                  MenuEntry(
                    icon: Icons.copy,
                    text: "Copy Title".tl,
                    onClick: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: selectedBooks.keys.first.title,
                        ),
                      );
                      context.showMessage(
                        message: "Copied".tl,
                      );
                    },
                  ),
                if (selectedBooks.length == 1)
                  MenuEntry(
                    icon: Icons.chrome_reader_mode_outlined,
                    text: "Read".tl,
                    onClick: () {
                      final c = selectedBooks.keys.first as FavoriteItem;
                      App.rootContext.to(() => ReaderWithLoading(
                            id: c.id,
                            sourceKey: c.sourceKey,
                          )
                      );
                    },
                  ),
                if (selectedBooks.length == 1)
                  MenuEntry(
                    icon: Icons.arrow_forward_ios,
                    text: "Jump to Detail".tl,
                    onClick: () {
                      final c = selectedBooks.keys.first as FavoriteItem;
                      App.mainNavigatorKey?.currentContext?.to(() => BookPage(
                            id: c.id,
                            sourceKey: c.sourceKey,
                          )
                      );
                    },
                  ),
              ]),
            ],
          )
        else if (searchMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    setState(() {
                      searchMode = false;
                    });
                  });
                },
              ),
            ),
            title: TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: "Search".tl,
                border: UnderlineInputBorder(),
              ),
              onChanged: (v) {
                keyword = v;
                searchHasUpper = keyword.contains(RegExp(r'[A-Z]'));
                updateSearchResult();
              },
            ).paddingBottom(8).paddingRight(8),
          ),
        if (isLoading)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          )
        else
          SliverGridBooks(
            books: searchMode ? searchResults : filterBooks(books),
            selections: selectedBooks,
            menuBuilder: (c) {
              return [
                if (!isAllFolder)
                  MenuEntry(
                    icon: Icons.delete,
                    text: "Delete".tl,
                    onClick: () {
                      LocalFavoritesManager().deleteBookWithId(
                        widget.folder,
                        c.id,
                        (c as FavoriteItem).type,
                      );
                    },
                  ),
                MenuEntry(
                  icon: Icons.check,
                  text: "Select".tl,
                  onClick: () {
                    setState(() {
                      if (!multiSelectMode) {
                        multiSelectMode = true;
                      }
                      if (selectedBooks.containsKey(c as FavoriteItem)) {
                        selectedBooks.remove(c);
                        _checkExitSelectMode();
                      } else {
                        selectedBooks[c] = true;
                      }
                      lastSelectedIndex = books.indexOf(c);
                    });
                  },
                ),
                MenuEntry(
                  icon: Icons.download,
                  text: "Download".tl,
                  onClick: () {
                    downloadBook(c as FavoriteItem);
                    context.showMessage(
                      message: "Download started".tl,
                    );
                  },
                ),
                if (appdata.settings["onClickFavorite"] == "viewDetail")
                  MenuEntry(
                    icon: Icons.menu_book_outlined,
                    text: "Read".tl,
                    onClick: () {
                      App.mainNavigatorKey?.currentContext?.to(
                        () => ReaderWithLoading(
                          id: c.id,
                          sourceKey: c.sourceKey,
                        )
                      );
                    },
                  ),
              ];
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedBooks.containsKey(c as FavoriteItem)) {
                    selectedBooks.remove(c);
                    _checkExitSelectMode();
                  } else {
                    selectedBooks[c] = true;
                  }
                  lastSelectedIndex = books.indexOf(c);
                });
              } else if (appdata.settings["onClickFavorite"] == "viewDetail") {
                App.mainNavigatorKey?.currentContext?.to(
                  () => BookPage(
                    id: c.id,
                    sourceKey: c.sourceKey,
                    cover: c.cover,
                    title: c.title,
                    heroID: heroID,
                  )
                );
              } else {
                App.mainNavigatorKey?.currentContext?.to(
                  () => ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
                );
              }
            },
            onLongPressed: (c, heroID) {
              setState(() {
                if (!multiSelectMode) {
                  multiSelectMode = true;
                  if (!selectedBooks.containsKey(c as FavoriteItem)) {
                    selectedBooks[c] = true;
                  }
                  lastSelectedIndex = books.indexOf(c);
                } else {
                  if (lastSelectedIndex != null) {
                    int start = lastSelectedIndex!;
                    int end = books.indexOf(c as FavoriteItem);
                    if (start > end) {
                      int temp = start;
                      start = end;
                      end = temp;
                    }

                    for (int i = start; i <= end; i++) {
                      if (i == lastSelectedIndex) continue;

                      var comic = books[i];
                      if (selectedBooks.containsKey(comic)) {
                        selectedBooks.remove(comic);
                      } else {
                        selectedBooks[comic] = true;
                      }
                    }
                  }
                  lastSelectedIndex = books.indexOf(c as FavoriteItem);
                }
                _checkExitSelectMode();
              });
            },
          ),
      ],
    );
    body = AppScrollBar(
      topPadding: 48,
      controller: scrollController,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: body,
      ),
    );
    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedBooks.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            updateBooks();
          });
        }
      },
      child: body,
    );
  }

  void favoriteOption(String option) {
    var targetFolders = LocalFavoritesManager()
        .folderNames
        .where((folder) => folder != favPage.folder)
        .toList();

    showPopUpWidget(
      App.rootContext,
      StatefulBuilder(
        builder: (context, setState) {
          return PopUpWidgetScaffold(
            title: favPage.folder ?? "Unselected".tl,
            body: Padding(
              padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
              child: Container(
                constraints:
                    const BoxConstraints(maxHeight: 700, maxWidth: 500),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: targetFolders.length + 1,
                        itemBuilder: (context, index) {
                          if (index == targetFolders.length) {
                            return SizedBox(
                              height: 36,
                              child: Center(
                                child: TextButton(
                                  onPressed: () {
                                    newFolder().then((v) {
                                      setState(() {
                                        targetFolders = LocalFavoritesManager()
                                            .folderNames
                                            .where((folder) =>
                                                folder != favPage.folder)
                                            .toList();
                                      });
                                    });
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.add, size: 20),
                                      const SizedBox(width: 4),
                                      Text("New Folder".tl),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                          var folder = targetFolders[index];
                          var disabled = false;
                          if (selectedLocalFolders.isNotEmpty) {
                            if (added.contains(folder) &&
                                !added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            } else if (!added.contains(folder) &&
                                added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            }
                          }
                          return CheckboxListTile(
                            title: Row(
                              children: [
                                Text(folder),
                                const SizedBox(width: 8),
                              ],
                            ),
                            value: selectedLocalFolders.contains(folder),
                            onChanged: disabled
                                ? null
                                : (v) {
                                    setState(() {
                                      if (v!) {
                                        selectedLocalFolders.add(folder);
                                      } else {
                                        selectedLocalFolders.remove(folder);
                                      }
                                    });
                                  },
                          );
                        },
                      ),
                    ),
                    Center(
                      child: FilledButton(
                        onPressed: () {
                          if (selectedLocalFolders.isEmpty) {
                            return;
                          }
                          if (option == 'move') {
                            var books = selectedBooks.keys
                                .map((e) => e as FavoriteItem)
                                .toList();
                            for (var f in selectedLocalFolders) {
                              LocalFavoritesManager().batchMoveFavorites(
                                favPage.folder as String,
                                f,
                                books,
                              );
                            }
                          } else {
                            var books = selectedBooks.keys
                                .map((e) => e as FavoriteItem)
                                .toList();
                            for (var f in selectedLocalFolders) {
                              LocalFavoritesManager().batchCopyFavorites(
                                favPage.folder as String,
                                f,
                                books,
                              );
                            }
                          }
                          App.rootContext.pop();
                          updateBooks();
                          _cancel();
                        },
                        child: Text(option == 'move' ? "Move".tl : "Add".tl),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _checkExitSelectMode() {
    if (selectedBooks.isEmpty) {
      setState(() {
        multiSelectMode = false;
      });
    }
  }

  void _cancel() {
    setState(() {
      selectedBooks.clear();
      multiSelectMode = false;
    });
  }

  void _deleteBookWithId() {
    var toBeDeleted = selectedBooks.keys.map((e) => e as FavoriteItem).toList();
    LocalFavoritesManager().batchDeleteBooks(widget.folder, toBeDeleted);
    _cancel();
  }
}

class _ReorderBooksPage extends StatefulWidget {
  const _ReorderBooksPage(this.name, this.onReorder);

  final String name;

  final void Function(List<FavoriteItem>) onReorder;

  @override
  State<_ReorderBooksPage> createState() => _ReorderBooksPageState();
}

class _ReorderBooksPageState extends State<_ReorderBooksPage> {
  final _key = GlobalKey();
  var reorderWidgetKey = UniqueKey();
  final _scrollController = ScrollController();
  late var books = LocalFavoritesManager().getFolderBooks(widget.name);
  bool changed = false;

  static int _floatToInt8(double x) {
    return (x * 255.0).round() & 0xff;
  }

  Color lightenColor(Color color, double lightenValue) {
    int red =
        (_floatToInt8(color.r) + ((255 - color.r) * lightenValue)).round();
    int green = (_floatToInt8(color.g) * 255 + ((255 - color.g) * lightenValue))
        .round();
    int blue = (_floatToInt8(color.b) * 255 + ((255 - color.b) * lightenValue))
        .round();

    return Color.fromARGB(_floatToInt8(color.a), red, green, blue);
  }

  @override
  void dispose() {
    if (changed) {
      // Delay to ensure navigation is completed
      Future.delayed(const Duration(milliseconds: 200), () {
        LocalFavoritesManager().reorder(books, widget.name);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['bookDisplayMode'];
    var tiles = books.map(
      (e) {
        var bookSource = e.type.bookSource;
        return BookTile(
          key: Key(e.hashCode.toString()),
          enableLongPressed: false,
          comic: Book(
            e.name,
            e.coverPath,
            e.id,
            e.author,
            e.tags,
            type == 'detailed'
                ? "${e.time} | ${bookSource?.name ?? "Unknown"}"
                : "${e.type.bookSource?.name ?? "Unknown"} | ${e.time}",
            bookSource?.key ??
                (e.type == BookType.local ? "local" : "Unknown"),
            null,
            null,
          ),
        );
      },
    ).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Reorder".tl),
        actions: [
          Tooltip(
            message: "Information".tl,
            child: IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                showInfoDialog(
                  context: context,
                  title: "Reorder".tl,
                  content: "Long press and drag to reorder.".tl,
                );
              },
            ),
          ),
          Tooltip(
            message: "Reverse".tl,
            child: IconButton(
              icon: const Icon(Icons.swap_vert),
              onPressed: () {
                setState(() {
                  books = books.reversed.toList();
                  changed = true;
                });
              },
            ),
          )
        ],
      ),
      body: ReorderableBuilder<FavoriteItem>(
        key: reorderWidgetKey,
        scrollController: _scrollController,
        longPressDelay: App.isDesktop
            ? const Duration(milliseconds: 100)
            : const Duration(milliseconds: 500),
        onReorder: (reorderFunc) {
          changed = true;
          setState(() {
            books = reorderFunc(books);
          });
          widget.onReorder(books);
        },
        dragChildBoxDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: lightenColor(
            Theme.of(context).splashColor.withAlpha(255),
            0.2,
          ),
        ),
        builder: (children) {
          return GridView(
            key: _key,
            controller: _scrollController,
            gridDelegate: SliverGridDelegateWithBooks(),
            children: children,
          );
        },
        children: tiles,
      ),
    );
  }
}

class _SelectUpdatePageNum extends StatefulWidget {
  const _SelectUpdatePageNum({
    required this.networkSource,
    this.networkFolder,
    super.key,
  });

  final String? networkFolder;
  final String networkSource;

  @override
  State<_SelectUpdatePageNum> createState() => _SelectUpdatePageNumState();
}

class _SelectUpdatePageNumState extends State<_SelectUpdatePageNum> {
  int updatePageNum = 9999999;

  String get _allPageText => 'All'.tl;

  List<String> get pageNumList =>
      ['1', '2', '3', '5', '10', '20', '50', '100', '200', _allPageText];

  @override
  void initState() {
    updatePageNum =
        appdata.implicitData["local_favorites_update_page_num"] ?? 9999999;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var source = BookSource.find(widget.networkSource);
    var sourceName = source?.name ?? widget.networkSource;
    var text = "The folder is Linked to @source".tlParams({
      "source": sourceName,
    });
    if (widget.networkFolder != null && widget.networkFolder!.isNotEmpty) {
      text += "\n${"Source Folder".tl}: ${widget.networkFolder}";
    }

    return Column(
      children: [
        Row(
          children: [Text(text)],
        ),
        Row(
          children: [
            Text("Update the page number by the latest collection".tl),
            Spacer(),
            Select(
              current: updatePageNum.toString() == '9999999'
                  ? _allPageText
                  : updatePageNum.toString(),
              values: pageNumList,
              minWidth: 48,
              onTap: (index) {
                setState(() {
                  updatePageNum = int.parse(pageNumList[index] == _allPageText
                      ? '9999999'
                      : pageNumList[index]);
                  appdata.implicitData["local_favorites_update_page_num"] =
                      updatePageNum;
                  appdata.writeImplicitData();
                });
              },
            )
          ],
        ),
      ],
    );
  }
}

class _LocalFavoritesFilterDialog extends StatefulWidget {
  const _LocalFavoritesFilterDialog({
    required this.initReadFilterSelect,
    required this.updateConfig,
  });

  final String initReadFilterSelect;
  final Function updateConfig;

  @override
  State<_LocalFavoritesFilterDialog> createState() =>
      _LocalFavoritesFilterDialogState();
}

const readFilterList = ['All', 'UnCompleted', 'Completed'];

class _LocalFavoritesFilterDialogState
    extends State<_LocalFavoritesFilterDialog> {
  List<String> optionTypes = ['Filter'];
  late var readFilter = widget.initReadFilterSelect;
  @override
  Widget build(BuildContext context) {
    Widget tabBar = Material(
      borderRadius: BorderRadius.circular(8),
      child: AppTabBar(
        key: PageStorageKey(optionTypes),
        tabs: optionTypes.map((e) => Tab(text: e.tl, key: Key(e))).toList(),
      ),
    ).paddingTop(context.padding.top);
    return ContentDialog(
      content: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tabBar,
            TabViewBody(children: [
              Column(
                children: [
                  ListTile(
                    title: Text("Filter reading status".tl),
                    trailing: Select(
                      current: readFilter.tl,
                      values: readFilterList.map((e) => e.tl).toList(),
                      minWidth: 64,
                      onTap: (index) {
                        setState(() {
                          readFilter = readFilterList[index];
                        });
                      },
                    ),
                  )
                ],
              )
            ]),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            appdata.implicitData["local_favorites_read_filter"] = readFilter;
            appdata.writeImplicitData();
            if (mounted) {
              Navigator.pop(context);
              widget.updateConfig(readFilter);
            }
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
