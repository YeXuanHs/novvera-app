import 'package:novvera/foundation/book_source/book_source.dart';

class BookType {
  final int value;

  const BookType(this.value);

  @override
  bool operator ==(Object other) => other is BookType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  String get sourceKey {
    if(this == local) {
      return "local";
    } else {
      return bookSource!.key;
    }
  }

  BookSource? get bookSource {
    if(this == local) {
      return null;
    } else {
      return BookSource.fromIntKey(value);
    }
  }

  static const local = BookType(0);

  factory BookType.fromKey(String key) {
    if(key == "local") {
      return local;
    } else {
      return BookType(key.hashCode);
    }
  }
}