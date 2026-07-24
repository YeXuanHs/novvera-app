part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    var bookSource = BookSource.find(widget.sourceKey);
    var history = HistoryManager().find(
      widget.id,
      BookType.fromKey(widget.sourceKey),
    );
    if (bookSource == null) {
      var localBook = LocalManager().find(
        widget.id,
        BookType.fromKey(widget.sourceKey),
      );
      if (localBook == null) {
        return Res.error("book not found");
      }
      return Res(
        ReaderProps(
          type: BookType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: localBook.title,
          chapters: localBook.chapters,
          history: history ??
              History.fromModel(
                model: localBook,
                ep: 0,
                page: 0,
              ),
          author: localBook.subtitle,
          tags: localBook.tags,
        ),
      );
    } else {
      var book = await bookSource.loadBookInfo!(widget.id);
      if (book.error) {
        return Res.fromErrorRes(book);
      }
      return Res(
        ReaderProps(
          type: BookType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: book.data.title,
          chapters: book.data.chapters,
          history: history ??
              History.fromModel(
                model: book.data,
                ep: 0,
                page: 0,
              ),
          author: book.data.findAuthor() ?? "",
          tags: book.data.plainTags,
        ),
      );
    }
  }
}

class ReaderProps {
  final BookType type;

  final String cid;

  final String name;

  final BookChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}
