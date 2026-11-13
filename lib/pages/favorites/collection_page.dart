import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:novvera/components/components.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/history.dart';
import 'package:novvera/foundation/novel_source/novel_paginator.dart';
import 'package:novvera/pages/image_favorites_page/image_favorites_page.dart';
import 'package:novvera/pages/image_favorites_page/type.dart';
import 'package:novvera/pages/reader/reader.dart';
import 'package:novvera/utils/translations.dart';

/// 收藏页：把「摘录」（划选的文字）和「图片」放在一起，两个 tab。
class CollectionPage extends StatefulWidget {
  const CollectionPage({
    super.key,
    this.initialTab = 0,
    this.initialImageKeyword,
  });

  final int initialTab;

  /// 图片 tab 的初始搜索词（首页标签/作者榜点进来时用）。
  final String? initialImageKeyword;

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab,
  );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Favorites".tl),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: "Excerpts".tl),
            Tab(text: "Images".tl),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const _ExcerptTab(),
          ImageFavoritesPage(
            embedded: true,
            initialKeyword: widget.initialImageKeyword,
          ),
        ],
      ),
    );
  }
}

enum _ExcerptSort {
  timeDesc("Time Desc"),
  timeAsc("Time Asc"),
  title("Title"),
  chapter("Chapter");

  final String label;

  const _ExcerptSort(this.label);

  static _ExcerptSort fromValue(String? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return timeDesc;
  }
}

class _ExcerptTab extends StatefulWidget {
  const _ExcerptTab();

  @override
  State<_ExcerptTab> createState() => _ExcerptTabState();
}

class _ExcerptTabState extends State<_ExcerptTab> {
  final _search = TextEditingController();

  List<Excerpt> items = [];

  bool _searching = false;

  bool _multiSelect = false;

  _ExcerptSort _sort = _ExcerptSort.timeDesc;

  TimeRange _timeFilter = TimeRange.all;

