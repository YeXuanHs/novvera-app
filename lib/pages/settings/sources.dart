part of 'settings_page.dart';

/// 书源管理：外置 JS 源的启用/导入/删除，以及文库8 账号。
class _BookSourcesView extends StatefulWidget {
  const _BookSourcesView();

  @override
  State<_BookSourcesView> createState() => _BookSourcesViewState();
}

class _BookSourcesViewState extends State<_BookSourcesView> {
  final _js = TextEditingController();

  bool _busy = false;

  @override
  void dispose() {
    _js.dispose();
    super.dispose();
  }

  bool get _enabled => appdata.settings['jsBookSourcesEnabled'] == true;

  bool _isBuiltin(BookSource s) => s.filePath.startsWith('builtin:');

  Future<void> _toggle(bool v) async {
    appdata.settings['jsBookSourcesEnabled'] = v;
    appdata.saveData();
    setState(() {});
    await BookSourceManager().reload();
    if (mounted) setState(() {});
  }

  Future<void> _import() async {
    _js.clear();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text("导入 JS 书源".tl),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: _js,
            maxLines: 12,
            decoration: InputDecoration(
              hintText:
                  'class MySource extends BookSource { ... }'.tl,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text("Cancel".tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text("Confirm".tl),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final js = _js.text.trim();
    if (js.isEmpty) return;
    setState(() => _busy = true);
    try {
      final source = await BookSourceParser().createAndParse(js, 'imported');
      await BookSourceManager().reload();
      if (mounted) {
        context.showMessage(message: "已导入 @name".tlParams({"name": source.name}));
        setState(() {});
      }
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(BookSource source) async {
    try {
      final f = File(source.filePath);
      if (await f.exists()) await f.delete();
      await BookSourceManager().reload();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = BookSource.all();
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("书源".tl)),
        SliverToBoxAdapter(
          child: SwitchListTile(
            title: Text("启用外置 JS 书源".tl),
            subtitle: Text(
              "扫描 <数据目录>/comic_source/*.js".tl,
            ),
            value: _enabled,
            onChanged: _toggle,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.add),
                  label: Text("导入 JS 源".tl),
                ),
                const SizedBox(width: 12),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final s = sources[i];
              final builtin = _isBuiltin(s);
              return ListTile(
                leading: Icon(
                  builtin ? Icons.dns : Icons.extension,
                ),
                title: Text(s.name),
                subtitle: Text("${s.key} · ${builtin ? "内置".tl : "JS".tl}"),
                trailing: builtin
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(s),
                      ),
              );
            },
            childCount: sources.length,
          ),
        ),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
  }
}

