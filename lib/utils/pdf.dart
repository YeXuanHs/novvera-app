import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/utils/image.dart';
import 'package:novvera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

typedef DecodeImage = Future<Image> Function(Uint8List data);

Future<void> _createPdfFromBook({
  required LocalBook book,
  required String savePath,
  required String localPath,
  required DecodeImage decodeImage,
}) async {
  var images = <String>[];

  var baseDir = book.directory.contains('/') || book.directory.contains('\\')
      ? book.directory
      : FilePath.join(localPath, book.directory);

  // add cover
  images.add(FilePath.join(baseDir, book.cover));

  bool multiChapters = book.chapters != null;

  void reorderFiles(List<FileSystemEntity> files) {
    files.removeWhere(
        (element) => element is! File || element.path.startsWith('cover'));
    files.sort((a, b) {
      var aName = (a as File).basenameWithoutExt;
      var bName = (b as File).basenameWithoutExt;
      var aNumber = int.tryParse(aName);
      var bNumber = int.tryParse(bName);
      if (aNumber != null && bNumber != null) {
        return aNumber.compareTo(bNumber);
      }
      return a.name.compareTo(b.name);
    });
  }

  if (!multiChapters) {
    var files = Directory(baseDir).listSync();
    reorderFiles(files);

    for (var file in files) {
      images.add(file.path);
    }
  } else {
    for (var chapter in book.downloadedChapters) {
      var files = Directory(FilePath.join(baseDir, chapter)).listSync();
      reorderFiles(files);
      for (var file in files) {
        images.add(file.path);
      }
    }
  }

  var generator = PdfGenerator(
    title: book.title,
    author: book.subtitle,
    imagePaths: images,
    outputPath: savePath,
    decodeImage: decodeImage,
  );
  await generator.generate();
}

Future<Isolate> _runIsolate(
    LocalBook book, String savePath, SendPort sendPort) {
  var localPath = LocalManager().path;
  return Isolate.spawn<SendPort>(
    (sendPort) => overrideIO(
      () async {
        if (App.isAndroid) {
          await SAFTaskWorker().init();
        }
        var receivePort = ReceivePort();
        sendPort.send(receivePort.sendPort);

        Completer<Image>? completer;

        Future<Image> decodeImage(Uint8List data) async {
          if (completer != null) {
            throw Exception('Another image is being decoded');
          }
          sendPort.send(data);
          completer = Completer();
          return completer!.future;
        }

        receivePort.listen((message) {
          if (message is Image) {
            if (completer == null) {
              throw Exception('No image is being decoded');
            }
            completer!.complete(message);
            completer = null;
          }
        });

        await _createPdfFromBook(
          book: book,
          savePath: savePath,
          localPath: localPath,
          decodeImage: decodeImage,
        );

        sendPort.send(null);
      },
    ),
    sendPort,
  );
}

Future<File> createPdfFromBookIsolate(LocalBook book, String savePath) async {
  var receivePort = ReceivePort();
  SendPort? sendPort;
  Isolate? isolate;
  var completer = Completer<void>();
  receivePort.listen((message) {
    if (message is SendPort) {
      sendPort = message;
    } else if (message is Uint8List) {
      Image.decodeImage(message).then((image) {
        sendPort!.send(image);
      });
    } else if (message == null) {
      receivePort.close();
      completer.complete();
      isolate!.kill();
    }
  });
  isolate = await _runIsolate(book, savePath, receivePort.sendPort);
  await completer.future;
  return File(savePath);
}

class PdfGenerator {
  final String title;
  final String author;
  final List<String> imagePaths;
  final String outputPath;
  final DecodeImage decodeImage;

  // PDF文件的对象ID计数器
  int _objectId = 1;

  // 存储每个对象在PDF中的字节位置
  final Map<int, int> _objectOffsets = {};

  static const double a4Width = 595.0; // points
  static const double a4Height = 842.0; // points

  PdfGenerator({
    required this.title,
    required this.author,
    required this.imagePaths,
    required this.outputPath,
    required this.decodeImage,
  });

