import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/utils/file_type.dart';
import 'package:novvera/utils/io.dart';

class EpubData {
  final String title;

  final String author;

  final File cover;

  final Map<String, List<File>> chapters;

  const EpubData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
  });
}

/// EPUB requires [mimetype] as the first ZIP entry and stored uncompressed.
void _writeEpubZip(String outFilePath, List<_EpubZipEntry> entries) {
  final archive = Archive();
  for (final e in entries) {
    if (e.store) {
      archive.addFile(ArchiveFile.noCompress(e.path, e.bytes.length, e.bytes));
    } else {
      archive.addFile(ArchiveFile.bytes(e.path, e.bytes));
    }
  }
  final encoded = ZipEncoder().encodeBytes(archive);
  File(outFilePath)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(encoded, flush: true);
}

class _EpubZipEntry {
  const _EpubZipEntry(this.path, this.bytes, {this.store = false});
  final String path;
  final List<int> bytes;
  final bool store;
}

List<int> _utf8(String s) => utf8.encode(s);

Future<File> createEpubComic(
    EpubData data, String cacheDir, String outFilePath) async {
  final coverExt = data.cover.extension;
  final coverMime = FileType.fromExtension(coverExt).mime;
  final coverBytes = data.cover.readAsBytesSync();
  final uuid = const Uuid().v4();
  final titleEsc = _xmlEscape(data.title);
  final authorEsc = _xmlEscape(data.author);

  final entries = <_EpubZipEntry>[
    _EpubZipEntry(
      'mimetype',
      _utf8('application/epub+zip'),
      store: true,
    ),
    _EpubZipEntry(
      'META-INF/container.xml',
      _utf8('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
    ),
  ];

  entries.add(_EpubZipEntry('OEBPS/images/cover.$coverExt', coverBytes));

  final manifest = StringBuffer();
  final spine = StringBuffer();
  final navMap = StringBuffer();
  manifest.writeln(
      '        <item id="cover_image" href="images/cover.$coverExt" media-type="$coverMime"/>');
  manifest.writeln(
      '        <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');
  manifest.writeln(
      '        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>');

  var imgIndex = 0;
  var chapterIndex = 0;
  var playOrder = 1;
  final chapterNames = data.chapters.keys.toList();

  for (final chapter in chapterNames) {
    final images = <String>[];
    for (final image in data.chapters[chapter]!) {
      final ext = image.extension;
      final name = 'img$imgIndex.$ext';
      entries.add(
        _EpubZipEntry('OEBPS/images/$name', image.readAsBytesSync()),
      );
      images.add('images/$name');
      final mime = FileType.fromExtension(ext).mime;
      manifest.writeln(
          '        <item id="img$imgIndex" href="images/$name" media-type="$mime"/>');
      imgIndex++;
    }
    final chapterEsc = _xmlEscape(chapter);
    entries.add(_EpubZipEntry(
      'OEBPS/$chapterIndex.html',
      _utf8('''<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
    "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>$chapterEsc</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
    <style type="text/css">
        img { max-width: 100%; height: auto; }
        body { margin: 0; padding: 0; }
    </style>
</head>
<body>
    <h1>$chapterEsc</h1>
    <div>
${images.map((e) => '        <img src="$e" alt="$e"/>').join('\n')}
    </div>
</body>
</html>
'''),
    ));
    manifest.writeln(
        '        <item id="chapter$chapterIndex" href="$chapterIndex.html" media-type="application/xhtml+xml"/>');
    spine.writeln('        <itemref idref="chapter$chapterIndex"/>');
    navMap.writeln(
        '        <navPoint id="chapter$chapterIndex" playOrder="$playOrder">');
    navMap.writeln(
        '            <navLabel><text>$chapterEsc</text></navLabel>');
    navMap.writeln('            <content src="$chapterIndex.html"/>');
    navMap.writeln('        </navPoint>');
    playOrder++;
    chapterIndex++;
  }

  entries.add(_EpubZipEntry(
    'OEBPS/content.opf',
    _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0"
    xmlns="http://www.idpf.org/2007/opf"
    unique-identifier="book_id"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <metadata>
        <dc:title>$titleEsc</dc:title>
        <dc:creator>$authorEsc</dc:creator>
        <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
        <dc:language>zh</dc:language>
        <meta name="cover" content="cover_image"/>
    </metadata>
    <manifest>
${manifest.toString()}
    </manifest>
    <spine toc="toc">
${spine.toString()}
    </spine>
</package>
'''),
  ));

  final navLis = StringBuffer();
  for (var i = 0; i < chapterIndex; i++) {
    navLis.writeln(
        '        <li><a href="$i.html">${_xmlEscape(chapterNames[i])}</a></li>');
  }
  entries.add(_EpubZipEntry(
    'OEBPS/nav.xhtml',
    _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>$titleEsc</title><meta charset="utf-8"/></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>$titleEsc</h1>
    <ol>
${navLis.toString()}
    </ol>
  </nav>
</body>
</html>
'''),
  ));

  entries.add(_EpubZipEntry(
    'OEBPS/toc.ncx',
    _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
    <head>
        <meta name="dtb:uid" content="urn:uuid:$uuid"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
    </head>
    <docTitle>
        <text>$titleEsc</text>
    </docTitle>
    <navMap>
${navMap.toString()}
    </navMap>
</ncx>
'''),
  ));

  _writeEpubZip(outFilePath, entries);
  return File(outFilePath);
}

Future<File> createEpubWithLocalComic(
    LocalComic comic, String outFilePath) async {
  var chapters = <String, List<File>>{};
  if (comic.chapters == null) {
    chapters[comic.title] =
        (await LocalManager().getImages(comic.id, comic.comicType, 0))
            .map((e) => File(e))
            .toList();
  } else {
    for (var chapter in comic.downloadedChapters) {
      chapters[comic.chapters![chapter]!] =
          (await LocalManager().getImages(comic.id, comic.comicType, chapter))
              .map((e) => File(e))
              .toList();
    }
  }
  var data = EpubData(
    title: comic.title,
    author: comic.subtitle,
    cover: comic.coverFile,
    chapters: chapters,
  );

  final cacheDir = App.cachePath;

  return Isolate.run(() => overrideIO(() async {
        return createEpubComic(data, cacheDir, outFilePath);
      }));
}

String _xmlEscape(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// Text-novel EPUB: chapter title → XHTML body (inner HTML, already escaped).
class NovelEpubData {
  const NovelEpubData({
    required this.title,
    required this.author,
    required this.chapters,
    this.coverBytes,
    this.coverExt = 'jpg',
  });

  final String title;
  final String author;

  /// Ordered map: chapter title → body HTML (paragraphs / imgs).
  final Map<String, String> chapters;
  final List<int>? coverBytes;
  final String coverExt;
}

Future<File> createNovelEpub(
  NovelEpubData data,
  String cacheDir,
  String outFilePath, [
  Map<String, List<int>> extraImages = const {},
]) async {
  final titleEsc = _xmlEscape(data.title);
  final authorEsc = _xmlEscape(data.author);
  final uuid = const Uuid().v4();

  final entries = <_EpubZipEntry>[
    _EpubZipEntry(
      'mimetype',
      _utf8('application/epub+zip'),
      store: true,
    ),
    _EpubZipEntry(
      'META-INF/container.xml',
      _utf8('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
    ),
  ];

  final manifest = StringBuffer();
  final spine = StringBuffer();
  final navMap = StringBuffer();
  final navLis = StringBuffer();

  var hasCover = false;
  if (data.coverBytes != null && data.coverBytes!.isNotEmpty) {
    final ext = data.coverExt.startsWith('.')
        ? data.coverExt.substring(1)
        : data.coverExt;
    final mime = FileType.fromExtension(ext).mime;
    entries.add(_EpubZipEntry('OEBPS/images/cover.$ext', data.coverBytes!));
    manifest.writeln(
      '        <item id="cover_image" href="images/cover.$ext" media-type="$mime"/>',
    );
    hasCover = true;
  }
  manifest.writeln(
    '        <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
  );
  manifest.writeln(
    '        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
  );

  var extraIdx = 0;
  for (final entry in extraImages.entries) {
    final rel = entry.key.replaceAll('\\', '/');
    final name = rel.contains('/') ? rel.split('/').last : rel;
    entries.add(_EpubZipEntry('OEBPS/images/$name', entry.value));
    final ext = name.contains('.') ? name.split('.').last : 'jpg';
    final mime = FileType.fromExtension(ext).mime;
    manifest.writeln(
      '        <item id="extra$extraIdx" href="images/$name" media-type="$mime"/>',
    );
    extraIdx++;
  }

  var chapterIndex = 0;
  var playOrder = 1;
  for (final entry in data.chapters.entries) {
    final chapterTitle = _xmlEscape(entry.key);
    entries.add(_EpubZipEntry(
      'OEBPS/$chapterIndex.html',
      _utf8('''<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
    "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>$chapterTitle</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
    <style type="text/css">
        body { margin: 1em; line-height: 1.7; }
        p { text-indent: 2em; margin: 0.4em 0; }
        img { max-width: 100%; height: auto; display: block; margin: 1em auto; }
        h1 { font-size: 1.3em; text-align: center; text-indent: 0; }
    </style>
</head>
<body>
    <h1>$chapterTitle</h1>
${entry.value}
</body>
</html>
'''),
    ));
    manifest.writeln(
      '        <item id="chapter$chapterIndex" href="$chapterIndex.html" media-type="application/xhtml+xml"/>',
    );
    spine.writeln('        <itemref idref="chapter$chapterIndex"/>');
    navMap.writeln(
      '        <navPoint id="chapter$chapterIndex" playOrder="$playOrder">',
    );
    navMap.writeln(
      '            <navLabel><text>$chapterTitle</text></navLabel>',
    );
    navMap.writeln('            <content src="$chapterIndex.html"/>');
    navMap.writeln('        </navPoint>');
    navLis.writeln(
      '        <li><a href="$chapterIndex.html">$chapterTitle</a></li>',
    );
    playOrder++;
    chapterIndex++;
  }

  entries.add(_EpubZipEntry(
    'OEBPS/content.opf',
    _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0"
    xmlns="http://www.idpf.org/2007/opf"
    unique-identifier="book_id"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <metadata>
        <dc:title>$titleEsc</dc:title>
        <dc:creator>$authorEsc</dc:creator>
        <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
        <dc:language>zh</dc:language>
${hasCover ? '        <meta name="cover" content="cover_image"/>' : ''}
    </metadata>
    <manifest>
${manifest.toString()}
    </manifest>
    <spine toc="toc">
${spine.toString()}
    </spine>
</package>
'''),
  ));

  entries.add(_EpubZipEntry(
    'OEBPS/nav.xhtml',
    _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>$titleEsc</title><meta charset="utf-8"/></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>$titleEsc</h1>
    <ol>
${navLis.toString()}
    </ol>
  </nav>
</body>
</html>
'''),
  ));

  entries.add(_EpubZipEntry(
    'OEBPS/toc.ncx',
    _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
    <head>
        <meta name="dtb:uid" content="urn:uuid:$uuid"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
    </head>
    <docTitle>
        <text>$titleEsc</text>
    </docTitle>
    <navMap>
${navMap.toString()}
    </navMap>
</ncx>
'''),
  ));

  _writeEpubZip(outFilePath, entries);
  return File(outFilePath);
}

/// Same as [createNovelEpub] with optional chapter illustration bytes.
Future<File> createNovelEpubWithImages(
  NovelEpubData data,
  Map<String, List<int>> images,
  String cacheDir,
  String outFilePath,
) {
  return createNovelEpub(data, cacheDir, outFilePath, images);
}
