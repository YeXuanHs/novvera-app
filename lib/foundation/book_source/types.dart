part of 'book_source.dart';

/// build book list, [Res.subData] should be maxPage or null if there is no limit.
typedef BookListBuilder = Future<Res<List<Book>>> Function(int page);

/// build book list with next param, [Res.subData] should be next page param or null if there is no next page.
typedef BookListBuilderWithNext =
    Future<Res<List<Book>>> Function(String? next);

typedef LoginFunction = Future<Res<bool>> Function(String, String);

typedef LoadBookFunc = Future<Res<BookDetails>> Function(String id);

typedef LoadBookPagesFunc =
    Future<Res<List<String>>> Function(String id, String? ep);

typedef CommentsLoader =
    Future<Res<List<Comment>>> Function(
      String id,
      String? subId,
      int page,
      String? replyTo,
    );

typedef ChapterCommentsLoader =
    Future<Res<List<Comment>>> Function(
      String bookId,
      String epId,
      int page,
      String? replyTo,
    );

typedef SendCommentFunc =
    Future<Res<bool>> Function(
      String id,
      String? subId,
      String content,
      String? replyTo,
    );

typedef SendChapterCommentFunc =
    Future<Res<bool>> Function(
      String bookId,
      String epId,
      String content,
      String? replyTo,
    );

typedef GetImageLoadingConfigFunc =
    Future<Map<String, dynamic>> Function(
      String imageKey,
      String bookId,
      String epId,
    )?;
typedef GetThumbnailLoadingConfigFunc =
    Map<String, dynamic> Function(String imageKey)?;

typedef BookThumbnailLoader =
    Future<Res<List<String>>> Function(String bookId, String? next);

typedef LikeOrUnlikeBookFunc =
    Future<Res<bool>> Function(String bookId, bool isLiking);

/// [isLiking] is true if the user is liking the comment, false if unliking.
/// return the new likes count or null.
typedef LikeCommentFunc =
    Future<Res<int?>> Function(
      String bookId,
      String? subId,
      String commentId,
      bool isLiking,
    );

/// [isUp] is true if the user is upvoting the comment, false if downvoting.
/// return the new vote count or null.
typedef VoteCommentFunc =
    Future<Res<int?>> Function(
      String bookId,
      String? subId,
      String commentId,
      bool isUp,
      bool isCancel,
    );

typedef HandleClickTagEvent =
    PageJumpTarget? Function(String namespace, String tag);

/// Handle tag suggestion selection event. Should return the text to insert
/// into the search field.
typedef TagSuggestionSelectFunc = String Function(String namespace, String tag);

/// [rating] is the rating value, 0-10. 1 represents 0.5 star.
typedef StarRatingFunc = Future<Res<bool>> Function(String bookId, int rating);
