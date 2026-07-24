import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:novvera/components/components.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/book_source/book_source.dart';
import 'package:novvera/foundation/book_type.dart';
import 'package:novvera/foundation/favorites.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/utils/ext.dart';
import 'package:novvera/utils/translations.dart';
import 'io.dart';

/// Import light novels into [LocalManager] (folder with `chapter.json`, or EPUB).
class ImportNovel {
  final String? selectedFolder;
  final bool copyToLocal;

  const ImportNovel({this.selectedFolder, this.copyToLocal = true});

  /// One book directory: `{title}/cover.*` + `{chapter}/chapter.json`.
  Future<bool> directory(bool single) async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) return false;
    final imported = <String?, List<LocalBook>>{selectedFolder: []};
    try {
      if (single) {
        final result = await _checkSingleNovel(path);
        if (result == null) {
          App.rootContext.showMessage(message: "Invalid book folder".tl);
          return false;
        }
        imported[selectedFolder]!.add(result);
      } else {
        await for (final entry in path.list()) {
          if (entry is Directory) {
            final result = await _checkSingleNovel(entry);
            if (result != null) imported[selectedFolder]!.add(result);
          }
        }
        if (imported[selectedFolder]!.isEmpty) {
          App.rootContext.showMessage(message: "No valid books found".tl);
          return false;
        }
      }
    } catch (e, s) {
      Log.error("Import Novel", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
      return false;
    }
    return registerBooks(imported, copyToLocal);
  }

  /// Pick a single `.epub` file.
  Future<bool> epub() async {
    final file = await selectFile(ext: ['epub']);
    if (file == null) return false;
    final controller = showLoadingDialog(App.rootContext, allowCancel: false);
    try {
      final book = await _importEpubFile(File(file.path));
      controller.close();
      if (book == null) {
        App.rootContext.showMessage(message: "Invalid EPUB".tl);
        return false;
      }
      return registerBooks({selectedFolder: [book]}, false);
    } catch (e, s) {
      controller.close();
      Log.error("Import Novel", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
      return false;
    }
  }

  /// Pick a directory of `.epub` files.
  Future<bool> multipleEpub() async {
    final picker = DirectoryPicker();
    final dir = await picker.pickDirectory(directAccess: true);
    if (dir == null) return false;
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((e) => e.extension == 'epub')
        .toList();
    if (files.isEmpty) {
      App.rootContext.showMessage(message: "No valid books found".tl);
      return false;
    }
    final controller = showLoadingDialog(App.rootContext, allowCancel: false);
    final books = <LocalBook>[];
    for (final file in files) {
      try {
        final book = await _importEpubFile(file);
        if (book != null) books.add(book);
      } catch (e, s) {
        Log.error("Import Novel", e.toString(), s);
      }
    }
    controller.close();
    if (books.isEmpty) {
      App.rootContext.showMessage(message: "No valid books found".tl);
      return false;
    }
    return registerBooks({selectedFolder: books}, false);
  }

  /// Rescan [LocalManager.path] and re-register folders that look like novels.
  Future<bool> localDownloads() async {
    final localDir = LocalManager().directory;
    final imported = <String?, List<LocalBook>>{null: []};
    var cancelled = false;
    final controller = showLoadingDialog(App.rootContext, onCancel: () {
      cancelled = true;
    });
    try {
      if (!await localDir.exists()) {
        App.rootContext.showMessage(message: "Local path not found".tl);
        controller.close();
        return false;
      }
      await for (final entry in localDir.list()) {
        if (cancelled) break;
        if (entry is Directory) {
          final stat = await entry.stat();
          final result = await _checkSingleNovel(
            entry,
            createTime: stat.modified,
            useRelativePath: true,
          );
          if (result != null) imported[null]!.add(result);
        }
      }
      if (!cancelled && imported[null]!.isEmpty) {
        App.rootContext.showMessage(message: "No valid books found".tl);
      }
    } catch (e, s) {
      Log.error("Import Novel", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    controller.close();
    if (cancelled) return false;
    return registerBooks(imported, false);
  }

  /// Novvera offline layout: cover image + chapter dirs each with `chapter.json`.
  Future<LocalBook?> _checkSingleNovel(
    Directory directory, {
    String? id,
    String? title,
    String? subtitle,
    List<String>? tags,
    DateTime? createTime,
    bool useRelativePath = false,
  }) async {
    if (!(await directory.exists())) return null;
    final name = title ?? directory.name;
    if (LocalManager().findByName(name) != null) {
      Log.info("Import Novel", "Book already exists: $name");
      return null;
    }

    final chapterIds = <String>[];
    final chapterTitles = <String, String>{};
    String coverPath = '';

    await for (final entry in directory.list()) {
      if (entry is Directory) {
        final jsonFile = File(FilePath.join(entry.path, 'chapter.json'));
        if (!jsonFile.existsSync()) continue;
        final chapId = entry.name;
        chapterIds.add(chapId);
        try {
          final map = jsonDecode(jsonFile.readAsStringSync()) as Map;
          final t = (map['title'] ?? '').toString().trim();
          chapterTitles[chapId] = t.isNotEmpty ? t : chapId;
        } catch (_) {
          chapterTitles[chapId] = chapId;
        }
      } else if (entry is File) {
        const imageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'];
        if (imageExtensions.contains(entry.extension) &&
            entry.name.toLowerCase().startsWith('cover')) {
          coverPath = entry.name;
        }
      }
    }

    if (chapterIds.isEmpty) return null;
    chapterIds.sort();

    if (coverPath.isEmpty) {
      // Fallback: first image under first chapter, or any cover-like file.
      final firstChap =
          Directory(FilePath.join(directory.path, chapterIds.first));
      await for (final entry in firstChap.list()) {
        if (entry is File) {
          const imageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'];
          if (imageExtensions.contains(entry.extension)) {
            coverPath = '${chapterIds.first}/${entry.name}';
            break;
          }
        }
      }
    }
    if (coverPath.isEmpty) {
      // Placeholder: reader still works; tile may miss cover.
      coverPath = 'cover.jpg';
    }

    final directoryPath = useRelativePath ? directory.name : directory.path;
    return LocalBook(
      id: id ?? '0',
      title: name,
      subtitle: subtitle ?? '',
      tags: tags ?? const ['type:novel'],
      directory: directoryPath,
      chapters: BookChapters(
        {for (final id in chapterIds) id: chapterTitles[id] ?? id},
      ),
      cover: coverPath,
      bookType: BookType.local,
      downloadedChapters: chapterIds,
      createdAt: createTime ?? DateTime.now(),
    );
  }

  Future<LocalBook?> _importEpubFile(File epubFile) async {
    final bytes = await epubFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.isEmpty) return null;

    ArchiveFile? findEntry(String name) {
      final lower = name.toLowerCase().replaceAll('\\', '/');
      for (final f in archive.files) {
        if (!f.isFile) continue;
        if (f.name.toLowerCase().replaceAll('\\', '/') == lower) return f;
      }
      return null;
    }

    String readText(ArchiveFile f) =>
        utf8.decode(f.content as List<int>, allowMalformed: true);

    final container = findEntry('META-INF/container.xml');
    if (container == null) return null;
    final containerXml = readText(container);
    final opfPath = RegExp(
      r'full-path\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(containerXml)?.group(1);
    if (opfPath == null || opfPath.isEmpty) return null;

    final opf = findEntry(opfPath);
    if (opf == null) return null;
    final opfXml = readText(opf);
    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';

    String meta(String prop) {
      final re = RegExp(
        '<dc:$prop[^>]*>([^<]*)</dc:$prop>',
        caseSensitive: false,
      );
      return re.firstMatch(opfXml)?.group(1)?.trim() ?? '';
    }

    final title = meta('title').isNotEmpty
        ? meta('title')
        : epubFile.name.replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');
    final author = meta('creator');

    if (LocalManager().findByName(title) != null) {
      Log.info("Import Novel", "Book already exists: $title");
      return null;
    }

    // id → href
    final idHref = <String, String>{};
    for (final m in RegExp(
      r'<item[^>]+>',
      caseSensitive: false,
    ).allMatches(opfXml)) {
      final tag = m.group(0)!;
      final id = RegExp(r'\bid\s*=\s*"([^"]+)"', caseSensitive: false)
          .firstMatch(tag)
          ?.group(1);
      final href = RegExp(r'\bhref\s*=\s*"([^"]+)"', caseSensitive: false)
          .firstMatch(tag)
          ?.group(1);
      if (id != null && href != null) idHref[id] = href;
    }

    final spine = <String>[];
    for (final m in RegExp(
      r'<itemref[^>]+idref\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).allMatches(opfXml)) {
      spine.add(m.group(1)!);
    }
    if (spine.isEmpty) return null;

    String? coverHref;
    final coverMeta = RegExp(
      r'<meta[^>]+name\s*=\s*"cover"[^>]+content\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(opfXml)?.group(1);
    if (coverMeta != null && idHref.containsKey(coverMeta)) {
      coverHref = idHref[coverMeta];
    }
    coverHref ??= RegExp(
      r'<item[^>]+properties\s*=\s*"[^"]*cover-image[^"]*"[^>]+href\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(opfXml)?.group(1);

    final outRoot = Directory(FilePath.join(
      LocalManager().path,
      findValidDirectoryName(LocalManager().path, sanitizeFileName(title)),
    ));
    await outRoot.create(recursive: true);

    String coverName = 'cover.jpg';
    if (coverHref != null) {
      final coverEntry = findEntry(_joinEpubPath(opfDir, coverHref));
      if (coverEntry != null) {
        var ext = coverHref.split('.').last.toLowerCase();
        if (ext.length > 5) ext = 'jpg';
        coverName = 'cover.$ext';
        await File(FilePath.join(outRoot.path, coverName))
            .writeAsBytes(coverEntry.content as List<int>);
      }
    }

    final chapterIds = <String>[];
    final chapterTitles = <String, String>{};
    var index = 0;
    for (final idref in spine) {
      final href = idHref[idref];
      if (href == null) continue;
      final entry = findEntry(_joinEpubPath(opfDir, href));
      if (entry == null) continue;
      final html = readText(entry);
      final chapTitle = _htmlTitle(html) ?? 'Chapter ${index + 1}';
      final text = _htmlToNovelText(html);
      if (text.trim().isEmpty) continue;

      final chapId = '${index + 1}';
      final chapDir = Directory(FilePath.join(outRoot.path, chapId));
      await chapDir.create(recursive: true);
      await File(FilePath.join(chapDir.path, 'chapter.json')).writeAsString(
        jsonEncode({
          'content': text,
          'images': <String>[],
          'title': chapTitle,
        }),
      );
      chapterIds.add(chapId);
      chapterTitles[chapId] = chapTitle;
      index++;
    }

    if (chapterIds.isEmpty) {
      try {
        await outRoot.delete(recursive: true);
      } catch (_) {}
      return null;
    }

    return LocalBook(
      id: '0',
      title: title,
      subtitle: author,
      tags: const ['type:novel', 'format:epub'],
      directory: outRoot.name,
      chapters: BookChapters(
        {for (final id in chapterIds) id: chapterTitles[id] ?? id},
      ),
      cover: coverName,
      bookType: BookType.local,
      downloadedChapters: chapterIds,
      createdAt: DateTime.now(),
    );
  }

  static String _joinEpubPath(String base, String href) {
    final h = href.replaceAll('\\', '/');
    if (h.startsWith('/')) return h.substring(1);
    if (base.isEmpty) return h;
    final joined = '$base$h'.replaceAll('\\', '/');
    // Resolve ../
    final parts = <String>[];
    for (final p in joined.split('/')) {
      if (p.isEmpty || p == '.') continue;
      if (p == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(p);
      }
    }
    return parts.join('/');
  }

  static String? _htmlTitle(String html) {
    final m = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html);
    final t = m?.group(1)?.trim();
    if (t == null || t.isEmpty) return null;
    return _decodeHtmlEntities(t);
  }

  static String _htmlToNovelText(String html) {
    var s = html;
    // Drop scripts/styles.
    s = s.replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        '');
    // Block breaks → newlines.
    s = s.replaceAll(
        RegExp(r'<(br|/p|/div|/h[1-6]|/li)\s*/?>', caseSensitive: false),
        '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = _decodeHtmlEntities(s);
    final lines = s
        .split('\n')
        .map((e) => e.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return lines.join('\n');
  }

  static String _decodeHtmlEntities(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1)!);
          if (code == null) return m.group(0)!;
          return String.fromCharCode(code);
        });
  }

  static Future<Map<String, String>> _copyDirectories(
      Map<String, dynamic> data) async {
    return overrideIO(() async {
      final toBeCopied = data['toBeCopied'] as List<String>;
      final destination = data['destination'] as String;
      final result = <String, String>{};
      for (final dir in toBeCopied) {
        final source = Directory(dir);
        var dest = Directory("$destination/${source.name}");
        if (dest.existsSync()) {
          Log.info("Import Novel",
              "Directory already exists: ${source.name}\nRenaming the old directory.");
          dest.renameSync(
              findValidDirectoryName(dest.parent.path, "${dest.path}_old"));
        }
        dest.createSync();
        await copyDirectory(source, dest);
        result[source.path] = dest.path;
      }
      return result;
    });
  }

  Future<Map<String?, List<LocalBook>>> _copyBooksToLocalDir(
      Map<String?, List<LocalBook>> books) async {
    final destPath = LocalManager().path;
    final result = <String?, List<LocalBook>>{};
    for (final favoriteFolder in books.keys) {
      result[favoriteFolder] = books[favoriteFolder]!
          .where((c) => c.directory.startsWith(destPath))
          .toList();
      books[favoriteFolder]!
          .removeWhere((c) => c.directory.startsWith(destPath));

      if (books[favoriteFolder]!.isEmpty) continue;

      try {
        final pathMap = await compute<Map<String, dynamic>, Map<String, String>>(
            _copyDirectories, {
          'toBeCopied':
              books[favoriteFolder]!.map((e) => e.directory).toList(),
          'destination': destPath,
        });
        for (final c in books[favoriteFolder]!) {
          result[favoriteFolder]!.add(LocalBook(
            id: c.id,
            title: c.title,
            subtitle: c.subtitle,
            tags: c.tags,
            directory: Directory(pathMap[c.directory]!).name,
            chapters: c.chapters,
            cover: c.cover,
            bookType: c.bookType,
            downloadedChapters: c.downloadedChapters,
            createdAt: c.createdAt,
          ));
        }
      } catch (e, s) {
        App.rootContext.showMessage(message: "Failed to copy books".tl);
        Log.error("Import Novel", e.toString(), s);
        return result;
      }
    }
    return result;
  }

  Future<bool> registerBooks(
      Map<String?, List<LocalBook>> importedBooks, bool copy) async {
    try {
      if (copy) {
        importedBooks = await _copyBooksToLocalDir(importedBooks);
      }
      var importedCount = 0;
      for (final folder in importedBooks.keys) {
        for (final book in importedBooks[folder]!) {
          final id = LocalManager().findValidId(book.bookType);
          final registered = LocalBook(
            id: id,
            title: book.title,
            subtitle: book.subtitle,
            tags: book.tags,
            directory: book.directory,
            chapters: book.chapters,
            cover: book.cover,
            bookType: book.bookType,
            downloadedChapters: book.downloadedChapters,
            createdAt: book.createdAt,
          );
          await LocalManager().add(registered, id);
          importedCount++;
          if (folder != null) {
            LocalFavoritesManager().addBook(
              folder,
              FavoriteItem(
                id: id,
                name: book.title,
                coverPath: book.cover,
                author: book.subtitle,
                type: book.bookType,
                tags: book.tags,
                favoriteTime: book.createdAt,
              ),
            );
          }
        }
      }
      App.rootContext.showMessage(
        message: "Imported @a books".tlParams({'a': importedCount}),
      );
    } catch (e, s) {
      App.rootContext.showMessage(message: "Failed to register books".tl);
      Log.error("Import Novel", e.toString(), s);
      return false;
    }
    return true;
  }
}
