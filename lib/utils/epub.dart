import 'dart:isolate';

import 'package:uuid/uuid.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/utils/file_type.dart';
import 'package:novvera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

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

Future<File> createEpubComic(
    EpubData data, String cacheDir, String outFilePath) async {
  final workingDir = Directory(FilePath.join(cacheDir, 'epub'));
  if (workingDir.existsSync()) {
    workingDir.deleteSync(recursive: true);
  }
  workingDir.createSync(recursive: true);

  // mimetype
  workingDir.joinFile('mimetype').writeAsStringSync('application/epub+zip');

  // META-INF
  Directory(FilePath.join(workingDir.path, 'META-INF')).createSync();
  File(FilePath.join(workingDir.path, 'META-INF', 'container.xml'))
      .writeAsStringSync('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
  ''');

  Directory(FilePath.join(workingDir.path, 'OEBPS')).createSync();

  // copy images, create html files
  final imageDir = Directory(FilePath.join(workingDir.path, 'OEBPS', 'images'));
  imageDir.createSync();
  final coverExt = data.cover.extension;
  final coverMime = FileType.fromExtension(coverExt).mime;
  imageDir
      .joinFile('cover.$coverExt')
      .writeAsBytesSync(data.cover.readAsBytesSync());
  int imgIndex = 0;
  int chapterIndex = 0;
  var manifestStrBuilder = StringBuffer();
  manifestStrBuilder.writeln(
      '        <item id="cover_image" href="OEBPS/images/cover.$coverExt" media-type="$coverMime"/>');
  manifestStrBuilder.writeln(
      '        <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');
  for (final chapter in data.chapters.keys) {
    var images = <String>[];
    for (final image in data.chapters[chapter]!) {
      final ext = image.extension;
      imageDir
          .joinFile('img$imgIndex.$ext')
          .writeAsBytesSync(image.readAsBytesSync());
      images.add('images/img$imgIndex.$ext');
      var mime = FileType.fromExtension(ext).mime;
      manifestStrBuilder.writeln(
          '        <item id="img$imgIndex" href="OEBPS/images/img$imgIndex$ext" media-type="$mime"/>');
      imgIndex++;
    }
    var html =
        File(FilePath.join(workingDir.path, 'OEBPS', '$chapterIndex.html'));
    html.writeAsStringSync('''
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" 
    "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>$chapter</title>
    <style type="text/css">
        img { 
            max-width: 100%;
            height: auto;
        }
        body {
            margin: 0;
            padding: 0;
        }
    </style>
</head>
<body>
    <h1>$chapter</h1>
    <div>
${images.map((e) => '        <img src="$e" alt="$e"/>').join('\n')}
    </div>
</body>
</html>
    ''');
    manifestStrBuilder.writeln(
        '        <item id="chapter$chapterIndex" href="OEBPS/$chapterIndex.html" media-type="application/xhtml+xml"/>');
    chapterIndex++;
  }

  // content.opf
  final contentOpf = File(FilePath.join(workingDir.path, 'content.opf'));
  final uuid = const Uuid().v4();
  var spineStrBuilder = StringBuffer();
  for (var i = 0; i < chapterIndex; i++) {
    var idRef = 'idref="chapter$i"';
    spineStrBuilder.writeln('        <itemref $idRef/>');
  }
  contentOpf.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" 
    xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <metadata>
        <dc:title>${data.title}</dc:title>
        <dc:creator>${data.author}</dc:creator>
        <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
        <meta name="cover" content="cover_image"/>
    </metadata>
    <manifest>
${manifestStrBuilder.toString()}       
    </manifest>
    <spine toc="toc">
${spineStrBuilder.toString()}
    </spine>
</package>
  ''');

  // toc.ncx
  final tocNcx = File(FilePath.join(workingDir.path, 'toc.ncx'));
  var navMapStrBuilder = StringBuffer();
  var playOrder = 2;
  final chapterNames = data.chapters.keys.toList();
  for (var i = 0; i < chapterIndex; i++) {
    navMapStrBuilder
        .writeln('        <navPoint id="chapter$i" playOrder="$playOrder">');
    navMapStrBuilder.writeln(
        '            <navLabel><text>${chapterNames[i]}</text></navLabel>');
    navMapStrBuilder.writeln('            <content src="OEBPS/$i.html"/>');
    navMapStrBuilder.writeln('        </navPoint>');
    playOrder++;
  }

  tocNcx.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
    <head>
        <meta name="dtb:uid" content="urn:uuid:$uuid"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
    </head>
    <docTitle>
        <text>${data.title}</text>
    </docTitle>
    <navMap>
${navMapStrBuilder.toString()}
    </navMap>
</ncx>
  ''');

  ZipFile.compressFolder(workingDir.path, outFilePath);

  workingDir.deleteSync(recursive: true);

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
  final workingDir = Directory(FilePath.join(cacheDir, 'novel_epub'));
  if (workingDir.existsSync()) {
    workingDir.deleteSync(recursive: true);
  }
  workingDir.createSync(recursive: true);

  workingDir.joinFile('mimetype').writeAsStringSync('application/epub+zip');

  Directory(FilePath.join(workingDir.path, 'META-INF')).createSync();
  File(FilePath.join(workingDir.path, 'META-INF', 'container.xml'))
      .writeAsStringSync('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');

  final oebps = Directory(FilePath.join(workingDir.path, 'OEBPS'));
  oebps.createSync();
  final imageDir = Directory(FilePath.join(oebps.path, 'images'));
  imageDir.createSync();

  final titleEsc = _xmlEscape(data.title);
  final authorEsc = _xmlEscape(data.author);
  final uuid = const Uuid().v4();
  final manifest = StringBuffer();
  final spine = StringBuffer();
  final navMap = StringBuffer();

  var hasCover = false;
  if (data.coverBytes != null && data.coverBytes!.isNotEmpty) {
    final ext = data.coverExt.startsWith('.')
        ? data.coverExt.substring(1)
        : data.coverExt;
    final mime = FileType.fromExtension(ext).mime;
    imageDir.joinFile('cover.$ext').writeAsBytesSync(data.coverBytes!);
    manifest.writeln(
      '        <item id="cover_image" href="OEBPS/images/cover.$ext" media-type="$mime"/>',
    );
    hasCover = true;
  }
  manifest.writeln(
    '        <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
  );

  // Chapter illustrations: keys like "images/img0.jpg"
  var extraIdx = 0;
  for (final entry in extraImages.entries) {
    final rel = entry.key.replaceAll('\\', '/');
    final name = rel.contains('/') ? rel.split('/').last : rel;
    final file = imageDir.joinFile(name);
    file.writeAsBytesSync(entry.value);
    final ext = name.contains('.') ? name.split('.').last : 'jpg';
    final mime = FileType.fromExtension(ext).mime;
    manifest.writeln(
      '        <item id="extra$extraIdx" href="OEBPS/images/$name" media-type="$mime"/>',
    );
    extraIdx++;
  }

  var chapterIndex = 0;
  var playOrder = 1;
  for (final entry in data.chapters.entries) {
    final chapterTitle = _xmlEscape(entry.key);
    final html = File(FilePath.join(oebps.path, '$chapterIndex.html'));
    html.writeAsStringSync('''
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
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
''');
    manifest.writeln(
      '        <item id="chapter$chapterIndex" href="OEBPS/$chapterIndex.html" media-type="application/xhtml+xml"/>',
    );
    spine.writeln('        <itemref idref="chapter$chapterIndex"/>');
    navMap.writeln(
      '        <navPoint id="chapter$chapterIndex" playOrder="$playOrder">',
    );
    navMap.writeln(
      '            <navLabel><text>$chapterTitle</text></navLabel>',
    );
    navMap.writeln('            <content src="OEBPS/$chapterIndex.html"/>');
    navMap.writeln('        </navPoint>');
    playOrder++;
    chapterIndex++;
  }

  File(FilePath.join(workingDir.path, 'content.opf')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0"
    xmlns="http://www.idpf.org/2007/opf"
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
''');

  File(FilePath.join(workingDir.path, 'toc.ncx')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
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
''');

  ZipFile.compressFolder(workingDir.path, outFilePath);
  workingDir.deleteSync(recursive: true);
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