  Future<void> generate() async {
    var file = File(outputPath);
    final output = file.openWrite();

    int length = 0;

    void write(String str) {
      var data = utf8.encode(str);
      output.add(data);
      length += data.length;
    }

    void writeData(Uint8List data) {
      output.add(data);
      length += data.length;
    }

    int getCurrentLength() {
      return length;
    }

    // 1. 写入PDF头部
    write('%PDF-1.7\n%\xFF\xFF\xFF\xFF\n\n');

    // 2. 写入Catalog对象
    _objectOffsets[_objectId] = getCurrentLength();
    write('$_objectId 0 obj\n');
    write('<<\n');
    write('/Type /Catalog\n');
    write('/Pages ${_objectId + 1} 0 R\n');
    write('>>\nendobj\n\n');

    final catalogId = _objectId++;

    // 3. 写入Pages对象
    _objectOffsets[_objectId] = getCurrentLength();
    write('$_objectId 0 obj\n');
    write('<<\n');
    write('/Type /Pages\n');
    write('/Kids [');
    final pageIds = <int>[];
    for (var i = 0; i < imagePaths.length; i++) {
      pageIds.add(_objectId + 1 + i * 3);
      write('${_objectId + 1 + i * 3} 0 R ');
    }
    write(']\n');
    write('/Count ${imagePaths.length}\n');
    write('>>\nendobj\n\n');

    final pagesId = _objectId++;

    // 4. 为每个图片创建Page和Image对象
    for (var i = 0; i < imagePaths.length; i++) {
      final imagePath = imagePaths[i];
      final image = await _getImage(imagePath);

      // 写入Page对象
      _objectOffsets[_objectId] = getCurrentLength();
      write('$_objectId 0 obj\n');
      write('<<\n');
      write('/Type /Page\n');
      write('/Parent $pagesId 0 R\n');
      write('/Resources <<\n');
      write('/XObject << /Im${i + 1} ${_objectId + 1} 0 R >>\n');
      write('>>\n');
      write('/MediaBox [0 0 $a4Width $a4Height]\n');
      write('/Contents ${_objectId + 2} 0 R\n');
      write('>>\nendobj\n\n');

      _objectId++;

      // 写入Image对象
      _objectOffsets[_objectId] = getCurrentLength();
      write('$_objectId 0 obj\n');
      write('<<\n');
      write('/Type /XObject\n');
      write('/Subtype /Image\n');
      write('/Width ${image.width}\n');
      write('/Height ${image.height}\n');
      write('/ColorSpace /DeviceRGB\n');
      write('/BitsPerComponent 8\n');
      write('/Filter /FlateDecode\n');
      write('/Length ${image.data.length}\n');
      write('>>\nstream\n');
      writeData(image.data);
      write('\nendstream\nendobj\n\n');

      _objectId++;

      // 写入Contents对象（绘制图片的指令）
      _objectOffsets[_objectId] = getCurrentLength();
      write('$_objectId 0 obj\n');
      write('<<\n');
      var stream = '';
      stream += 'q\n';
      // Calculate scaling factors
      var scaleX = a4Width / image.width;
      var scaleY = a4Height / image.height;
      var scale = scaleX < scaleY ? scaleX : scaleY;
      // Calculate centering offsets
      var offsetX = (a4Width - (image.width * scale)) / 2;
      var offsetY = (a4Height - (image.height * scale)) / 2;
      // Apply transformation matrix
      stream += '1 0 0 1 $offsetX $offsetY cm\n'; // Translate
      stream += '${scale * image.width} 0 0 ${scale * image.height} 0 0 cm\n';
      stream += '/Im${i + 1} Do\n';
      stream += 'Q\n';
      var streamData = utf8.encode(stream);
      write('/Length ${streamData.length}\n');
      write('>>\nstream\n');
      writeData(streamData);
      write('endstream\nendobj\n\n');

      _objectId++;
    }

    // 5. 写入Info对象（元数据）
    final infoId = _objectId;
    _objectOffsets[_objectId] = getCurrentLength();
    write('$_objectId 0 obj\n');
    write('<<\n');
    write('/Title <');
    writeData(_toPdfString(title));
    write('>\n');
    write('/Author <');
    writeData(_toPdfString(author));
    write('>\n');
    write('/Producer (novvera v${App.version})\n');
    write('/CreationDate (D:${_formatDateTime(DateTime.now())})\n');
    write('>>\nendobj\n\n');

    _objectId++;

    // 6. 写入交叉引用表
    final xrefOffset = getCurrentLength();
    write('xref\n');
    write('0 $_objectId\n');
    write('0000000000 65535 f\r\n');

    for (var i = 1; i < _objectId; i++) {
      final offset = _objectOffsets[i]!;
      write('${offset.toString().padLeft(10, '0')} 00000 n\r\n'); // 使用\r\n
    }

    // 7. 写入文件尾部
    write('trailer\n');
    write('<<\n');
    write('/Size $_objectId\n');
    write('/Root $catalogId 0 R\n');
    write('/Info $infoId 0 R\n');
    write('>>\n');
    write('startxref\n');
    write('$xrefOffset\n');
    write('%%EOF\n');

    await output.close();
  }

