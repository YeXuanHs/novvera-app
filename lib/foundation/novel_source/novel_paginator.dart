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

/// Cursor into [NovelBlock] list (MewX-style lineIndex + wordIndex).
class NovelPageCursor {
  const NovelPageCursor(this.blockIndex, [this.charIndex = 0]);

  final int blockIndex;
  final int charIndex;

  static const zero = NovelPageCursor(0, 0);

  @override
  bool operator ==(Object other) =>
      other is NovelPageCursor &&
      other.blockIndex == blockIndex &&
      other.charIndex == charIndex;

  @override
  int get hashCode => Object.hash(blockIndex, charIndex);
}

class _LaidOutPage {
  const _LaidOutPage(this.page, this.next);

  final NovelGalleryPage page;
  final NovelPageCursor next;
}

/// Parse chapter [content] (lines; http URLs = inline images) into ordered blocks.
///
/// Each non-empty text line becomes one [NovelTextBlock] (MewX element model).
List<NovelBlock> parseNovelBlocks(
  String content, {
  List<String> trailingImages = const [],
}) {
  final blocks = <NovelBlock>[];
  final seenImages = <String>{};

  for (final raw in content.split('\n')) {
    final trimmed = raw.trimRight().trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('file://')) {
      if (seenImages.add(trimmed)) {
        blocks.add(NovelImageBlock(trimmed));
      }
      continue;
    }
    blocks.add(NovelTextBlock(trimmed));
  }

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

/// Char-width / height measure for one-page fill layout.
class _NovelMeasure {
  _NovelMeasure({
    required this.style,
    required this.maxWidth,
  }) : strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);

  final TextStyle style;
  final double maxWidth;
  final StrutStyle strut;

  static const heightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: false,
    applyHeightToLastDescent: false,
  );

  double textHeight(String text) {
    if (text.trim().isEmpty) return 0;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      strutStyle: strut,
      textHeightBehavior: heightBehavior,
    )..layout(maxWidth: maxWidth);
    return tp.height;
  }
}

