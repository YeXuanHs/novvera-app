part of 'reader.dart';

/// 打开摘录选择器。
///
/// 展示从 [startBlock] 开始的连续原文，用户用系统选择手势划出一段，
/// 再点「摘录选中」保存。之所以不复用阅读器里的文字控件，是因为画廊模式
/// 的文字页被 PhotoView 包着，长按/拖动手势会被缩放层吃掉，选不中。
Future<void> _showExcerptPicker(
  BuildContext context, {
  required _ReaderState reader,
  int? startBlock,
  int maxChars = 4000,
}) {
  return showDialog(
    context: context,
    builder: (_) => _ExcerptPickerDialog(
      reader: reader,
      startBlock: startBlock ?? 0,
      maxChars: maxChars,
    ),
  );
}

class _ExcerptPickerDialog extends StatefulWidget {
  const _ExcerptPickerDialog({
    required this.reader,
    required this.startBlock,
    required this.maxChars,
  });

  final _ReaderState reader;
  final int startBlock;
  final int maxChars;

  @override
  State<_ExcerptPickerDialog> createState() => _ExcerptPickerDialogState();
}

class _ExcerptPickerDialogState extends State<_ExcerptPickerDialog> {
  final _scrollController = ScrollController();

  /// 拼接后的正文。
  String joined = '';

  /// 每个文本段在 [joined] 中的起始偏移。
  final List<int> segStart = [];

  /// 每个文本段对应的 block 下标。
  final List<int> segBlock = [];

  /// 当前选区（SelectableText 回调给出，直接用它，不引入 controller）。
  TextSelection selection = const TextSelection.collapsed(offset: -1);

  @override
  void initState() {
    super.initState();
    _buildText();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _buildText() {
    final all = NovelPageCache.blocks;
    if (all.isEmpty) return;
    final sb = StringBuffer();
    final start = widget.startBlock
        .clamp(0, math.max(0, all.length - 1))
        .toInt();
    for (var i = start; i < all.length; i++) {
      final b = all[i];
      if (b is! NovelTextBlock || b.text.trim().isEmpty) continue;
      if (sb.isNotEmpty) sb.write('\n\n');
      segStart.add(sb.length);
      segBlock.add(i);
      sb.write(b.text.trim());
      if (sb.length >= widget.maxChars) break;
    }
    joined = sb.toString();
  }

  bool get _hasSelection =>
      joined.isNotEmpty &&
      selection.isValid &&
      !selection.isCollapsed &&
      selection.end <= joined.length &&
      selection.start >= 0;

  int get _selectedLength {
    if (!_hasSelection) return 0;
    return selection.end - selection.start;
  }

  /// 找到偏移 [offset] 落在哪个文本段。
  int _segIndexAt(int offset) {
    for (var i = segStart.length - 1; i >= 0; i--) {
      if (offset >= segStart[i]) return i;
    }
    return 0;
  }

  String _chapterName() {
    final chapters = widget.reader.widget.chapters;
    return chapters?.titles.elementAtOrNull(widget.reader.chapter - 1) ?? '';
  }

  void _save({required bool wholeBlock}) {
    if (joined.isEmpty) {
      Navigator.pop(context);
      return;
    }
    var start = 0;
    var end = 0;
    if (wholeBlock) {
      // 整段：优先取选区起点所在段，否则第一段。
      final anchor = _hasSelection ? selection.start : 0;
      final idx = _segIndexAt(anchor);
      start = segStart[idx];
      end = idx + 1 < segStart.length ? segStart[idx + 1] : joined.length;
    } else {
      if (!_hasSelection) {
        context.showMessage(message: "Please select the text to excerpt".tl);
        return;
      }
      start = selection.start;
      end = selection.end;
      if (start > end) {
        final t = start;
        start = end;
        end = t;
      }
    }

    final raw = joined.substring(start, end);
    // 去掉首尾空白，但要把偏移一起挪，否则定位会偏。
    final lead = raw.length - raw.trimLeft().length;
    final text = raw.trim();
    if (text.isEmpty) {
      context.showMessage(message: "Please select the text to excerpt".tl);
      return;
    }
    start += lead;

    final segIdx = _segIndexAt(start);
    final blockIndex = segBlock[segIdx];
    final inBlock = (start - segStart[segIdx]).clamp(0, 1 << 30).toInt();
    final reader = widget.reader;

    final excerpt = Excerpt(
      bookId: reader.cid,
      sourceKey: reader.type.sourceKey,
      bookTitle: reader.widget.name,
      author: reader.widget.author,
      cover: HistoryManager().find(reader.cid, reader.type)?.cover ?? '',
      ep: reader.chapter,
      eid: reader.eid,
      epName: _chapterName(),
      blockIndex: blockIndex,
      charStart: inBlock,
      charEnd: inBlock + text.length,
      text: text,
    );
    ExcerptManager().add(excerpt);
    // 先提示再关窗：pop 之后这个 context 已失效，toast 会挂不上。
    App.rootContext.showMessage(
      message: "Excerpt saved (@count chars)"
          .tlParams({"count": text.length}),
    );
    Navigator.pop(context);
  }

  void _copy() {
    final text = _hasSelection
        ? joined.substring(selection.start, selection.end)
        : joined;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    context.showMessage(message: "Copied".tl);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final height = size.height * (size.width > 720 ? 0.7 : 0.8);
    final width = math.min(640.0, size.width - 48);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.format_quote, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text("Excerpt".tl, style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                joined.isEmpty ? "No text to excerpt in this chapter".tl : "Select the text you want to keep, then tap Excerpt selection".tl,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: SelectableText(
                      joined,
                      onSelectionChanged: (sel, cause) {
                        setState(() => selection = sel);
                      },
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 17,
                        height: 1.75,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                children: [
                  Text(
                    _hasSelection ? "@count chars selected".tlParams({"count": _selectedLength}) : "Nothing selected".tl,
                    style: theme.textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _copy,
                    child: Text("Copy".tl),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: joined.isEmpty
                        ? null
                        : () => _save(wholeBlock: true),
                    child: Text("Excerpt this paragraph".tl),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed:
                        _hasSelection ? () => _save(wholeBlock: false) : null,
                    child: Text("Excerpt selection".tl),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
