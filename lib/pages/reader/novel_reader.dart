import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:novvera/components/components.dart';
import 'package:novvera/foundation/comic_source/comic_source.dart';
import 'package:novvera/foundation/comic_type.dart';
import 'package:novvera/foundation/history.dart';
import 'package:novvera/foundation/image_provider/cached_image.dart';
import 'package:novvera/foundation/novel_backend/novel_http.dart';
import 'package:novvera/foundation/novel_source/builtin_sources.dart';
import 'package:novvera/utils/translations.dart';

/// Scrollable text + illustration reader for builtin novel sources.
class NovelReader extends StatefulWidget {
  const NovelReader({
    super.key,
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    this.initialPage,
    this.initialChapter,
    this.initialChapterGroup,
    required this.author,
    required this.tags,
  });

  final ComicType type;
  final String cid;
  final String name;
  final ComicChapters chapters;
  final History history;
  final int? initialPage;
  final int? initialChapter;
  final int? initialChapterGroup;
  final String author;
  final List<String> tags;

  @override
  State<NovelReader> createState() => _NovelReaderState();
}

class _NovelReaderState extends State<NovelReader> {
  late int chapterIndex; // 1-based absolute chapter index
  late ScrollController scrollController;
  String? content;
  List<String> images = [];
  String? chapterTitle;
  bool loading = true;
  String? error;
  bool showChrome = true;

  bool _firstLoad = true;

  History get history => widget.history;

  int get maxChapter => widget.chapters.length;

  String get epId =>
      widget.chapters.ids.elementAtOrNull(chapterIndex - 1) ?? '1-1';

  String get sourceKey => widget.type.sourceKey;

  @override
  void initState() {
    super.initState();
    chapterIndex = widget.initialChapter ?? 1;
    if (chapterIndex < 1) chapterIndex = 1;
    if (widget.initialChapterGroup != null) {
      var c = chapterIndex;
      for (int i = 0; i < (widget.initialChapterGroup! - 1); i++) {
        if (i < widget.chapters.groupCount) {
          c += widget.chapters.getGroupByIndex(i).length;
        }
      }
      chapterIndex = c;
    }
    if (chapterIndex > maxChapter) chapterIndex = maxChapter;
    scrollController = ScrollController();
    scrollController.addListener(_onScroll);
    _loadChapter();
  }

