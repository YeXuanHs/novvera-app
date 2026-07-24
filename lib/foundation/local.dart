import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:novvera/foundation/book_source/book_source.dart';
import 'package:novvera/foundation/book_type.dart';
import 'package:novvera/foundation/favorites.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_source/builtin_sources.dart';
import 'package:novvera/network/download.dart';
import 'package:novvera/pages/reader/reader.dart';
import 'package:novvera/utils/io.dart';

import 'app.dart';
import 'history.dart';

class LocalBook with HistoryMixin implements Book {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the book is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final BookChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final BookType bookType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  const LocalBook({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.bookType,
    required this.downloadedChapters,
    required this.createdAt,
  });

  LocalBook.fromRow(Row row)
      : id = row[0] as String,
        title = row[1] as String,
        subtitle = row[2] as String,
        tags = List.from(jsonDecode(row[3] as String)),
        directory = row[4] as String,
        chapters = BookChapters.fromJsonOrNull(jsonDecode(row[5] as String)),
        cover = row[6] as String,
        bookType = BookType(row[7] as int),
        downloadedChapters = List.from(jsonDecode(row[8] as String)),
        createdAt = DateTime.fromMillisecondsSinceEpoch(row[9] as int);

  File get coverFile => File(FilePath.join(
        baseDir,
        cover,
      ));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  @override
  String get description => "";

