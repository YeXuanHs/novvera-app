import 'package:flutter/painting.dart';

/// Ordered chapter content for novel reader (text segments + images).
sealed class NovelBlock {
  const NovelBlock();
}

class NovelTextBlock extends NovelBlock {
  const NovelTextBlock(this.text);
  final String text;
}

class NovelImageBlock extends NovelBlock {
  const NovelImageBlock(this.url);
  final String url;
}

/// One gallery page: either text that fills (or partially fills) the viewport,
/// or a single exclusive image page.
sealed class NovelGalleryPage {
  const NovelGalleryPage();
}

class NovelGalleryTextPage extends NovelGalleryPage {
  const NovelGalleryTextPage(this.text);
  final String text;
}

class NovelGalleryImagePage extends NovelGalleryPage {
  const NovelGalleryImagePage(this.url);
  final String url;
}

/// Parse chapter [content] (lines; http URLs = inline images) into ordered blocks.
List<NovelBlock> parseNovelBlocks(
  String content, {
  List<String> trailingImages = const [],
}) {
  final blocks = <NovelBlock>[];
  final seenImages = <String>{};
  final textBuf = StringBuffer();

  void flushText() {
    final t = textBuf.toString().trimRight();
    textBuf.clear();
    if (t.trim().isEmpty) return;
    blocks.add(NovelTextBlock(t));
  }

  for (final raw in content.split('\n')) {
    final line = raw.trimRight();
    final trimmed = line.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      flushText();
      if (trimmed.isNotEmpty && seenImages.add(trimmed)) {
        blocks.add(NovelImageBlock(trimmed));
      }
      continue;
    }
    if (textBuf.isNotEmpty) textBuf.writeln();
    textBuf.write(line);
  }
  flushText();

  for (final url in trailingImages) {
    if (url.startsWith('http') && seenImages.add(url)) {
      blocks.add(NovelImageBlock(url));
    }
  }

  if (blocks.isEmpty) {
    blocks.add(const NovelTextBlock('（本章无内容）'));
  }
  return blocks;
}

/// Gallery pagination: fill viewport with text; images force end of text page
/// and occupy an exclusive page of their own.
List<NovelGalleryPage> paginateNovelGallery({
  required List<NovelBlock> blocks,
  required Size viewport,
  required TextStyle style,
  EdgeInsets padding = const EdgeInsets.fromLTRB(24, 20, 24, 56),
}) {
  final maxWidth = (viewport.width - padding.horizontal).clamp(80.0, 100000.0);
  final maxHeight = (viewport.height - padding.vertical).clamp(80.0, 100000.0);
  final pages = <NovelGalleryPage>[];
  final buf = StringBuffer();

  double measure(String text) {
    if (text.trim().isEmpty) return 0;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    return tp.height;
  }

  void flushTextPage() {
    final text = buf.toString().trimRight();
    buf.clear();
    if (text.trim().isEmpty) return;
    pages.add(NovelGalleryTextPage(text));
  }

  /// Append [chunk] into the current text page, splitting across pages if needed.
  void appendText(String chunk) {
    if (chunk.isEmpty) return;
    var remaining = chunk;
    while (remaining.isNotEmpty) {
      final current = buf.toString();
      final sep = current.isEmpty || current.endsWith('\n') ? '' : '\n';
      final candidate = '$current$sep$remaining';
      if (measure(candidate) <= maxHeight) {
        if (sep.isNotEmpty) buf.write(sep);
        buf.write(remaining);
        return;
      }
      // Need to split. If buffer has content, flush first then retry.
      if (current.trim().isNotEmpty) {
        flushTextPage();
        continue;
      }
      // Buffer empty but remaining alone is taller than one page — binary split.
      var lo = 1;
      var hi = remaining.length;
      var fit = 1;
      while (lo <= hi) {
        final mid = (lo + hi) ~/ 2;
        if (measure(remaining.substring(0, mid)) <= maxHeight) {
          fit = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      buf.write(remaining.substring(0, fit));
      flushTextPage();
      remaining = remaining.substring(fit);
    }
  }

  for (final block in blocks) {
    if (block is NovelImageBlock) {
      flushTextPage();
      pages.add(NovelGalleryImagePage(block.url));
      continue;
    }
    if (block is NovelTextBlock) {
      appendText(block.text);
    }
  }
  flushTextPage();

  if (pages.isEmpty) {
    pages.add(const NovelGalleryTextPage('（本章无内容）'));
  }
  return pages;
}