/// Layout a single gallery page starting at [start] (MewX calcFromFirst).
///
/// Images force end of a text page and occupy an exclusive page.
/// Measurement uses the same TextStyle as [_buildNovelTextPage] so page
/// boundaries match Flutter Text rendering.
_LaidOutPage layoutPageForward({
  required List<NovelBlock> blocks,
  required NovelPageCursor start,
  required _NovelMeasure measure,
  required double maxHeight,
}) {
  if (start.blockIndex >= blocks.length) {
    return const _LaidOutPage(
      NovelGalleryTextPage('（本章无内容）'),
      NovelPageCursor(0, 0),
    );
  }

  final first = blocks[start.blockIndex];
  if (first is NovelImageBlock) {
    // Exclusive image page.
    return _LaidOutPage(
      NovelGalleryImagePage(first.url),
      NovelPageCursor(start.blockIndex + 1, 0),
    );
  }

  // Text page: greedily append until height full; stop before next image.
  final buf = StringBuffer();
  var bi = start.blockIndex;
  var ci = start.charIndex;

  String currentText() {
    final b = blocks[bi];
    return b is NovelTextBlock ? b.text : '';
  }

  void advancePastBlock() {
    bi++;
    ci = 0;
  }

  // Skip empty text blocks.
  while (bi < blocks.length) {
    final b = blocks[bi];
    if (b is NovelImageBlock) break;
    if (b is NovelTextBlock && b.text.isNotEmpty && ci < b.text.length) {
      break;
    }
    advancePastBlock();
  }

  if (bi >= blocks.length) {
    return const _LaidOutPage(
      NovelGalleryTextPage('（本章无内容）'),
      NovelPageCursor(0, 0),
    );
  }

  if (blocks[bi] is NovelImageBlock) {
    return _LaidOutPage(
      NovelGalleryImagePage((blocks[bi] as NovelImageBlock).url),
      NovelPageCursor(bi + 1, 0),
    );
  }

  while (bi < blocks.length) {
    final block = blocks[bi];
    if (block is NovelImageBlock) {
      // Image forces end of text page (content already in buf).
      break;
    }
    final text = (block as NovelTextBlock).text;
    if (ci >= text.length) {
      advancePastBlock();
      continue;
    }

    final remaining = text.substring(ci);
    final sep = buf.isEmpty
        ? ''
        : (buf.toString().endsWith('\n') ? '' : '\n\n');
    final candidate = '$buf$sep$remaining';
    if (measure.textHeight(candidate) <= maxHeight) {
      if (sep.isNotEmpty) buf.write(sep);
      buf.write(remaining);
      advancePastBlock();
      continue;
    }

    // Need to split this paragraph (or flush existing and retry).
    if (buf.isNotEmpty && buf.toString().trim().isNotEmpty) {
      // Current page already has content that fits; end page here.
      // Next page starts at (bi, ci).
      break;
    }

    // Buffer empty: binary-fit as much of [remaining] as fits one page.
    var lo = 1;
    var hi = remaining.length;
    var fit = 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (measure.textHeight(remaining.substring(0, mid)) <= maxHeight) {
        fit = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    buf.write(remaining.substring(0, fit));
    ci += fit;
    if (ci >= text.length) {
      advancePastBlock();
    }
    // Page is full after a forced split.
    break;
  }

  final pageText = buf.toString().trimRight();
  if (pageText.isEmpty) {
    // Safety: avoid infinite empty pages.
    if (bi < blocks.length && blocks[bi] is NovelImageBlock) {
      return _LaidOutPage(
        NovelGalleryImagePage((blocks[bi] as NovelImageBlock).url),
        NovelPageCursor(bi + 1, 0),
      );
    }
    return _LaidOutPage(
      const NovelGalleryTextPage('（本章无内容）'),
      NovelPageCursor(blocks.length, 0),
    );
  }

  return _LaidOutPage(
    NovelGalleryTextPage(pageText),
    NovelPageCursor(bi, ci),
  );
}

/// Lazy gallery pager: lays out **one screen at a time** (no full-chapter split).
///
/// Call [ensureThrough] as the user advances; only then are later pages built.
class NovelIncrementalPager {
  NovelIncrementalPager({
    required List<NovelBlock> blocks,
    required Size viewport,
    required TextStyle style,
    EdgeInsets padding = const EdgeInsets.fromLTRB(24, 20, 24, 88),
  })  : _blocks = List<NovelBlock>.from(blocks),
        _measure = _NovelMeasure(
          style: style,
          maxWidth: (viewport.width - padding.horizontal).clamp(80.0, 100000.0),
        ),
        _maxHeight =
            (viewport.height - padding.vertical).clamp(80.0, 100000.0) {
    _starts.add(NovelPageCursor.zero);
  }

  final List<NovelBlock> _blocks;
  final _NovelMeasure _measure;
  final double _maxHeight;

  final List<NovelPageCursor> _starts = [];
  final List<NovelGalleryPage> _pages = [];
  bool _complete = false;

  int get pageCount => _pages.length;

  bool get isComplete => _complete;

  NovelPageCursor? startOf(int pageIndex) =>
      pageIndex >= 0 && pageIndex < _starts.length ? _starts[pageIndex] : null;

  NovelGalleryPage? pageAt(int index) =>
      index >= 0 && index < _pages.length ? _pages[index] : null;

  List<NovelGalleryPage> get pages => List.unmodifiable(_pages);

  bool _isAtEnd(NovelPageCursor c) => c.blockIndex >= _blocks.length;

  /// Ensure pages `0..indexInclusive` exist (or chapter ends sooner).
  void ensureThrough(int indexInclusive) {
    if (_blocks.isEmpty) {
      if (_pages.isEmpty) {
        _pages.add(const NovelGalleryTextPage('（本章无内容）'));
        _complete = true;
      }
      return;
    }
    while (!_complete && _pages.length <= indexInclusive) {
      _layoutNext();
    }
  }

  /// Layout until chapter end (only when jumping to last page).
  void ensureAll() {
    ensureThrough(1 << 20);
  }

  void _layoutNext() {
    final start = _starts[_pages.length];
    if (_isAtEnd(start)) {
      _complete = true;
      if (_pages.isEmpty) {
        _pages.add(const NovelGalleryTextPage('（本章无内容）'));
      }
      return;
    }

    final laid = layoutPageForward(
      blocks: _blocks,
      start: start,
      measure: _measure,
      maxHeight: _maxHeight,
    );

    // Guard against zero-advance loops.
    if (laid.next == start && !_isAtEnd(laid.next)) {
      _pages.add(laid.page);
      _starts.add(NovelPageCursor(start.blockIndex + 1, 0));
    } else {
      _pages.add(laid.page);
      _starts.add(laid.next);
    }

    if (_isAtEnd(_starts.last)) {
      _complete = true;
    }
  }
}

/// Full-chapter pagination (tests / fallback). Prefer [NovelIncrementalPager].
List<NovelGalleryPage> paginateNovelGallery({
  required List<NovelBlock> blocks,
  required Size viewport,
  required TextStyle style,
  EdgeInsets padding = const EdgeInsets.fromLTRB(24, 20, 24, 88),
}) {
  final pager = NovelIncrementalPager(
    blocks: blocks,
    viewport: viewport,
    style: style,
    padding: padding,
  );
  pager.ensureAll();
  return pager.pages;
}