  @override
  void dispose() {
    _saveHistory(force: true);
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!scrollController.hasClients) return;
    _saveHistory();
  }

  void _saveHistory({bool force = false}) {
    final max = scrollController.hasClients
        ? scrollController.position.maxScrollExtent
        : 0.0;
    final offset =
        scrollController.hasClients ? scrollController.offset : 0.0;
    // page stores scroll progress as 1–1000 (1-based style)
    final progress = max <= 0
        ? 1
        : (1 + (offset / max * 999).clamp(0, 999)).round();

    if (widget.chapters.isGrouped) {
      int g = 0;
      int c = chapterIndex;
      while (g < widget.chapters.groupCount &&
          c > widget.chapters.getGroupByIndex(g).length) {
        c -= widget.chapters.getGroupByIndex(g).length;
        g++;
      }
      history.readEpisode.add('${g + 1}-$c');
      history.ep = c;
      history.group = g + 1;
    } else {
      history.readEpisode.add(chapterIndex.toString());
      history.ep = chapterIndex;
    }
    history.page = progress;
    history.maxPage = 1000;
    history.time = DateTime.now();
    if (force) {
      HistoryManager().addHistory(history);
    } else {
      HistoryManager().addHistoryAsync(history);
    }
  }

  Future<void> _loadChapter({int? restoreProgress}) async {
    setState(() {
      loading = true;
      error = null;
      content = null;
      images = [];
    });
    final res = await loadNovelChapter(sourceKey, widget.cid, epId);
    if (!mounted) return;
    if (res.error) {
      setState(() {
        loading = false;
        error = res.errorMessage;
      });
      return;
    }
    final data = res.data;
    final text = (data['content'] ?? '').toString();
    final imgs = (data['images'] as List? ?? [])
        .map((e) => normalizeNovelImageUrl(e.toString()))
        .where((e) => e.startsWith('http'))
        .toList();
    setState(() {
      loading = false;
      content = text;
      images = imgs;
      chapterTitle =
          (data['chapter_title'] ?? widget.chapters[epId] ?? '').toString();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      final progress = restoreProgress ??
          (_firstLoad && history.page > 1 ? history.page : 1);
      _firstLoad = false;
      if (progress > 1 && scrollController.position.maxScrollExtent > 0) {
        final offset =
            ((progress - 1) / 999) * scrollController.position.maxScrollExtent;
        scrollController.jumpTo(offset.clamp(
          0.0,
          scrollController.position.maxScrollExtent,
        ));
      }
    });
    _saveHistory();
  }

  void _prevChapter() {
    if (chapterIndex <= 1) return;
    setState(() => chapterIndex--);
    _loadChapter(restoreProgress: 1);
  }

  void _nextChapter() {
    if (chapterIndex >= maxChapter) return;
    setState(() => chapterIndex++);
    _loadChapter(restoreProgress: 1);
  }

  List<_NovelBlock> _buildBlocks(String text) {
    final blocks = <_NovelBlock>[];
    final seenImages = <String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        blocks.add(const _NovelBlock.spacer());
        continue;
      }
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        final url = normalizeNovelImageUrl(trimmed);
        if (!seenImages.contains(url)) {
          seenImages.add(url);
          blocks.add(_NovelBlock.image(url));
        }
        continue;
      }
      blocks.add(_NovelBlock.text(line));
    }
    for (final url in images) {
      if (!seenImages.contains(url)) {
        blocks.add(_NovelBlock.image(url));
      }
    }
    return blocks;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            if (showChrome) _buildAppBar(theme),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => showChrome = !showChrome),
                child: _buildBody(theme),
              ),
            ),
            if (showChrome) _buildBottomBar(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar(ThemeData theme) {
    return Material(
      elevation: 1,
      color: theme.colorScheme.surfaceContainerLow,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (chapterTitle != null && chapterTitle!.isNotEmpty)
                    Text(
                      chapterTitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            Text(
              '$chapterIndex / $maxChapter',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              TextButton(
                onPressed: chapterIndex > 1 ? _prevChapter : null,
                child: Text('上一章'.tl),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _showChapterPicker(theme),
                child: Text('目录'.tl),
              ),
              const Spacer(),
              TextButton(
                onPressed: chapterIndex < maxChapter ? _nextChapter : null,
                child: Text('下一章'.tl),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showChapterPicker(ThemeData theme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final ids = widget.chapters.ids.toList();
        final titles = widget.chapters.titles.toList();
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: Column(
            children: [
              ListTile(title: Text('目录'.tl)),
              Expanded(
                child: ListView.builder(
                  itemCount: ids.length,
                  itemBuilder: (_, i) {
                    final active = i + 1 == chapterIndex;
                    return ListTile(
                      selected: active,
                      title: Text(titles[i]),
                      subtitle: Text(ids[i]),
                      onTap: () {
                        Navigator.pop(ctx);
                        if (i + 1 != chapterIndex) {
                          setState(() => chapterIndex = i + 1);
                          _loadChapter(restoreProgress: 1);
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return NetworkError(
        message: error!,
        withAppbar: false,
        retry: () => _loadChapter(),
      );
    }
    final blocks = _buildBlocks(content ?? '');
    final width = MediaQuery.of(context).size.width;
    final pad = width > 720 ? (width - 720) / 2 + 24.0 : 20.0;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _prevChapter,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _nextChapter,
      },
      child: Focus(
        autofocus: true,
        child: ListView.builder(
          controller: scrollController,
          padding: EdgeInsets.fromLTRB(pad, 16, pad, 48),
          itemCount: blocks.length,
          itemBuilder: (context, i) {
            final b = blocks[i];
            if (b.isSpacer) {
              return const SizedBox(height: 12);
            }
            if (b.imageUrl != null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: AnimatedImage(
                      image: CachedImageProvider(
                        b.imageUrl!,
                        sourceKey: sourceKey,
                        cid: widget.cid,
                      ),
                      fit: BoxFit.contain,
                      width: double.infinity,
                    ),
                  ),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                b.text!,
                style: theme.textTheme.bodyLarge?.copyWith(
                  height: 1.75,
                  fontSize: 17,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NovelBlock {
  final String? text;
  final String? imageUrl;
  final bool isSpacer;

  const _NovelBlock.text(this.text)
      : imageUrl = null,
        isSpacer = false;

  const _NovelBlock.image(this.imageUrl)
      : text = null,
        isSpacer = false;

  const _NovelBlock.spacer()
      : text = null,
        imageUrl = null,
        isSpacer = true;
}
