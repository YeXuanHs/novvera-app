import 'dart:async';
import 'dart:convert';
import 'package:novvera/foundation/favorites.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/utils/channel.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

Future<ComicUpdateResult> updateBook(
    FavoriteItemWithUpdateInfo c, String folder) async {
  int retries = 3;
  while (true) {
    try {
      var bookSource = c.type.bookSource;
      if (bookSource == null) {
        return ComicUpdateResult(false, "Book source not found");
      }
      var newInfo = (await bookSource.loadBookInfo!(c.id)).data;

      var newTags = <String>[];
      for (var entry in newInfo.tags.entries) {
        const shouldIgnore = ['author', 'artist', 'time'];
        var namespace = entry.key;
        if (shouldIgnore.contains(namespace.toLowerCase())) {
          continue;
        }
        for (var tag in entry.value) {
          newTags.add("$namespace:$tag");
        }
      }

      var item = FavoriteItem(
        id: c.id,
        name: newInfo.title,
        coverPath: newInfo.cover,
        author: newInfo.subTitle ??
            newInfo.tags['author']?.firstOrNull ??
            c.author,
        type: c.type,
        tags: newTags,
      );

      LocalFavoritesManager().updateInfo(folder, item, false);

      var updated = false;
      var updateTime = newInfo.findUpdateTime();
      if (updateTime != null && updateTime != c.updateTime) {
        LocalFavoritesManager().updateUpdateTime(
          folder,
          c.id,
          c.type,
          updateTime,
        );
        updated = true;
      } else {
        LocalFavoritesManager().updateCheckTime(folder, c.id, c.type);
      }
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      Log.error("Check Updates", e, s);
      await Future.delayed(const Duration(seconds: 2));
      retries--;
      if (retries == 0) {
        return ComicUpdateResult(false, e.toString());
      }
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? book;
  final String? errorMessage;

  UpdateProgress(this.total, this.current, this.errors, this.updated,
      [this.book, this.errorMessage]);
}

void updateFolderBase(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime,
) async {
  var books = LocalFavoritesManager().getBooksWithUpdatesInfo(folder);
  int total = books.length;
  int current = 0;
  int errors = 0;
  int updated = 0;

  stream.add(UpdateProgress(total, current, errors, updated));

  var booksToUpdate = <FavoriteItemWithUpdateInfo>[];

  for (var book in books) {
    if (!ignoreCheckTime) {
      var lastCheckTime = book.lastCheckTime;
      if (lastCheckTime != null &&
          DateTime.now().difference(lastCheckTime).inDays < 1) {
        current++;
        stream.add(UpdateProgress(total, current, errors, updated));
        continue;
      }
    }
    booksToUpdate.add(book);
  }

  total = booksToUpdate.length;
  current = 0;
  stream.add(UpdateProgress(total, current, errors, updated));

  var channel = Channel<FavoriteItemWithUpdateInfo>(10);

  // Producer
  () async {
    var c = 0;
    for (var book in booksToUpdate) {
      await channel.push(book);
      c++;
      // Throttle
      if (c % 5 == 0) {
        var delay = c % 100 + 1;
        if (delay > 10) {
          delay = 10;
        }
        await Future.delayed(Duration(seconds: delay));
      }
    }
    channel.close();
  }();

  // Consumers
  var updateFutures = <Future>[];
  for (var i = 0; i < 5; i++) {
    var f = () async {
      while (true) {
        var book = await channel.pop();
        if (book == null) {
          break;
        }
        var result = await updateBook(book, folder);
        current++;
        if (result.updated) {
          updated++;
        }
        if (result.errorMessage != null) {
          errors++;
        }
        stream.add(UpdateProgress(total, current, errors, updated, book, result.errorMessage));
      }
    }();
    updateFutures.add(f);
  }

  await Future.wait(updateFutures);

  if (updated > 0) {
    LocalFavoritesManager().notifyChanges();
  }

  stream.close();
}


Stream<UpdateProgress> updateFolder(String folder, bool ignoreCheckTime) {
  var stream = StreamController<UpdateProgress>();
  updateFolderBase(folder, stream, ignoreCheckTime);
  return stream.stream;
}

Future<String> getUpdatedBooksAsJson(String folder) async {
  var books = LocalFavoritesManager().getBooksWithUpdatesInfo(folder);
  var updatedBooks = books.where((c) => c.hasNewUpdate).toList();
  var jsonList = updatedBooks.map((c) => {
    'id': c.id,
    'name': c.name,
    'coverUrl': c.coverPath,
    'author': c.author,
    'type': c.type.sourceKey,
    'updateTime': c.updateTime,
    'tags': c.tags,
  }).toList();
  return jsonEncode(jsonList);
}
