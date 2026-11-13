import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/history.dart';
import 'package:novvera/foundation/novel_source/novel_paginator.dart';
import 'package:novvera/pages/image_favorites_page/image_favorites_page.dart';
import 'package:novvera/pages/reader/reader.dart';

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
        title: const Text('收藏'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '摘录'),
            Tab(text: '图片'),
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

class _ExcerptTab extends StatefulWidget {
  const _ExcerptTab();

  @override
  State<_ExcerptTab> createState() => _ExcerptTabState();
}

class _ExcerptTabState extends State<_ExcerptTab> {
  final _search = TextEditingController();

  List<Excerpt> items = [];

  @override
  void initState() {
    super.initState();
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
      items = ExcerptManager().getAll(keyword: _search.text);
    });
  }

  void _open(Excerpt e) {
    App.rootContext.to(
      () => ReaderWithLoading(
        id: e.bookId,
        sourceKey: e.sourceKey,
        initialEp: e.ep,
        initialCursor: NovelPageCursor(e.blockIndex, e.charStart),
      ),
    );
  }

  void _copy(Excerpt e) {
    Clipboard.setData(ClipboardData(text: e.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制摘录'), duration: Duration(seconds: 1)),
    );
  }

  void _delete(Excerpt e) {
    ExcerptManager().remove(e);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _search,
            onChanged: (_) => _load(),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索摘录、书名、章节',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _search.clear();
                        _load();
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
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
                        '还没有摘录',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '阅读时点左下角的「摘录」，划选一段文字即可保存',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
    final source = [
      e.bookTitle,
      if (e.epName.isNotEmpty) e.epName,
    ].where((s) => s.isNotEmpty).join(' · ');

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(e),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              PopupMenuButton<String>(
                tooltip: '更多',
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
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'open', child: Text('跳到原文')),
                  PopupMenuItem(value: 'copy', child: Text('复制')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