  int _codeUnitForDigit(int digit) =>
      digit < 10 ? digit + 0x30 : digit + 0x61 - 10;

  Uint8List _toPdfString(String str) {
    Uint8List data;
    try {
      data = latin1.encode(str);
    } catch (e) {
      data = Uint8List.fromList(<int>[0xfe, 0xff] + _encodeUtf16be(str));
    }
    var result = <int>[];
    for (final byte in data) {
      result.add(_codeUnitForDigit((byte & 0xF0) >> 4));
      result.add(_codeUnitForDigit(byte & 0x0F));
    }
    return Uint8List.fromList(result);
  }

  List<int> _encodeUtf16be(String str) {
    const unicodeReplacementCharacterCodePoint = 0xfffd;
    const unicodeByteZeroMask = 0xff;
    const unicodeByteOneMask = 0xff00;
    const unicodeValidRangeMax = 0x10ffff;
    const unicodePlaneOneMax = 0xffff;
    const unicodeUtf16ReservedLo = 0xd800;
    const unicodeUtf16ReservedHi = 0xdfff;
    const unicodeUtf16Offset = 0x10000;
    const unicodeUtf16SurrogateUnit0Base = 0xd800;
    const unicodeUtf16SurrogateUnit1Base = 0xdc00;
    const unicodeUtf16HiMask = 0xffc00;
    const unicodeUtf16LoMask = 0x3ff;

    final encoding = <int>[];

    void add(int unit) {
      encoding.add((unit & unicodeByteOneMask) >> 8);
      encoding.add(unit & unicodeByteZeroMask);
    }

    for (final unit in str.codeUnits) {
      if ((unit >= 0 && unit < unicodeUtf16ReservedLo) ||
          (unit > unicodeUtf16ReservedHi && unit <= unicodePlaneOneMax)) {
        add(unit);
      } else if (unit > unicodePlaneOneMax && unit <= unicodeValidRangeMax) {
        final base = unit - unicodeUtf16Offset;
        add(unicodeUtf16SurrogateUnit0Base +
            ((base & unicodeUtf16HiMask) >> 10));
        add(unicodeUtf16SurrogateUnit1Base + (base & unicodeUtf16LoMask));
      } else {
        add(unicodeReplacementCharacterCodePoint);
      }
    }
    return encoding;
  }

  // 格式化日期时间
  String _formatDateTime(DateTime dt) {
    return dt
        .toUtc()
        .toString()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll(' ', '')
        .replaceAll('.', '')
        .substring(0, 14);
  }

  Future<({int width, int height, Uint8List data})> _getImage(
      String imagePath) async {
    var data = await File(imagePath).readAsBytes();
    var image = await decodeImage(data);
    var width = image.width;
    var height = image.height;
    data = Uint8List(width * height * 3);
    for (var i = 0; i < width * height; i++) {
      var pixel = image.getPixelAtIndex(i);
      data[i * 3] = pixel.r;
      data[i * 3 + 1] = pixel.g;
      data[i * 3 + 2] = pixel.b;
    }
    data = tdeflCompressData(data, true, true, 9);
    return (width: width, height: height, data: data);
  }
}

// ---------------------------------------------------------------------------
// Novel PDF generation (flow-based: text + images mixed)
// ---------------------------------------------------------------------------

