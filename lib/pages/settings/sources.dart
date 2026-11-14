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

  /// 源仓库索引（venera 同款 index.json），按需下载，不内置 js 文件。
  List<Map<String, dynamic>> _store = [];

  bool _storeBusy = false;

  String get _storeUrl =>
      (appdata.settings['bookSourceListUrl'] ?? '').toString();

  Future<void> _loadStore() async {
    if (_storeUrl.isEmpty) {
      context.showMessage(message: "请先设置源仓库地址".tl);
      return;
    }
    setState(() => _storeBusy = true);
    try {
      final res = await Dio().get(_storeUrl,
          options: Options(responseType: ResponseType.json));
      final data = res.data;
      final list = <Map<String, dynamic>>[];
      void collect(dynamic raw) {
        if (raw is List) {
          for (final e in raw) {
            if (e is Map) list.add(Map<String, dynamic>.from(e));
          }
        } else if (raw is Map) {
          for (final key in ['sources', 'data', 'items', 'list']) {
            if (raw[key] is List) collect(raw[key]);
          }
          if (raw['url'] != null && raw['name'] != null) {
            list.add(Map<String, dynamic>.from(raw));
          }
        }
      }

      collect(data);
      if (mounted) setState(() => _store = list);
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      if (mounted) setState(() => _storeBusy = false);
    }
  }

  Future<void> _install(Map<String, dynamic> entry) async {
    final url = (entry['url'] ?? '').toString();
    if (url.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await Dio().get(url,
          options: Options(responseType: ResponseType.plain));
      final js = res.data.toString();
      final key = (entry['key'] ?? entry['name'] ?? 'source').toString();
      final dir = Directory("${App.dataPath}/comic_source");
      if (!await dir.exists()) await dir.create(recursive: true);
      await File("${dir.path}/$key.js").writeAsString(js);
      await BookSourceManager().reload();
      if (mounted) {
        context.showMessage(message: "已安装 $key".tl);
        setState(() {});
      }
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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

  Future<void> _login(BookSource source) async {
    final user = TextEditingController(text: "${source.data['account']?[0] ?? ''}");
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text("${source.name} · ${"登录".tl}"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: user,
              decoration: InputDecoration(
                labelText: "用户名".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pass,
              obscureText: true,
              decoration: InputDecoration(
                labelText: "密码".tl,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
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
    setState(() => _busy = true);
    try {
      final login = source.account?.login;
      if (login == null) return;
      final res = await login(user.text.trim(), pass.text);
      if (!res.error) {
        source.data['account'] = [user.text.trim(), pass.text];
        await source.saveData();
        if (mounted) {
          context.showMessage(message: "登录成功".tl);
          setState(() {});
        }
      } else if (mounted) {
        context.showMessage(message: res.errorMessage ?? "登录失败".tl);
      }
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout(BookSource source) async {
    source.data.remove('account');
    await source.saveData();
    if (mounted) setState(() {});
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
          child: ListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: Text("源仓库".tl),
            subtitle: Text(
              _storeUrl.isEmpty ? "未设置仓库地址".tl : _storeUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: TextButton(
              onPressed: _storeBusy ? null : _loadStore,
              child: Text(_storeBusy ? "...".tl : "检查更新".tl),
            ),
          ),
        ),
        if (_store.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final e = _store[i];
                final key = (e['key'] ?? e['name'] ?? '').toString();
                final installed =
                    BookSource.find(key) != null;
                return ListTile(
                  dense: true,
                  title: Text("${e['name'] ?? key}"),
                  subtitle: Text(key),
                  trailing: TextButton(
                    onPressed: _busy || installed
                        ? null
                        : () => _install(e),
                    child: Text(installed ? "已安装".tl : "安装".tl),
                  ),
                );
              },
              childCount: _store.length,
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
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.account != null)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => s.isLogged ? _logout(s) : _login(s),
                        child: Text(s.isLogged ? "退出登录".tl : "登录".tl),
                      ),
                    if (!builtin)
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(s),
                      ),
                  ],
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

