part of "history.dart";

/// 一段被摘录下来的原文。
///
/// 与 [ImageFavorite]（按图片页码收藏）不同，摘录是**文字 + 位置锚点**：
/// 记录选中文字落在哪个 [NovelBlock]、段内起止偏移，所以无论字号、视口、
/// 阅读模式怎么变，都能精确跳回原文那一行。
class Excerpt {
  Excerpt({
    required this.bookId,
    required this.sourceKey,
    required this.bookTitle,
    required this.author,
    required this.cover,
    required this.ep,
    required this.eid,
    required this.epName,
    required this.blockIndex,
    required this.charStart,
    required this.charEnd,
    required this.text,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  /// 书籍 id（与 History.id 一致）。
  final String bookId;

  /// 书籍来源 key（与 History.sourceKey / BookType.sourceKey 一致）。
  final String sourceKey;

  final String bookTitle;

  final String author;

  final String cover;

  /// 章节序号，1 基。
  final int ep;

  final String eid;

  final String epName;

  /// 摘录所在文本块的序号（0 基），与阅读器顶行锚点同一坐标系。
  final int blockIndex;

  /// 选中范围在该文本块内的起始字符下标。
  final int charStart;

  /// 选中范围结束字符下标（不含）。
  final int charEnd;

  /// 摘录正文快照。原文后续变动时依然可读。
  final String text;

  final DateTime time;

  bool get hasRange => charEnd > charStart;

  /// 唯一标识：同一本书、同一章节、同一块、同一起点视为同一条。
  String get key => '$bookId@$sourceKey@$ep@$blockIndex@$charStart';

  Map<String, dynamic> toMap() {
    return {
      'book_id': bookId,
      'source_key': sourceKey,
      'book_title': bookTitle,
      'author': author,
      'cover': cover,
      'ep': ep,
      'eid': eid,
      'ep_name': epName,
      'block_index': blockIndex,
      'char_start': charStart,
      'char_end': charEnd,
      'text': text,
      'time': time.millisecondsSinceEpoch,
    };
  }

  Excerpt.fromMap(Map<String, dynamic> map)
      : bookId = map['book_id'],
        sourceKey = map['source_key'],
        bookTitle = map['book_title'] ?? '',
        author = map['author'] ?? '',
        cover = map['cover'] ?? '',
        ep = map['ep'] ?? 1,
        eid = map['eid'] ?? '',
        epName = map['ep_name'] ?? '',
        blockIndex = map['block_index'] ?? 0,
        charStart = map['char_start'] ?? 0,
        charEnd = map['char_end'] ?? 0,
        text = map['text'] ?? '',
        time = DateTime.fromMillisecondsSinceEpoch(map['time'] ?? 0);

  @override
  bool operator ==(Object other) =>
      other is Excerpt && other.key == key && other.time == time;

  @override
  int get hashCode => Object.hash(key, time);

  @override
  String toString() => 'Excerpt($bookTitle EP$ep @$blockIndex:${charStart}-$charEnd)';
}

/// 摘录库：SQLite 表 `excerpts`，一本书一条记录对应一段摘录。
class ExcerptManager with ChangeNotifier {
  Database get _db => HistoryManager()._db;

  static ExcerptManager? _cache;

  ExcerptManager._();

  factory ExcerptManager() => (_cache ??= ExcerptManager._());

  static const _table = 'excerpts';

  void init() {
    _db.execute("""
      CREATE TABLE IF NOT EXISTS $_table (
        book_id TEXT NOT NULL,
        source_key TEXT NOT NULL,
        book_title TEXT,
        author TEXT,
        cover TEXT,
        ep INTEGER NOT NULL,
        eid TEXT,
        ep_name TEXT,
        block_index INTEGER NOT NULL,
        char_start INTEGER NOT NULL DEFAULT 0,
        char_end INTEGER NOT NULL DEFAULT 0,
        text TEXT NOT NULL,
        time INTEGER NOT NULL,
        PRIMARY KEY (book_id, source_key, ep, block_index, char_start)
      );
    """);
  }

  static const _insertSql = """
    insert or replace into $_table (
      book_id, source_key, book_title, author, cover, ep, eid, ep_name,
      block_index, char_start, char_end, text, time
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
  """;

  /// 写入一条摘录；同一位置重复摘录会覆盖旧内容（保留最新文本与时间）。
  void add(Excerpt excerpt, [bool notify = true]) {
    if (excerpt.text.trim().isEmpty) return;
    _db.execute(_insertSql, [
      excerpt.bookId,
      excerpt.sourceKey,
      excerpt.bookTitle,
      excerpt.author,
      excerpt.cover,
      excerpt.ep,
      excerpt.eid,
      excerpt.epName,
      excerpt.blockIndex,
      excerpt.charStart,
      excerpt.charEnd,
      excerpt.text,
      excerpt.time.millisecondsSinceEpoch,
    ]);
    if (notify) notifyListeners();
  }

  void remove(Excerpt excerpt, [bool notify = true]) {
    _db.execute("""
      delete from $_table
      where book_id == ? and source_key == ? and ep == ?
        and block_index == ? and char_start == ?;
    """, [
      excerpt.bookId,
      excerpt.sourceKey,
      excerpt.ep,
      excerpt.blockIndex,
      excerpt.charStart,
    ]);
    if (notify) notifyListeners();
  }

  void removeAll(Iterable<Excerpt> list) {
    if (list.isEmpty) return;
    for (final e in list) {
      remove(e, false);
    }
    notifyListeners();
  }

  /// 是否已经在同一位置摘录过。
  bool has(String bookId, String sourceKey, int ep, int blockIndex, int charStart) {
    final res = _db.select("""
      select 1 from $_table
      where book_id == ? and source_key == ? and ep == ?
        and block_index == ? and char_start == ? limit 1;
    """, [bookId, sourceKey, ep, blockIndex, charStart]);
    return res.isNotEmpty;
  }

  List<Excerpt> getAll({String? keyword}) {
    ResultSet res;
    final k = keyword?.trim() ?? '';
    if (k.isEmpty) {
      res = _db.select("select * from $_table order by time desc;");
    } else {
      res = _db.select("""
        select * from $_table
        where text like ? or book_title like ? or ep_name like ? or author like ?
        order by time desc;
      """, ['%$k%', '%$k%', '%$k%', '%$k%']);
    }
    try {
      return res.map((row) => Excerpt.fromMap(row)).toList();
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
      return [];
    }
  }

  /// 同一本书的摘录，按章节 + 位置排序（用于书内查看）。
  List<Excerpt> getByBook(String bookId, String sourceKey) {
    final res = _db.select("""
      select * from $_table
      where book_id == ? and source_key == ?
      order by ep asc, block_index asc, char_start asc;
    """, [bookId, sourceKey]);
    try {
      return res.map((row) => Excerpt.fromMap(row)).toList();
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
      return [];
    }
  }

  int get count {
    final res = _db.select("select count(*) from $_table;");
    return res.first.values.first! as int;
  }

  /// 涉及的书数（首页卡片展示用）。
  int get bookCount {
    final res = _db.select("select count(distinct book_id) from $_table;");
    return res.first.values.first! as int;
  }
}