  int _minLength = 0;

  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _sort = _ExcerptSort.fromValue(appdata.implicitData["excerpt_sort"]);
    _timeFilter = TimeRange.fromString(
      appdata.implicitData["excerpt_time_filter"],
    );
    _minLength = appdata.implicitData["excerpt_length_filter"] ?? 0;
    _load();
    ExcerptManager().addListener(_load);
  }

  @override
  void dispose() {
    ExcerptManager().removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    setState(() {
      final matched = ExcerptManager()
          .getAll(keyword: _search.text)
          .where((e) =>
              _timeFilter.contains(e.time) && e.text.length >= _minLength)
          .toList();
      items = _sorted(matched);
      final keys = items.map((e) => e.key).toSet();
      _selected.removeWhere((k) => !keys.contains(k));
    });
  }

  List<Excerpt> _sorted(List<Excerpt> list) => switch (_sort) {
        _ExcerptSort.timeDesc => list, // getAll 本身就是按时间倒序
        _ExcerptSort.timeAsc => list.reversed.toList(),
        _ExcerptSort.title =>
          list..sort((a, b) => a.bookTitle.compareTo(b.bookTitle)),
        _ExcerptSort.chapter => list..sort((a, b) {
            final byBook = a.bookTitle.compareTo(b.bookTitle);
            if (byBook != 0) return byBook;
            if (a.ep != b.ep) return a.ep.compareTo(b.ep);
            return a.blockIndex.compareTo(b.blockIndex);
          }),
      };

  void _openOptions() {
    showDialog(
      context: context,
      builder: (_) => _ExcerptOptionsDialog(
        initSort: _sort,
        initTimeFilter: _timeFilter,
        initMinLength: _minLength,
        updateConfig: (sort, timeRange, minLength) {
          setState(() {
            _sort = sort;
            _timeFilter = timeRange;
            _minLength = minLength;
          });
          _load();
        },
      ),
    );
  }

  void _open(Excerpt e) {
    App.rootContext.to(
      () => ReaderWithLoading(
        id: e.bookId,
        sourceKey: e.sourceKey,
        initialEp: e.ep,
        // 具体位置由 initialCursor 决定；这里给 1 免得沿用别的章节的页码。
        initialPage: 1,
        initialCursor: NovelPageCursor(e.blockIndex, e.charStart),
      ),
    );
  }

  void _copy(Excerpt e) {
    Clipboard.setData(ClipboardData(text: e.text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Excerpt copied".tl),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _delete(Excerpt e) {
    ExcerptManager().remove(e);
  }

  void _toggle(Excerpt e) {
    setState(() {
      if (!_selected.remove(e.key)) _selected.add(e.key);
    });
  }

  void _deleteSelected() {
    final targets = items.where((e) => _selected.contains(e.key)).toList();
    if (targets.isEmpty) return;
    ExcerptManager().removeAll(targets);
    setState(() {
      _selected.clear();
      _multiSelect = false;
    });
  }

  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    const height = 52.0;

    if (_multiSelect) {
      return SizedBox(
        height: height,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Cancel".tl,
              onPressed: () => setState(() {
                _multiSelect = false;
                _selected.clear();
              }),
            ),
            Text('${_selected.length}', style: theme.textTheme.titleMedium),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: "Select All".tl,
              onPressed: () => setState(() {
                _selected
                  ..clear()
                  ..addAll(items.map((e) => e.key));
              }),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "Delete".tl,
              onPressed: _selected.isEmpty ? null : _deleteSelected,
            ),
            const SizedBox(width: 8),
          ],
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Row(
        children: [
          const SizedBox(width: 16),
          if (_searching)
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => _load(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: "Search excerpts, book title, chapter".tl,
                  border: InputBorder.none,
                ),
              ),
            )
          else
            Expanded(
              child: Text(
                "Excerpts".tl,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_searching)
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: "Cancel".tl,
              onPressed: () {
                _search.clear();
                setState(() => _searching = false);
                _load();
              },
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: "Search".tl,
              onPressed: () => setState(() => _searching = true),
            ),
            IconButton(
              isSelected:
                  _timeFilter != TimeRange.all || _minLength > 0,
              tooltip: "Sort".tl,
              icon: const Icon(Icons.sort_rounded),
              onPressed: _openOptions,
            ),
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: "Multi-Select".tl,
              onPressed: () => setState(() => _multiSelect = true),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _buildToolbar(context),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.format_quote,
                        size: 48,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "No excerpts yet".tl,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        "Tap the quote button while reading, then select the text you want to keep"
                            .tl,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      _buildItem(context, items[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildItem(BuildContext context, Excerpt e) {
    final theme = Theme.of(context);
    final date = DateFormat('yyyy-MM-dd HH:mm').format(e.time);
    final source =
        [e.bookTitle, if (e.epName.isNotEmpty) e.epName].join(' · ');
    final checked = _selected.contains(e.key);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (_multiSelect) {
            _toggle(e);
          } else {
            _open(e);
          }
        },
        onLongPress: _multiSelect
            ? null
            : () => setState(() {
                  _multiSelect = true;
                  _selected.add(e.key);
                }),
        child: Padding(
          padding: EdgeInsets.fromLTRB(_multiSelect ? 4 : 16, 14, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_multiSelect)
                // 交给外层 InkWell 统一切换，避免 Checkbox 与 onTap 各触发一次。
                IgnorePointer(
                  child: Checkbox(
                    value: checked,
                    onChanged: (_) {},
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      date,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              if (!_multiSelect)
                PopupMenuButton<String>(
                  tooltip: "More".tl,
                  onSelected: (v) {
                    switch (v) {
                      case 'open':
                        _open(e);
                      case 'copy':
                        _copy(e);
                      case 'delete':
                        _delete(e);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'open', child: Text("Go to text".tl)),
                    PopupMenuItem(value: 'copy', child: Text("Copy".tl)),
                    PopupMenuItem(value: 'delete', child: Text("Delete".tl)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 摘录的排序 / 筛选弹窗——与图片收藏那个保持同一套结构与控件，只换文案。
class _ExcerptOptionsDialog extends StatefulWidget {
  const _ExcerptOptionsDialog({
    required this.initSort,
    required this.initTimeFilter,
    required this.initMinLength,
    required this.updateConfig,
  });

  final _ExcerptSort initSort;
  final TimeRange initTimeFilter;
  final int initMinLength;
  final void Function(_ExcerptSort sort, TimeRange timeRange, int minLength)
      updateConfig;

  @override
  State<_ExcerptOptionsDialog> createState() => _ExcerptOptionsDialogState();
}

class _ExcerptOptionsDialogState extends State<_ExcerptOptionsDialog> {
  static const lengthOptions = [0, 10, 20, 50, 100, 200, 500];

  final List<String> optionTypes = ['Sort', 'Filter'];

  late _ExcerptSort sort = widget.initSort;

  late int minLength = widget.initMinLength;

  late TimeRangeType timeRangeType;

  DateTime? start;

  DateTime? end;

  @override
  void initState() {
    super.initState();
    timeRangeType = switch (widget.initTimeFilter) {
      TimeRange.all => TimeRangeType.all,
      TimeRange.lastWeek => TimeRangeType.lastWeek,
      TimeRange.lastMonth => TimeRangeType.lastMonth,
      TimeRange.lastHalfYear => TimeRangeType.lastHalfYear,
      TimeRange.lastYear => TimeRangeType.lastYear,
      _ => TimeRangeType.custom,
    };
    if (timeRangeType == TimeRangeType.custom) {
      end = widget.initTimeFilter.end;
      start = end!.subtract(widget.initTimeFilter.duration);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabBar = Material(
      borderRadius: BorderRadius.circular(8),
      child: AppTabBar(
        key: PageStorageKey(optionTypes),
        tabs: optionTypes.map((e) => Tab(text: e.tl, key: Key(e))).toList(),
      ),
    ).paddingTop(context.padding.top);

    return ContentDialog(
      content: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tabBar,
            TabViewBody(
              children: [
                RadioGroup<_ExcerptSort>(
                  groupValue: sort,
                  onChanged: (v) {
                    setState(() => sort = v ?? sort);
                  },
                  child: Column(
                    children: _ExcerptSort.values
                        .map(
                          (e) => RadioListTile<_ExcerptSort>(
                            title: Text(e.label.tl),
                            value: e,
                          ),
                        )
                        .toList(),
                  ),
                ),
                Column(
                  children: [
                    ListTile(
                      title: Text("Time Filter".tl),
                      trailing: Select(
                        current: timeRangeType.value.tl,
                        values: TimeRangeType.values
                            .map((e) => e.value.tl)
                            .toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() {
                            timeRangeType = TimeRangeType.values[index];
                          });
                        },
                      ),
                    ),
                    if (timeRangeType == TimeRangeType.custom)
                      Column(
                        children: [
                          ListTile(
                            title: Text("Start Time".tl),
                            trailing: TextButton(
                              onPressed: () async {
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: start ?? DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: end ?? DateTime.now(),
                                );
                                if (date != null) {
                                  setState(() => start = date);
                                }
                              },
                              child: Text(
                                start == null
                                    ? "Select Date".tl
                                    : DateFormat("yyyy-MM-dd").format(start!),
                              ),
                            ),
                          ),
                          ListTile(
                            title: Text("End Time".tl),
                            trailing: TextButton(
                              onPressed: () async {
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: end ?? DateTime.now(),
                                  firstDate: start ?? DateTime(2000),
                                  lastDate: DateTime.now(),
                                );
                                if (date != null) {
                                  setState(() => end = date);
                                }
                              },
                              child: Text(
                                end == null
                                    ? "Select Date".tl
                                    : DateFormat("yyyy-MM-dd").format(end!),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ListTile(
                      title: Text("Text Length Greater Than".tl),
                      trailing: Select(
                        current: minLength.toString(),
                        values:
                            lengthOptions.map((e) => e.toString()).toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() => minLength = lengthOptions[index]);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            appdata.implicitData["excerpt_sort"] = sort.name;
            TimeRange timeRange;
            if (timeRangeType == TimeRangeType.custom) {
              timeRange = TimeRange(
                end: end,
                duration: end!.difference(start!),
              );
            } else {
              timeRange = switch (timeRangeType) {
                TimeRangeType.all => TimeRange.all,
                TimeRangeType.lastWeek => TimeRange.lastWeek,
                TimeRangeType.lastMonth => TimeRange.lastMonth,
                TimeRangeType.lastHalfYear => TimeRange.lastHalfYear,
                TimeRangeType.lastYear => TimeRange.lastYear,
                _ => TimeRange.all,
              };
            }
            appdata.implicitData["excerpt_time_filter"] = timeRange.toString();
            appdata.implicitData["excerpt_length_filter"] = minLength;
            appdata.writeImplicitData();
            if (mounted) {
              Navigator.pop(context);
              widget.updateConfig(sort, timeRange, minLength);
            }
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