  @override
  String get sourceKey =>
      bookType == BookType.local ? "local" : bookType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, bookType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i=0; i<chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j=0; j<keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: bookType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ??
            History.fromModel(
              model: this,
              ep: 0,
              page: 0,
            ),
        author: subtitle,
        tags: tags,
      )
    );
  }

  @override
  HistoryType get historyType => bookType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  /// path to the directory where all the books are stored
  late String path;

  Directory get directory => Directory(path);

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!await newDir.list().isEmpty) {
      return "Directory is not empty";
    }
    try {
      await copyDirectoryIsolate(
        directory,
        newDir,
      );
      await File(FilePath.join(App.dataPath, 'local_path'))
          .writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    await directory.deleteContents(recursive: true);
    path = newPath;
    _checkNoMedia();
    return null;
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error("IO",
          "Failed to create test file in local path: $e\nUsing default path instead.");
      path = await findDefaultPath();
    }
  }

  Future<void> init() async {
    _db = sqlite3.open(
      '${App.dataPath}/local.db',
    );
    _db.execute('''
      CREATE TABLE IF NOT EXISTS books (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        book_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        PRIMARY KEY (id, book_type)
      );
    ''');
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    _checkPathValidation();
    _checkNoMedia();
    await BookSourceManager().ensureInit();
    restoreDownloadingTasks();
  }

  String findValidId(BookType type) {
    final res = _db.select(
      '''
      SELECT id FROM books WHERE book_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    return (int.parse((res.first[0])) + 1).toString();
  }

  Future<void> add(LocalBook book, [String? id]) async {
    var old = find(id ?? book.id, book.bookType);
    var downloaded = book.downloadedChapters;
    if (old != null) {
      downloaded.addAll(old.downloadedChapters);
    }
    _db.execute(
      'INSERT OR REPLACE INTO books VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id ?? book.id,
        book.title,
        book.subtitle,
        jsonEncode(book.tags),
        book.directory,
        jsonEncode(book.chapters),
        book.cover,
        book.bookType.value,
        jsonEncode(downloaded),
        book.createdAt.millisecondsSinceEpoch,
      ],
    );
    notifyListeners();
  }

  void remove(String id, BookType bookType) async {
    _db.execute(
      'DELETE FROM books WHERE id = ? AND book_type = ?;',
      [id, bookType.value],
    );
    notifyListeners();
  }

  void removeBook(LocalBook book) {
    remove(book.id, book.bookType);
    notifyListeners();
  }

  List<LocalBook> getBooks(LocalSortType sortType) {
    var res = _db.select('''
      SELECT * FROM books
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => LocalBook.fromRow(row)).toList();
  }

  LocalBook? find(String id, BookType bookType) {
    final res = _db.select(
      'SELECT * FROM books WHERE id = ? AND book_type = ?;',
      [id, bookType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalBook.fromRow(res.first);
  }

  @override
  void dispose() {
    super.dispose();
    _db.dispose();
  }

  List<LocalBook> getRecent() {
    final res = _db.select('''
      SELECT * FROM books
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalBook.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM books;
    ''');
    return res.first[0] as int;
  }

  LocalBook? findByName(String name) {
    final res = _db.select('''
      SELECT * FROM books
      WHERE title = ? OR directory = ?;
    ''', [name, name]);
    if (res.isEmpty) {
      return null;
    }
    return LocalBook.fromRow(res.first);
  }

  List<LocalBook> search(String keyword) {
    final res = _db.select('''
      SELECT * FROM books
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''', ['%$keyword%', '%$keyword%', '%$keyword%']);
    return res.map((row) => LocalBook.fromRow(row)).toList();
  }

  Future<List<String>> getImages(String id, BookType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var book = find(id, type) ?? (throw "Book Not Found");
    var directory = Directory(book.baseDir);
    if (book.hasChapters) {
      var cid =
          ep is int ? book.chapters!.ids.elementAt(ep - 1) : (ep as String);
      cid = getChapterDirectoryName(cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    // Novel offline chapters are stored as chapter.json (not image pages).
    final chapterJson = File(FilePath.join(directory.path, 'chapter.json'));
    if (chapterJson.existsSync()) {
      return _loadNovelChapterFile(chapterJson);
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude book.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a book page.
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        if (entity.name == 'chapter.json') {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) {
      var ai = int.tryParse(a.name.split('.').first);
      var bi = int.tryParse(b.name.split('.').first);
      if (ai != null && bi != null) {
        return ai.compareTo(bi);
      }
      return a.name.compareTo(b.name);
    });
    return files.map((e) => "file://${e.path}").toList();
  }

  List<String> _loadNovelChapterFile(File chapterJson) {
    final map = jsonDecode(chapterJson.readAsStringSync()) as Map;
    final content = (map['content'] ?? '').toString();
    final images = (map['images'] as List? ?? []).map((e) => e.toString()).toList();
    final chapterDir = chapterJson.parent.path;
    final resolved = <String>[];
    for (final img in images) {
      if (img.startsWith('http') || img.startsWith('file://')) {
        resolved.add(img);
      } else {
        resolved.add('file://${FilePath.join(chapterDir, img)}');
      }
    }
    final rewritten = content.split('\n').map((line) {
      final t = line.trim();
      if (t.isEmpty ||
          t.startsWith('http') ||
          t.startsWith('file://') ||
          t.contains('://')) {
        return line;
      }
      if (RegExp(r'^img\d+\.\w+$').hasMatch(t) ||
          RegExp(r'^\d+\.\w+$').hasMatch(t)) {
        return 'file://${FilePath.join(chapterDir, t)}';
      }
      return line;
    }).join('\n');

    return buildNovelReaderPages(content: rewritten, trailingImages: resolved);
  }

  bool isDownloaded(String id, BookType type,
      [int? ep, BookChapters? chapters]) {
    var book = find(id, type);
    if (book == null) return false;
    if (book.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (book.chapters?.length != chapters.length) {
        // update
        add(LocalBook(
          id: book.id,
          title: book.title,
          subtitle: book.subtitle,
          tags: book.tags,
          directory: book.directory,
          chapters: chapters,
          cover: book.cover,
          bookType: book.bookType,
          downloadedChapters: book.downloadedChapters,
          createdAt: book.createdAt,
        ));
      }
    }
    return book.downloadedChapters
        .contains((chapters ?? book.chapters)!.ids.elementAtOrNull(ep - 1));
  }

  /// Whether a local library entry is a light novel (has `chapter.json`).
  bool isLocalNovel(String id, BookType type) {
    final book = find(id, type);
    if (book == null || !book.hasChapters) return false;
    final chapId = book.downloadedChapters.firstOrNull ??
        book.chapters?.ids.firstOrNull;
    if (chapId == null) return false;
    final file = File(FilePath.join(
      book.baseDir,
      getChapterDirectoryName(chapId),
      'chapter.json',
    ));
    return file.existsSync();
  }

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, BookType type) {
    return downloadingTasks
        .any((element) => element.id == id && element.bookType == type);
  }

  Future<Directory> findValidDirectory(
      String id, BookType type, String name) async {
    var book = find(id, type);
    if (book != null) {
      return Directory(FilePath.join(path, book.directory));
    }
    const bookDirectoryMaxLength = 80;
    if (name.length > bookDirectoryMaxLength) {
      name = name.substring(0, bookDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  void completeTask(DownloadTask task) {
    add(task.toLocalBook());
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    downloadingTasks.firstOrNull?.resume();
  }

  void removeTask(DownloadTask task) {
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.first != task) {
      var shouldResume = !downloadingTasks.first.isPaused;
      downloadingTasks.first.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasks();
      if (shouldResume) {
        downloadingTasks.first.resume();
      }
    }
  }

  Future<void> saveCurrentDownloadingTasks() async {
    var tasks = downloadingTasks.map((e) => e.toJson()).toList();
    await File(FilePath.join(App.dataPath, 'downloading_tasks.json'))
        .writeAsString(jsonEncode(tasks));
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (file.existsSync()) {
      try {
        var tasks = jsonDecode(file.readAsStringSync());
        for (var e in tasks) {
          var task = DownloadTask.fromJson(e);
          if (task != null) {
            downloadingTasks.add(task);
          }
        }
      } catch (e) {
        file.delete();
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    downloadingTasks.first.resume();
  }

  void deleteBook(LocalBook c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk) {
      var dir = Directory(FilePath.join(path, c.directory));
      dir.deleteIgnoreError(recursive: true);
    }
    // Deleting a local book means that it's no longer available, thus both favorite and history should be deleted.
    if (c.bookType == BookType.local) {
      if (HistoryManager().find(c.id, c.bookType) != null) {
        HistoryManager().remove(c.id, c.bookType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.bookType);
      for (var f in folders) {
        LocalFavoritesManager().deleteBookWithId(f, c.id, c.bookType);
      }
    }
    remove(c.id, c.bookType);
    notifyListeners();
  }

  void deleteBookChapters(LocalBook c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE books SET downloadedChapters = ? WHERE id = ? AND book_type = ?;',
        [
          jsonEncode(newDownloadedChapters),
          c.id,
          c.bookType.value,
        ],
      );
    } else {
      _db.execute(
        'DELETE FROM books WHERE id = ? AND book_type = ?;',
        [c.id, c.bookType.value],
      );
    }
    var shouldRemovedDirs = <Directory>[];
    for (var chapter in chapters) {
      var dir = Directory(FilePath.join(
        c.baseDir,
        getChapterDirectoryName(chapter),
      ));
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _deleteDirectories(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteBooks(List<LocalBook> books, [bool removeFileOnDisk = true, bool removeFavoriteAndHistory = true]) {
    if (books.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in books) {
        if (removeFileOnDisk) {
          var dir = Directory(FilePath.join(path, c.directory));
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
        _db.execute(
          'DELETE FROM books WHERE id = ? AND book_type = ?;',
          [c.id, c.bookType.value],
        );
      }
    }
    catch(e, s) {
      Log.error("LocalManager", "Failed to batch delete books: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var bookIDs = books.map((e) => BookID(e.bookType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteBooksInAllFolders(bookIDs);
      HistoryManager().batchDeleteHistories(bookIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  /// Deletes the directories in a separate isolate to avoid blocking the UI thread.
  static void _deleteDirectories(List<Directory> directories) {
    Isolate.run(() async {
      await SAFTaskWorker().init();
      for (var dir in directories) {
        try {
          if (dir.existsSync()) {
            await dir.delete(recursive: true);
          }
        } catch (e) {
          continue;
        }
      }
    });
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' || char == '\\' || char == ':' || char == '*' ||
          char == '?'
          || char == '"' || char == '<' || char == '>' || char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }
}

enum LocalSortType {
  name("name"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}
