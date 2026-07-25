import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:novvera/components/components.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/book_type.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/pages/book_details_page/book_page.dart';
import 'package:novvera/pages/downloading_page.dart';
import 'package:novvera/pages/favorites/favorites_page.dart';
import 'package:novvera/utils/epub.dart';
import 'package:novvera/utils/file_type.dart';
import 'package:novvera/utils/io.dart';
import 'package:novvera/utils/pdf.dart';
import 'package:novvera/utils/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalBooksPage extends StatefulWidget {
  const LocalBooksPage({super.key});

  @override
  State<LocalBooksPage> createState() => _LocalBooksPageState();
}

class _LocalBooksPageState extends State<LocalBooksPage> {
  late List<LocalBook> books;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalBook, bool> selectedBooks = {};

  void update() {
    if (keyword.isEmpty) {
      setState(() {
        books = LocalManager().getBooks(sortType);
      });
    } else {
      setState(() {
        books = LocalManager().search(keyword);
      });
    }
  }

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "name";
    sortType = LocalSortType.fromString(sort);
    books = LocalManager().getBooks(sortType);
    LocalManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    super.dispose();
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "Sort".tl,
            content: RadioGroup<LocalSortType>(
              groupValue: sortType,
              onChanged: (v) {
                setState(() {
                  sortType = v ?? sortType;
                });
              },
              child: Column(
                children: [
                  RadioListTile<LocalSortType>(
                    title: Text("Name".tl),
                    value: LocalSortType.name,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Date".tl),
                    value: LocalSortType.timeAsc,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Date Desc".tl),
                    value: LocalSortType.timeDesc,
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  appdata.implicitData["local_sort"] = sortType.value;
                  appdata.writeImplicitData();
                  Navigator.pop(context);
                  update();
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        });
      },
    );
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(entries: [
      MenuEntry(
        icon: Icons.delete_outline,
        text: "Delete".tl,
        onClick: () {
          deleteBooks(selectedBooks.keys.toList()).then((value) {
            if (value) {
              setState(() {
                multiSelectMode = false;
                selectedBooks.clear();
              });
            }
          });
        },
      ),
      MenuEntry(
        icon: Icons.favorite_border,
        text: "Add to favorites".tl,
        onClick: () {
          addFavorite(selectedBooks.keys.toList());
        },
      ),
      if (selectedBooks.length == 1)
        MenuEntry(
          icon: Icons.folder_open,
          text: "Open Folder".tl,
          onClick: () {
            openBookFolder(selectedBooks.keys.first);
          },
        ),
      if (selectedBooks.length == 1)
        MenuEntry(
          icon: Icons.chrome_reader_mode_outlined,
          text: "View Detail".tl,
          onClick: () {
            context.to(() => BookPage(
                  id: selectedBooks.keys.first.id,
                  sourceKey: selectedBooks.keys.first.sourceKey,
                ));
          },
        ),
      if (selectedBooks.isNotEmpty)
        ...exportActions(selectedBooks.keys.toList()),
    ]);
  }

  void selectAll() {
    setState(() {
      selectedBooks = books.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedBooks.clear();
    });
  }

  void invertSelection() {
    setState(() {
      books.asMap().forEach((k, v) {
        selectedBooks[v] = !selectedBooks.putIfAbsent(v, () => false);
      });
      selectedBooks.removeWhere((k, v) => !v);
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: "Select All".tl,
          onPressed: selectAll),
      IconButton(
          icon: const Icon(Icons.deselect),
          tooltip: "Deselect".tl,
          onPressed: deSelect),
      IconButton(
          icon: const Icon(Icons.flip),
          tooltip: "Invert Selection".tl,
          onPressed: invertSelection),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(
          icon: const Icon(Icons.sort),
          onPressed: sort,
        ),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedBooks.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedBooks.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedBooks.clear();
                      });
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedBooks.length.toString())
                  : TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        border: InputBorder.none,
                      ),
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ),
              actions: multiSelectMode ? selectActions : null,
            ),
          SliverGridBooks(
            books: books.map((b) {
              b.tags = null;
              return b;
            }).toList(),
            selections: selectedBooks,
            onLongPressed: (c, heroID) {
              setState(() {
                multiSelectMode = true;
                selectedBooks[c as LocalBook] = true;
              });
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedBooks.containsKey(c as LocalBook)) {
                    selectedBooks.remove(c);
                  } else {
                    selectedBooks[c] = true;
                  }
                  if (selectedBooks.isEmpty) {
                    multiSelectMode = false;
                  }
                });
              } else {
                // prevent dirty data
                var book =
                    LocalManager().find(c.id, BookType.fromKey(c.sourceKey))!;
                book.read();
              }
            },
            menuBuilder: (c) {
              return [
                MenuEntry(
                  icon: Icons.folder_open,
                  text: "Open Folder".tl,
                  onClick: () {
                    openBookFolder(c as LocalBook);
                  },
                ),
                MenuEntry(
                  icon: Icons.delete,
                  text: "Delete".tl,
                  onClick: () {
                    deleteBooks([c as LocalBook]).then((value) {
                      if (value && multiSelectMode) {
                        setState(() {
                          multiSelectMode = false;
                          selectedBooks.clear();
                        });
                      }
                    });
                  },
                ),
                ...exportActions([c as LocalBook]),
              ];
            },
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedBooks.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  Future<bool> deleteBooks(List<LocalBook> books) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeBookFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(builder: (context, state) {
          return ContentDialog(
            title: "Delete".tl,
            content: Column(
              children: [
                CheckboxListTile(
                  title: Text("Remove local favorite and history".tl),
                  value: removeFavoriteAndHistory,
                  onChanged: (v) {
                    state(() {
                      removeFavoriteAndHistory = !removeFavoriteAndHistory;
                    });
                  },
                ),
                CheckboxListTile(
                  title: Text("Also remove files on disk".tl),
                  value: removeBookFile,
                  onChanged: (v) {
                    state(() {
                      removeBookFile = !removeBookFile;
                    });
                  },
                )
              ],
            ),
            actions: [
              if (books.length == 1 && books.first.hasChapters)
                TextButton(
                  child: Text("Delete Chapters".tl),
                  onPressed: () {
                    context.pop();
                    showDeleteChaptersPopWindow(context, books.first);
                  },
                ),
              FilledButton(
                onPressed: () {
                  context.pop();
                  LocalManager().batchDeleteBooks(
                    books,
                    removeBookFile,
                    removeFavoriteAndHistory,
                  );
                  isDeleted = true;
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        });
      },
    );
    return isDeleted;
  }

  List<MenuEntry> exportActions(List<LocalBook> books) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export".tl,
        onClick: () => _showExportDialog(books),
      ),
    ];
  }

  void _showExportDialog(List<LocalBook> books) {
    var format = 0; // 0 = EPUB, 1 = PDF
    var merged = true; // true = single file, false = folder hierarchy
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setState) {
          return ContentDialog(
            title: "Export".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Format".tl).paddingHorizontal(16),
                RadioGroup<int>(
                  groupValue: format,
                  onChanged: (v) => setState(() => format = v ?? format),
                  child: Column(children: [
                    RadioListTile<int>(
                      title: const Text('EPUB'),
                      value: 0,
                    ),
                    RadioListTile<int>(
                      title: const Text('PDF'),
                      value: 1,
                    ),
                  ]),
                ),
                const Divider(),
                CheckboxListTile(
                  title: Text("Merge into single file".tl),
                  subtitle: Text(merged
                      ? "Single file".tl
                      : format == 0
                          ? "书名/卷名/章节名.epub"
                          : "书名/卷名/章节名.pdf"),
                  value: merged,
                  onChanged: (v) => setState(() => merged = v ?? merged),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  if (merged) {
                    _exportMerged(books, format == 0 ? '.epub' : '.pdf',
                        format == 0 ? 'epub' : 'pdf');
                  } else {
                    _exportHierarchy(books, format == 0 ? '.epub' : '.pdf',
                        format == 0 ? 'epub' : 'pdf');
                  }
                },
                child: Text("Export".tl),
              ),
            ],
          );
        });
      },
    );
  }

  /// Single file export: one EPUB or PDF containing all chapters.
  void _exportMerged(List<LocalBook> books, String ext, String format) async {
    var current = 0;
    var cacheDir = FilePath.join(App.cachePath, 'books_export');
    bool canceled = false;
    if (Directory(cacheDir).existsSync()) {
      Directory(cacheDir).deleteSync(recursive: true);
    }
    Directory(cacheDir).createSync();
    var loadingController = showLoadingDialog(
      context,
      allowCancel: true,
      message: "${"Exporting".tl} $current/${books.length}",
      withProgress: books.length > 1,
      onCancel: () => canceled = true,
    );
    try {
      var fileName = "";
      for (var book in books) {
        if (canceled) break;
        fileName = FilePath.join(
          cacheDir,
          sanitizeFileName(book.title, maxLength: 100) + ext,
        );
        if (format == 'epub') {
          await createNovelEpubFromLocalBook(book, fileName);
        } else {
          await createNovelPdfFromLocalBook(book, fileName);
        }
        current++;
        if (books.length > 1) {
          loadingController
              .setMessage("${"Exporting".tl} $current/${books.length}");
          loadingController.setProgress(current / books.length);
        }
      }
      if (canceled) return;
      if (books.length == 1) {
        await saveFile(file: File(fileName), filename: File(fileName).name);
      } else {
        var outFile = FilePath.join(App.cachePath, 'books_export.zip');
        loadingController.setProgress(null);
        loadingController.setMessage("Compressing".tl);
        await ZipFile.compressFolderAsync(cacheDir, outFile);
        await saveFile(file: File(outFile), filename: "books_export.zip");
        File(outFile).deleteIgnoreError();
      }
    } catch (e, s) {
      Log.error("Export", e, s);
      context.showMessage(message: e.toString());
    } finally {
      loadingController.close();
      Directory(cacheDir).deleteIgnoreError(recursive: true);
    }
  }

  /// Folder hierarchy export: 书名/卷名/章节.ext
  void _exportHierarchy(
      List<LocalBook> books, String ext, String format) async {
    final picker = DirectoryPicker();
    final dest = await picker.pickDirectory();
    if (dest == null) return;

    var current = 0;
    bool canceled = false;
    final loadingController = showLoadingDialog(
      context,
      allowCancel: true,
      message: "${"Exporting".tl} $current/${books.length}",
      withProgress: books.length > 1,
      onCancel: () => canceled = true,
    );
    try {
      for (final book in books) {
        if (canceled) break;
        final bookName = sanitizeFileName(book.title, maxLength: 100);
        final bookDir = Directory(FilePath.join(dest.path, bookName));
        if (!bookDir.existsSync()) bookDir.createSync(recursive: true);

        // Copy cover
        try {
          final coverFile = book.coverFile;
          if (coverFile.existsSync()) {
            await coverFile.copy(FilePath.join(bookDir.path, book.cover));
          }
        } catch (_) {}

        if (book.chapters != null && book.chapters!.isGrouped) {
          // Grouped: 书名/卷名/章节.ext — only export volumes with downloaded chapters
          for (final groupName in book.chapters!.groups) {
            final chapMap = book.chapters!.getGroup(groupName);
            // Filter to only downloaded chapters in this group
            final downloadedInGroup = chapMap.entries
                .where((e) => book.downloadedChapters.contains(e.key))
                .toList();
            if (downloadedInGroup.isEmpty) continue;
            final groupDir =
                Directory(FilePath.join(bookDir.path, sanitizeFileName(groupName)));
            if (!groupDir.existsSync()) groupDir.createSync(recursive: true);
            for (final entry in downloadedInGroup) {
              if (canceled) break;
              final chapName = sanitizeFileName(entry.value, maxLength: 80);
              final outPath = FilePath.join(groupDir.path, '$chapName$ext');
              await _exportChapter(book, entry.key, outPath, format);
            }
          }
        } else {
          // Flat: 书名/章节.ext — only export downloaded chapters
          final chapMap = book.chapters?.allChapters ?? {};
          for (final entry in chapMap.entries) {
            if (!book.downloadedChapters.contains(entry.key)) continue;
            if (canceled) break;
            final chapName = sanitizeFileName(entry.value, maxLength: 80);
            final outPath = FilePath.join(bookDir.path, '$chapName$ext');
            await _exportChapter(book, entry.key, outPath, format);
          }
        }
        current++;
        if (books.length > 1) {
          loadingController
              .setMessage("${"Exporting".tl} $current/${books.length}");
          loadingController.setProgress(current / books.length);
        }
      }
    } catch (e, s) {
      Log.error("Export", e, s);
      context.showMessage(message: e.toString());
    }
    loadingController.close();
  }

  /// Export a single chapter to EPUB or PDF.
  Future<void> _exportChapter(
      LocalBook book, String chapId, String outPath, String format) async {
    final chapDirName = LocalManager.getChapterDirectoryName(chapId);
    final chapDir = Directory(FilePath.join(book.baseDir, chapDirName));
    final jsonFile = File(FilePath.join(chapDir.path, 'chapter.json'));
    if (!jsonFile.existsSync()) return;

    final map = jsonDecode(jsonFile.readAsStringSync()) as Map;
    final title =
        (map['title'] ?? book.chapters?[chapId] ?? chapId).toString();
    final content = (map['content'] ?? '').toString();

    if (format == 'epub') {
      await createNovelEpub(
        NovelEpubData(
          title: title,
          author: book.subtitle,
          chapters: {title: _contentToHtml(content, chapDir)},
        ),
        App.cachePath,
        outPath,
        _collectEmbeddedImages(content, chapDir),
      );
    } else {
      await createNovelPdfChapter(
        title: title,
        content: content,
        chapterDir: chapDir,
        outputPath: outPath,
      );
    }
  }

  /// Convert chapter content lines to EPUB XHTML body.
  String _contentToHtml(String content, Directory chapDir) {
    final body = StringBuffer();
    var imgIdx = 0;
    for (final raw in content.split('\n')) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('file://')) {
        final path = t.substring(7);
        var ext = 'jpg';
        try {
          final bytes = File(path).readAsBytesSync();
          ext = detectFileType(bytes).ext;
          if (ext.startsWith('.')) ext = ext.substring(1);
          if (ext.isEmpty) ext = 'jpg';
        } catch (_) {}
        final rel = 'images/chap_img$imgIdx.$ext';
        body.writeln('    <p><img src="$rel" alt="illustration"/></p>');
        imgIdx++;
      } else if (t.startsWith('http://') || t.startsWith('https://')) {
        body.writeln(
            '    <p><img src="${_xmlEscape(t)}" alt="illustration"/></p>');
      } else {
        body.writeln('    <p>${_xmlEscape(t)}</p>');
      }
    }
    if (body.isEmpty) body.writeln('    <p>（本章无内容）</p>');
    return body.toString();
  }

  Map<String, List<int>> _collectEmbeddedImages(
      String content, Directory chapDir) {
    final embedded = <String, List<int>>{};
    var imgIdx = 0;
    for (final raw in content.split('\n')) {
      final t = raw.trim();
      if (t.startsWith('file://')) {
        final path = t.substring(7);
        try {
          final bytes = File(path).readAsBytesSync();
          var ext = detectFileType(bytes).ext;
          if (ext.startsWith('.')) ext = ext.substring(1);
          if (ext.isEmpty) ext = 'jpg';
          embedded['images/chap_img$imgIdx.$ext'] = bytes;
        } catch (_) {}
        imgIdx++;
      }
    }
    return embedded;
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

typedef ExportBookFunc = Future<File> Function(
    LocalBook book, String outFilePath);

/// Opens the folder containing the book in the system file explorer
Future<void> openBookFolder(LocalBook book) async {
  try {
    final folderPath = book.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open book folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalBook book) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(builder: (context, setState) {
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: book.downloadedChapters.length,
                itemBuilder: (context, index) {
                  var id = book.downloadedChapters[index];
                  var chapter = book.chapters![id] ?? "Unknown Chapter";
                  return CheckboxListTile(
                    title: Text(chapter),
                    value: chapters.contains(id),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          chapters.add(id);
                        } else {
                          chapters.remove(id);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: () {
                      Future.delayed(const Duration(milliseconds: 200), () {
                        LocalManager().deleteBookChapters(book, chapters);
                      });
                      App.rootContext.pop();
                    },
                    child: Text("Submit".tl),
                  )
                ],
              ),
            )
          ],
        );
      }),
    ),
  );
}