/// Export a whole offline novel as a single PDF.
Future<File> createNovelPdfFromLocalBook(
  LocalBook book,
  String outFilePath,
) async {
  if (!book.hasChapters) {
    throw StateError('Not a chaptered novel');
  }
  final generator = NovelPdfGenerator(
    title: book.title,
    author: book.subtitle,
    outputPath: outFilePath,
    decodeImage: Image.decodeImage,
  );
  generator.startDocument();

  for (final chapId in book.downloadedChapters) {
    final chapDirName = LocalManager.getChapterDirectoryName(chapId);
    final chapDir = Directory(FilePath.join(book.baseDir, chapDirName));
    final jsonFile = File(FilePath.join(chapDir.path, 'chapter.json'));
    if (!jsonFile.existsSync()) continue;
    final map = jsonDecode(jsonFile.readAsStringSync()) as Map;
    final title =
        (map['title'] ?? book.chapters?[chapId] ?? chapId).toString();
    final content = (map['content'] ?? '').toString();
    await generator.addChapter(title, content, chapDir);
  }

  await generator.finish();
  return File(outFilePath);
}

/// Export a single chapter as a standalone PDF file.
Future<File> createNovelPdfChapter({
  required String title,
  required String content,
  required Directory chapterDir,
  required String outputPath,
}) async {
  final generator = NovelPdfGenerator(
    title: title,
    author: '',
    outputPath: outputPath,
    decodeImage: Image.decodeImage,
  );
  generator.startDocument();
  await generator.addChapter(title, content, chapterDir);
  await generator.finish();
  return File(outputPath);
}

/// Flow-based PDF generator for novels.
///
/// Supports:
/// - Pure text paragraphs
/// - Pure image pages (illustrations)
/// - Mixed text + image content
class NovelPdfGenerator {
  final String title;
  final String author;
  final String outputPath;
  final DecodeImage decodeImage;

  static const double _pageW = 595.0;
  static const double _pageH = 842.0;
  static const double _margin = 50.0;
  static const double _contentW = _pageW - _margin * 2;
  static const double _lineHeight = 20.0;
  static const double _fontSize = 12.0;
  static const double _titleFontSize = 18.0;
  static const double _titleLineHeight = 28.0;
  static const double _paragraphSpacing = 8.0;
  static const double _imageSpacing = 12.0;

  final List<_PdfPage> _pages = [];
  _PdfPage? _currentPage;

  int _objectId = 0;
  final Map<int, int> _objectOffsets = {};
  int _totalLength = 0;
  late IOSink _output;

  NovelPdfGenerator({
    required this.title,
    required this.author,
    required this.outputPath,
    required this.decodeImage,
  });

  void startDocument() {
    _output = File(outputPath).openWrite();
    _newPage();
  }

  void _newPage() {
    _currentPage = _PdfPage();
    _pages.add(_currentPage!);
  }

  void _ensurePage() {
    _currentPage ??= _PdfPage();
  }

  void _write(String str) {
    var data = utf8.encode(str);
    _output.add(data);
    _totalLength += data.length;
  }

  void _writeBytes(List<int> data) {
    _output.add(data);
    _totalLength += data.length;
  }

