import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/book_source/book_source.dart';
import 'package:novvera/foundation/book_type.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/foundation/novel_source/builtin_sources.dart';
import 'package:novvera/foundation/res.dart';
import 'package:novvera/network/images.dart';
import 'package:novvera/utils/ext.dart';
import 'package:novvera/utils/file_type.dart';
import 'package:novvera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the book. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalBook toLocalBook();

  String get id;

  BookType get bookType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      case "NovelDownloadTask":
        return NovelDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.bookType == bookType;
  }

  @override
  int get hashCode => Object.hash(id, bookType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final BookSource source;

  final String bookId;

  /// book details. If null, the book details will be fetched from the source.
  BookDetails? book;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => bookId;

  @override
  BookType get bookType => BookType(source.key.hashCode);

  String? bookTitle;

  ImagesDownloadTask({
    required this.source,
    required this.bookId,
    this.book,
    this.chapters,
    this.bookTitle,
  });

  @override
  void cancel() {
    _isRunning = false;
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, bookType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = this.tasks.values.toList();
          for (var i = 0; i < tasks.length; i++) {
            if (!tasks[i].isComplete) {
              tasks[i].cancel();
              await tasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          }
          catch(e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          var dir = Directory(FilePath.join(path!, c));
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? book?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused";
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching book info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  var tasks = <int, _ImageDownloadWrapper>{};

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  void _scheduleTasks() {
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      Directory saveTo;
      if (book!.chapters != null) {
        saveTo = Directory(FilePath.join(
          path!,
          LocalManager.getChapterDirectoryName(
            _images!.keys.elementAt(_chapter),
          ),
        ));
        if (!saveTo.existsSync()) {
          saveTo.createSync(recursive: true);
        }
      } else {
        saveTo = Directory(path!);
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _message = "Resuming...";
    _isRunning = true;
    notifyListeners();
    runRecorder();

    if (book == null) {
      _message = "Fetching book info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadBookInfo!(bookId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        book = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          bookId,
          bookType,
          book!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress
            in ImageDownloader.loadThumbnail(book!.cover, source.key)) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (_images == null) {
      if (book!.chapters == null) {
        _message = "Fetching image list...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadBookPages!(bookId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        _images = {};
        _totalCount = 0;
        int cpCount = 0;
        int totalCpCount =
            chapters?.length ?? book!.chapters!.allChapters.length;
        for (var i in book!.chapters!.allChapters.keys) {
          if (chapters != null && !chapters!.contains(i)) {
            continue;
          }
          if (_images![i] != null) {
            _totalCount += _images![i]!.length;
            continue;
          }
          _message = "Fetching image list ($cpCount/$totalCpCount)...";
          notifyListeners();
          var res = await _runWithRetry(() async {
            var r = await source.loadBookPages!(bookId, i);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          if (!_isRunning) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            _images![i] = res.data;
            _totalCount += _images![i]!.length;
          }
        }
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    }

    while (_chapter < _images!.length) {
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      while (_index < images.length) {
        _scheduleTasks();
        var task = tasks[_index]!;
        await task.wait();
        if (isPaused) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}");
          return;
        }
        _index++;
        _downloadedCount++;
        _message = "$_downloadedCount/$_totalCount";
        await LocalManager().saveCurrentDownloadingTasks();
      }
      _index = 0;
      _chapter++;
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => book?.title ?? bookTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "bookId": bookId,
      "book": book?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
      source: BookSource.find(json["source"])!,
      bookId: json["bookId"],
      book:
          json["book"] == null ? null : BookDetails.fromJson(json["book"]),
      chapters: ListOrNull.from(json["chapters"]),
    )
      ..path = json["path"]
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"]
      .._totalCount = json["totalCount"]
      .._index = json["index"]
      .._chapter = json["chapter"];
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalBook toLocalBook() {
    return LocalBook(
      id: book!.id,
      title: title,
      subtitle: book!.subTitle ?? '',
      tags: book!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: book!.chapters,
      cover: File(_cover!.split("file://").last).name,
      bookType: BookType(source.key.hashCode),
      downloadedChapters: chapters ?? book?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.bookId == bookId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(bookId, source.key);
}

Future<Res<T>> _runWithRetry<T>(Future<T> Function() task,
    {int retry = 3}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadBookImageUnwrapped(
          image, task.source.key, task.bookId, chapter)) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          var fileType = detectFileType(p.imageBytes!);
          var file = saveTo.joinFile("$index${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
          isComplete = true;
          for (var c in completers) {
            c.complete(this);
          }
          completers.clear();
        }
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        start();
        return;
      }
      error = e.toString();
      for (var c in completers) {
        if (!c.isCompleted) {
          c.complete(this);
        }
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final BookDetails book;

  late BookSource source;

  /// Download book by archive url
  ///
  /// Currently only support zip file and books without chapters
  ArchiveDownloadTask(this.archiveUrl, this.book) {
    source = BookSource.find(book.sourceKey)!;
  }

  FileDownloader? _downloader;

  String _message = "Fetching book info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  BookType get bookType => BookType(source.key.hashCode);

  @override
  String? get cover => book.cover;

  @override
  String get id => book.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...";

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        book.id,
        bookType,
        book.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile =
        File(FilePath.join(App.dataPath, "archive_downloading.zip"));

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => book.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "book": book.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      BookDetails.fromJson(json["book"]),
    )..path = json["path"];
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalBook toLocalBook() {
    return LocalBook(
      id: book.id,
      title: title,
      subtitle: book.subTitle ?? '',
      tags: book.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      bookType: BookType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}

/// Offline novel download → [LocalManager] (same UX as Venera local library).
///
/// Each chapter is stored as `chapter.json` (+ illustration files).
/// Desktop may pass [saveRoot] (folder picker); mobile uses [LocalManager.path].
class NovelDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final BookSource source;
  final String bookId;
  BookDetails? book;
  final List<String>? chapters;
  final String? saveRoot;
  String? bookTitle;

  NovelDownloadTask({
    required this.source,
    required this.bookId,
    this.book,
    this.chapters,
    this.saveRoot,
    this.bookTitle,
  });

  @override
  String get id => bookId;

  @override
  BookType get bookType => BookType(source.key.hashCode);

  bool _isRunning = false;
  bool _isError = false;
  String _message = "Pending...";
  String? _cover;
  int _done = 0;
  int _total = 0;
  int _chapterIndex = 0;

  bool get _useAbsoluteDirectory =>
      saveRoot != null && saveRoot!.trim().isNotEmpty;

  @override
  double get progress {
    if (_total <= 0) return 0;
    return (_done / _total).clamp(0.0, 1.0);
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  int get speed => currentSpeed;

  @override
  String? get cover => _cover ?? book?.cover;

  @override
  String get message => _message;

  @override
  String get title => book?.title ?? bookTitle ?? "Loading...";

  @override
  void cancel() {
    _isRunning = false;
    LocalManager().removeTask(this);
    if (path != null && LocalManager().find(id, bookType) == null) {
      try {
        Directory(path!).deleteSync(recursive: true);
      } catch (e) {
        Log.error("Download", "Failed to delete directory: $e");
      }
    }
  }

  @override
  void pause() {
    if (!_isRunning) return;
    _isRunning = false;
    _message = "Paused";
    stopRecorder();
    notifyListeners();
    LocalManager().saveCurrentDownloadingTasks();
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
  }

  String _directoryForDb() {
    if (path == null) return '';
    if (_useAbsoluteDirectory) return path!;
    final root = LocalManager().path;
    if (path!.startsWith(root)) {
      return Directory(path!).name;
    }
    return path!;
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isRunning = true;
    _isError = false;
    notifyListeners();
    runRecorder();

    if (book == null) {
      _message = "Fetching book info...";
      notifyListeners();
      final res = await _runWithRetry(() async {
        final r = await source.loadBookInfo!(bookId);
        if (r.error) throw r.errorMessage!;
        return r.data;
      });
      if (!_isRunning) return;
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      }
      book = res.data;
    }

    if (book!.chapters == null || book!.chapters!.length == 0) {
      _setError("Error: No chapters");
      return;
    }

    final toDownload = chapters ?? book!.chapters!.ids.toList();
    _total = toDownload.length;
    _done = _chapterIndex.clamp(0, _total);

    if (path == null) {
      try {
        if (_useAbsoluteDirectory) {
          final name = sanitizeFileName(book!.title, maxLength: 80);
          final dir = Directory(FilePath.join(saveRoot!, name));
          if (!dir.existsSync()) await dir.create(recursive: true);
          path = dir.path;
        } else {
          final dir = await LocalManager().findValidDirectory(
            bookId,
            bookType,
            book!.title,
          );
          if (!(await dir.exists())) await dir.create();
          path = dir.path;
        }
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      try {
        await for (final progress
            in ImageDownloader.loadThumbnail(book!.cover, source.key)) {
          if (progress.imageBytes != null) {
            var ext = detectFileType(progress.imageBytes!).ext;
            if (ext.startsWith('.')) ext = ext.substring(1);
            if (ext.isEmpty) ext = 'jpg';
            final file = File(FilePath.join(path!, 'cover.$ext'));
            await file.writeAsBytes(progress.imageBytes!);
            _cover = 'file://${file.path}';
            break;
          }
        }
      } catch (e) {
        Log.warning("Download", "cover failed: $e");
      }
    }

    while (_chapterIndex < toDownload.length) {
      if (!_isRunning) return;
      final chapId = toDownload[_chapterIndex];
      final chapTitle = book!.chapters!.allChapters[chapId] ?? chapId;
      _message = "Downloading ${_done + 1}/$_total · $chapTitle";
      notifyListeners();

      final chapDirName = LocalManager.getChapterDirectoryName(chapId);
      final chapDir = Directory(FilePath.join(path!, chapDirName));
      if (!chapDir.existsSync()) {
        await chapDir.create(recursive: true);
      }
      final outFile = File(FilePath.join(chapDir.path, 'chapter.json'));
      if (outFile.existsSync()) {
        _done++;
        _chapterIndex++;
        await LocalManager().saveCurrentDownloadingTasks();
        continue;
      }

      final res = await loadNovelChapter(source.key, bookId, chapId);
      if (!_isRunning) return;
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      }

      final data = res.data;
      var content = (data['content'] ?? '').toString();
      final trailing = (data['images'] as List? ?? [])
          .map((e) => e.toString())
          .where((e) => e.startsWith('http'))
          .toList();

      final urlToLocal = <String, String>{};
      var imgIndex = 0;

      Future<String?> saveImage(String url) async {
        final normalized = normalizeNovelImageUrl(url);
        if (!normalized.startsWith('http')) return null;
        if (urlToLocal.containsKey(normalized)) return urlToLocal[normalized];
        try {
          await for (final p in ImageDownloader.loadBookImage(
            normalized,
            source.key,
            bookId,
            chapId,
          )) {
            if (p.imageBytes != null) {
              var ext = detectFileType(p.imageBytes!).ext;
              if (ext.startsWith('.')) ext = ext.substring(1);
              if (ext.isEmpty) {
                final pathLower =
                    Uri.tryParse(normalized)?.path.toLowerCase() ?? '';
                ext = pathLower.contains('.png')
                    ? 'png'
                    : pathLower.contains('.webp')
                        ? 'webp'
                        : 'jpg';
              }
              final name = 'img$imgIndex.$ext';
              imgIndex++;
              await File(FilePath.join(chapDir.path, name))
                  .writeAsBytes(p.imageBytes!);
              urlToLocal[normalized] = name;
              return name;
            }
          }
        } catch (e) {
          Log.warning("Download", "image $normalized: $e");
        }
        return null;
      }

      final allUrls = <String>{};
      for (final line in content.split('\n')) {
        final t = line.trim();
        if (t.startsWith('http://') || t.startsWith('https://')) {
          allUrls.add(normalizeNovelImageUrl(t));
        }
      }
      for (final u in trailing) {
        allUrls.add(normalizeNovelImageUrl(u));
      }

      for (final u in allUrls) {
        if (!_isRunning) return;
        await saveImage(u);
      }

      content = content.split('\n').map((line) {
        final t = line.trim();
        if (t.startsWith('http://') || t.startsWith('https://')) {
          final local = urlToLocal[normalizeNovelImageUrl(t)];
          return local ?? line;
        }
        return line;
      }).join('\n');

      final localImages = urlToLocal.values.toList();
      await outFile.writeAsString(jsonEncode({
        'content': content,
        'images': localImages,
        'title': chapTitle,
      }));

      _done++;
      _chapterIndex++;
      _message = "$_done/$_total";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  @override
  LocalBook toLocalBook() {
    var coverName = 'cover.jpg';
    try {
      for (final f in Directory(path!).listSync()) {
        if (f is File && f.name.startsWith('cover.')) {
          coverName = f.name;
          break;
        }
      }
    } catch (_) {}
    return LocalBook(
      id: book!.id,
      title: title,
      subtitle: book!.subTitle ?? '',
      tags: book!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: _directoryForDb(),
      chapters: book!.chapters,
      cover: coverName,
      bookType: BookType(source.key.hashCode),
      downloadedChapters: chapters ?? book?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "NovelDownloadTask",
      "source": source.key,
      "bookId": bookId,
      "book": book?.toJson(),
      "chapters": chapters,
      "saveRoot": saveRoot,
      "path": path,
      "cover": _cover,
      "done": _done,
      "total": _total,
      "chapterIndex": _chapterIndex,
      "bookTitle": bookTitle,
    };
  }

  static NovelDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "NovelDownloadTask") return null;
    final src = BookSource.find(json["source"]);
    if (src == null) return null;
    return NovelDownloadTask(
      source: src,
      bookId: json["bookId"],
      book: json["book"] == null
          ? null
          : BookDetails.fromJson(json["book"]),
      chapters: ListOrNull.from(json["chapters"]),
      saveRoot: json["saveRoot"] as String?,
      bookTitle: json["bookTitle"] as String?,
    )
      ..path = json["path"]
      .._cover = json["cover"]
      .._done = json["done"] ?? 0
      .._total = json["total"] ?? 0
      .._chapterIndex = json["chapterIndex"] ?? 0;
  }

  @override
  bool operator ==(Object other) {
    if (other is NovelDownloadTask) {
      return other.bookId == bookId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(bookId, source.key);
}
