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

/// 文库8 账号：填自己的号优先，失效自动回退注册机账号。
class _Wenku8AccountView extends StatefulWidget {
  const _Wenku8AccountView();

  @override
  State<_Wenku8AccountView> createState() => _Wenku8AccountViewState();
}

class _Wenku8AccountViewState extends State<_Wenku8AccountView> {
  final _user = TextEditingController();
  final _pass = TextEditingController();

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = Wenku8Client.instance;
    _user.text = c.userUsername ?? '';
    _pass.text = c.userPassword ?? '';
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final ok = await Wenku8Client.instance
          .setUserAccount(_user.text.trim(), _pass.text);
      if (!mounted) return;
      final c = Wenku8Client.instance;
      context.showMessage(
        message: ok
            ? (c.usingUserAccount ? "已登录自己的账号".tl : "已回退到自动注册账号".tl)
            : "登录失败".tl,
      );
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    _user.clear();
    _pass.clear();
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final c = Wenku8Client.instance;
    final status = c.usingUserAccount
        ? "当前：自己的账号".tl
        : "当前：自动注册账号".tl;
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("文库8 账号".tl)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status, style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  decoration: InputDecoration(
                    labelText: "用户名".tl,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: "密码".tl,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Text("保存并登录".tl),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _busy ? null : _clear,
                      child: Text("清除".tl),
                    ),
                    if (_busy) ...[
                      const SizedBox(width: 16),
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  "登录自己的账号后优先用它拉书架；只有密码改过/账号不可用时才回退到自动注册的号。".tl,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
  }
}