  /// Resolve a content line to a local image file path, or null.
  String? _resolveImagePath(String line, Directory chapDir) {
    if (line.startsWith('file://')) return line.substring(7);
    // Bare filename like "img0.jpg" stored by download logic
    if (!line.startsWith('http://') && !line.startsWith('https://')) {
      final f = File(FilePath.join(chapDir.path, line));
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Add a chapter's content to the PDF.
  Future<void> addChapter(
      String chapterTitle, String content, Directory chapDir) async {
    // Chapter title
    _addTitle(chapterTitle);

    final lines = content.split('\n');
    for (final raw in lines) {
      final t = raw.trim();
      if (t.isEmpty) {
        _advanceY(_paragraphSpacing);
        continue;
      }
      final localPath = _resolveImagePath(t, chapDir);
      if (localPath != null) {
        await _addLocalImage(localPath, chapDir);
      } else if (t.startsWith('http://') || t.startsWith('https://')) {
        _addText('[image: $t]');
      } else {
        _addText(t);
      }
    }

    // Page break between chapters
    _currentPage = null;
  }

  void _addTitle(String text) {
    _ensurePage();
    final page = _currentPage!;
    if (page.y + _titleLineHeight > _pageH - _margin) {
      _newPage();
    }
    page.elements.add(_PdfTextElement(
      text: text,
      x: _margin,
      y: _pageH - page.y - _titleFontSize,
      fontSize: _titleFontSize,
      isTitle: true,
    ));
    page.y += _titleLineHeight + _paragraphSpacing;
  }

  void _addText(String text) {
    _ensurePage();
    // Simple line wrapping: split by character count
    // For CJK, each character is roughly the same width
    final charsPerLine = (_contentW / (_fontSize * 0.55)).floor();
    final lines = <String>[];
    var remaining = text;
    while (remaining.isNotEmpty) {
      if (remaining.length <= charsPerLine) {
        lines.add(remaining);
        break;
      }
      lines.add(remaining.substring(0, charsPerLine));
      remaining = remaining.substring(charsPerLine);
    }
    for (final line in lines) {
      _ensurePage();
      final page = _currentPage!;
      if (page.y + _lineHeight > _pageH - _margin) {
        _newPage();
      }
      final p = _currentPage!;
      p.elements.add(_PdfTextElement(
        text: line,
        x: _margin,
        y: _pageH - p.y - _fontSize,
        fontSize: _fontSize,
        isTitle: false,
      ));
      p.y += _lineHeight;
    }
    _advanceY(_paragraphSpacing);
  }

  Future<void> _addLocalImage(String path, Directory chapDir) async {
    File? file;
    if (File(path).existsSync()) {
      file = File(path);
    } else {
      final inChap = File(FilePath.join(chapDir.path, path));
      if (inChap.existsSync()) file = inChap;
    }
    if (file == null) return;

    try {
      final bytes = await file.readAsBytes();
      final image = await decodeImage(bytes);
      final imgW = image.width.toDouble();
      final imgH = image.height.toDouble();

      // Scale to fit content area
      final scaleW = _contentW / imgW;
      final scaleH = (_pageH - _margin * 2) / imgH;
      final scale = scaleW < scaleH ? scaleW : scaleH;
      final drawW = imgW * scale;
      final drawH = imgH * scale;

      _ensurePage();
      if (_currentPage!.y + drawH + _imageSpacing > _pageH - _margin) {
        _newPage();
      }

      // Raw RGB data
      final rgbData = Uint8List(imgW.toInt() * imgH.toInt() * 3);
      for (var i = 0; i < imgW.toInt() * imgH.toInt(); i++) {
        final pixel = image.getPixelAtIndex(i);
        rgbData[i * 3] = pixel.r;
        rgbData[i * 3 + 1] = pixel.g;
        rgbData[i * 3 + 2] = pixel.b;
      }
      final compressed = tdeflCompressData(rgbData, true, true, 9);

      final page = _currentPage!;
      page.elements.add(_PdfImageElement(
        x: _margin,
        y: _pageH - page.y - drawH,
        drawW: drawW,
        drawH: drawH,
        imgW: imgW.toInt(),
        imgH: imgH.toInt(),
        compressedData: compressed,
      ));
      page.y += drawH + _imageSpacing;
    } catch (e) {
      _addText('[image error: $path]');
    }
  }

  void _advanceY(double amount) {
    _ensurePage();
    _currentPage!.y += amount;
  }

  /// Write the final PDF document.
  Future<void> finish() async {
    // Write header
    _write('%PDF-1.7\n%\xFF\xFF\xFF\xFF\n\n');

    // Catalog
    _objectOffsets[++_objectId] = _totalLength;
    _write('$_objectId 0 obj\n<<\n/Type /Catalog\n/Pages ${_objectId + 1} 0 R\n>>\nendobj\n\n');
    final catalogId = _objectId;

    // Pages
    _objectOffsets[++_objectId] = _totalLength;
    _write('$_objectId 0 obj\n<<\n/Type /Pages\n/Kids [');
    var nextObjId = _objectId + 1;
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      final imgCount = page.elements.whereType<_PdfImageElement>().length;
      _write('$nextObjId 0 R ');
      nextObjId += 2 + imgCount + 1; // page + font(4 objs shared) + images + content
    }
    _write(']\n/Count ${_pages.length}\n>>\nendobj\n\n');
    final pagesId = _objectId;

    // Shared CIDFont objects (STSong-Light for CJK)
    final fontType0Id = ++_objectId;
    final fontCidId = ++_objectId;
    final fontDescId = ++_objectId;
    final cMapId = ++_objectId;

    // Type0 font
    _objectOffsets[fontType0Id] = _totalLength;
    _write('$fontType0Id 0 obj\n<<\n/Type /Font\n/Subtype /Type0\n'
        '/BaseFont /STSong-Light\n/Encoding /UniGB-UCS2-H\n'
        '/DescendantFonts [$fontCidId 0 R]\n/ToUnicode $cMapId 0 R\n>>\nendobj\n\n');

    // CIDFont descendant
    _objectOffsets[fontCidId] = _totalLength;
    _write('$fontCidId 0 obj\n<<\n/Type /Font\n/Subtype /CIDFontType2\n'
        '/BaseFont /STSong-Light\n'
        '/CIDSystemInfo <<\n/Registry (Adobe)\n/Ordering (GB1)\n/Supplement 2\n>>\n'
        '/FontDescriptor $fontDescId 0 R\n/Widths ['
        ' 250 333 408 500 500 833 778 333 333 333 500 570 250 333 250 278'
        ' 500 500 500 500 500 500 500 500 500 500 278 278 570 570 570 500'
        ' 833 722 722 722 722 667 611 778 722 278 556 722 611 833 722 778'
        ' 667 778 722 667 611 722 667 944 667 667 611 333 278 333 570 500'
        ' 333 500 500 444 500 444 278 500 500 278 278 444 278 778 500 500'
        ' 500 500 333 389 278 500 500 722 500 500 444 480 200 480 541 350'
        ' 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
        ' 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
        ' 250 333 500 500 500 500 200 500 333 760 276 500 570 333 760 500'
        ' 400 570 300 300 333 500 523 250 333 300 310 500 750 750 750 500'
        ' 722 722 722 722 722 722 722 570 722 722 722 722 722 667 667 500'
        ' 500 500 500 500 500 500 722 444 444 444 444 444 278 278 278 278'
        ' 500 500 500 500 500 500 500 570 500 500 500 500 500 500 500 500'
        ']\n>>\nendobj\n\n');

    // Font descriptor
    _objectOffsets[fontDescId] = _totalLength;
    _write('$fontDescId 0 obj\n<<\n/Type /FontDescriptor\n/FontName /STSong-Light\n'
        '/Flags 34\n/FontBBox [-171 -249 1073 1054]\n/ItalicAngle 0\n'
        '/Ascent 859\n/Descent -141\n/CapHeight 700\n/StemV 58\n'
        '/AvgWidth 500\n/MaxWidth 1000\n/Leading 0\n'
        '>>\nendobj\n\n');

    // ToUnicode CMap
    final cMapContent = StringBuffer()
      ..write('2 dict begin\n')
      ..write('begincmap\n')
      ..write('/CMapName /UniGB-UCS2-H def\n')
      ..write('/CMapType 2 def\n')
      ..write('/CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >> def\n')
      ..write('1 begincodespacerange\n')
      ..write('<0000> <FFFF>\n')
      ..write('endcodespacerange\n')
      ..write('endcmap\n')
      ..write('CMapName currentdict /CMap defineresource pop\n')
      ..write('end\n');
    final cMapBytes = utf8.encode(cMapContent.toString());
    _objectOffsets[cMapId] = _totalLength;
    _write('$cMapId 0 obj\n<<\n/Length ${cMapBytes.length}\n>>\nstream\n');
    _writeBytes(cMapBytes);
    _write('\nendstream\nendobj\n\n');

    // Per-page objects
    for (var pi = 0; pi < _pages.length; pi++) {
      final page = _pages[pi];
      final imgElements = page.elements.whereType<_PdfImageElement>().toList();

      // Page object
      _objectOffsets[++_objectId] = _totalLength;
      final pageObjId = _objectId;
      _write('$_objectId 0 obj\n<<\n/Type /Page\n/Parent $pagesId 0 R\n');
      _write('/Resources <<\n');
      _write('/Font << /F1 $fontType0Id 0 R >>\n');
      if (imgElements.isNotEmpty) {
        _write('/XObject <<');
        for (var ii = 0; ii < imgElements.length; ii++) {
          _write(' /Im${ii + 1} ${_objectId + 1 + ii} 0 R');
        }
        _write(' >>\n');
      }
      _write('>>\n');
      _write('/MediaBox [0 0 $_pageW $_pageH]\n');
      _write('/Contents ${_objectId + 1 + imgElements.length} 0 R\n');
      _write('>>\nendobj\n\n');

      // Image XObjects
      for (final img in imgElements) {
        _objectOffsets[++_objectId] = _totalLength;
        _write('$_objectId 0 obj\n<<\n/Type /XObject\n/Subtype /Image\n');
        _write('/Width ${img.imgW}\n/Height ${img.imgH}\n');
        _write('/ColorSpace /DeviceRGB\n/BitsPerComponent 8\n');
        _write('/Filter /FlateDecode\n/Length ${img.compressedData.length}\n');
        _write('>>\nstream\n');
        _writeBytes(img.compressedData);
        _write('\nendstream\nendobj\n\n');
      }

      // Content stream
      _objectOffsets[++_objectId] = _totalLength;
      final contentStream = StringBuffer();
      contentStream.writeln('BT');
      int imgIdx = 0;
      for (final elem in page.elements) {
        if (elem is _PdfTextElement) {
          contentStream.writeln('/F1 ${elem.fontSize} Tf');
          contentStream.writeln('1 0 0 1 ${elem.x} ${elem.y} Tm');
          contentStream.writeln('<${_toHexUtf16be(elem.text)}> Tj');
        } else if (elem is _PdfImageElement) {
          contentStream.writeln('ET');
          contentStream.writeln('q');
          contentStream.writeln(
              '${elem.drawW} 0 0 ${elem.drawH} ${elem.x} ${elem.y} cm');
          contentStream.writeln('/Im${imgIdx + 1} Do');
          contentStream.writeln('Q');
          contentStream.writeln('BT');
          imgIdx++;
        }
      }
      contentStream.writeln('ET');
      final streamBytes = utf8.encode(contentStream.toString());
      _write('$_objectId 0 obj\n<<\n/Length ${streamBytes.length}\n>>\nstream\n');
      _writeBytes(streamBytes);
      _write('\nendstream\nendobj\n\n');
    }

    // Info object
    final infoId = ++_objectId;
    _objectOffsets[infoId] = _totalLength;
    _write('$infoId 0 obj\n<<\n');
    _write('/Title (${_escapePdfString(title)})\n');
    _write('/Author (${_escapePdfString(author)})\n');
    _write('/Producer (novvera v${App.version})\n');
    _write('>>\nendobj\n\n');

    // Xref
    final xrefOffset = _totalLength;
    final xrefCount = _objectId + 1; // includes free entry at index 0
    _write('xref\n0 $xrefCount\n');
    _write('0000000000 65535 f\r\n');
    for (var i = 1; i <= _objectId; i++) {
      _write('${(_objectOffsets[i]!).toString().padLeft(10, '0')} 00000 n\r\n');
    }
    _write('trailer\n<<\n/Size $xrefCount\n/Root $catalogId 0 R\n/Info $infoId 0 R\n>>\n');
    _write('startxref\n$xrefOffset\n%%EOF\n');

    await _output.flush();
    await _output.close();
  }

  /// Encode a string as hex UTF-16BE for PDF CIDFont text operators.
  static String _toHexUtf16be(String s) {
    final buf = StringBuffer();
    for (final unit in s.runes) {
      if (unit <= 0xFFFF) {
        buf.write(unit.toRadixString(16).padLeft(4, '0'));
      } else {
        // Surrogate pair
        final base = unit - 0x10000;
        final hi = 0xD800 + ((base & 0xFFC00) >> 10);
        final lo = 0xDC00 + (base & 0x3FF);
        buf.write(hi.toRadixString(16).padLeft(4, '0'));
        buf.write(lo.toRadixString(16).padLeft(4, '0'));
      }
    }
    return buf.toString().toUpperCase();
  }

  static String _escapePdfString(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('(', '\\(')
        .replaceAll(')', '\\)')
        .replaceAll('\r', '\\r')
        .replaceAll('\n', '\\n');
  }
}

abstract class _PdfPageElement {
  final double x;
  final double y;
  const _PdfPageElement({required this.x, required this.y});
}

class _PdfTextElement extends _PdfPageElement {
  final String text;
  final double fontSize;
  final bool isTitle;
  const _PdfTextElement({
    required super.x,
    required super.y,
    required this.text,
    required this.fontSize,
    required this.isTitle,
  });
}

class _PdfImageElement extends _PdfPageElement {
  final double drawW;
  final double drawH;
  final int imgW;
  final int imgH;
  final Uint8List compressedData;
  const _PdfImageElement({
    required super.x,
    required super.y,
    required this.drawW,
    required this.drawH,
    required this.imgW,
    required this.imgH,
    required this.compressedData,
  });
}

class _PdfPage {
  double y = 0;
  final List<_PdfPageElement> elements = [];
}
