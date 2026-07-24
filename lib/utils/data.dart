import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/book_source/book_source.dart';
import 'package:novvera/foundation/book_type.dart';
import 'package:novvera/foundation/favorites.dart';
import 'package:novvera/foundation/history.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/network/cookie_jar.dart';
import 'package:novvera/utils/ext.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'io.dart';

Future<File> exportAppData([bool sync = true]) async {
  var time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.novvera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  await Isolate.run(() {
    var zipFile = ZipFile.open(cacheFilePath);
    var historyFile = FilePath.join(dataPath, "history.db");
    var localFavoriteFile = FilePath.join(dataPath, "local_favorite.db");
    var appdata = FilePath.join(dataPath, sync ? "syncdata.json" : "appdata.json");
    var cookies = FilePath.join(dataPath, "cookie.db");
    zipFile.addFile("history.db", historyFile);
    zipFile.addFile("local_favorite.db", localFavoriteFile);
    zipFile.addFile("appdata.json", appdata);
    zipFile.addFile("cookie.db", cookies);
    for (var file
        in Directory(FilePath.join(dataPath, "book_source")).listSync()) {
      if (file is File) {
        zipFile.addFile("book_source/${file.name}", file.path);
      }
    }
    zipFile.close();
  });
  return cacheFile;
}

Future<void> importAppData(File file, [bool checkVersion = false]) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
    var historyFile = cacheDir.joinFile("history.db");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    var appdataFile = cacheDir.joinFile("appdata.json");
    var cookieFile = cacheDir.joinFile("cookie.db");
    if (checkVersion && appdataFile.existsSync()) {
      var data = jsonDecode(await appdataFile.readAsString());
      var version = data["settings"]["dataVersion"];
      if (version is int && version <= appdata.settings["dataVersion"]) {
        return;
      }
    }
    if (await historyFile.exists()) {
      HistoryManager().close();
      File(FilePath.join(App.dataPath, "history.db")).deleteIfExistsSync();
      historyFile.renameSync(FilePath.join(App.dataPath, "history.db"));
      HistoryManager().init();
    }
    if (await localFavoriteFile.exists()) {
      LocalFavoritesManager().close();
      File(FilePath.join(App.dataPath, "local_favorite.db"))
          .deleteIfExistsSync();
      localFavoriteFile
          .renameSync(FilePath.join(App.dataPath, "local_favorite.db"));
      LocalFavoritesManager().init();
    }
    if (await appdataFile.exists()) {
      var content = await appdataFile.readAsString();
      var data = jsonDecode(content);
      appdata.syncData(data);
    }
    if (await cookieFile.exists()) {
      SingleInstanceCookieJar.instance?.dispose();
      File(FilePath.join(App.dataPath, "cookie.db")).deleteIfExistsSync();
      cookieFile.renameSync(FilePath.join(App.dataPath, "cookie.db"));
      SingleInstanceCookieJar.instance =
          SingleInstanceCookieJar(FilePath.join(App.dataPath, "cookie.db"))
            ..init();
    }
    var bookSourceDir = FilePath.join(cacheDirPath, "book_source");
    if (Directory(bookSourceDir).existsSync()) {
      Directory(FilePath.join(App.dataPath, "book_source"))
          .deleteIfExistsSync(recursive: true);
      Directory(FilePath.join(App.dataPath, "book_source")).createSync();
      for (var file in Directory(bookSourceDir).listSync()) {
        if (file is File) {
          var targetFile =
              FilePath.join(App.dataPath, "book_source", file.name);
          await file.copy(targetFile);
        }
      }
      await BookSourceManager().reload();
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}

Future<void> importPicaData(File file) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    if (localFavoriteFile.existsSync()) {
      var db = sqlite3.open(localFavoriteFile.path);
      try {
        var folderNames = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((e) => e["name"] as String)
            .toList();
        folderNames
            .removeWhere((e) => e == "folder_order" || e == "folder_sync");
        for (var folderSyncValue in db.select("SELECT * FROM folder_sync;")) {
          var folderName = folderSyncValue["folder_name"];
          String sourceKey = folderSyncValue["key"];
          sourceKey =
              sourceKey.toLowerCase() == "htmanga" ? "wnacg" : sourceKey;
          // 有值就跳过
          if (LocalFavoritesManager().findLinked(folderName).$1 != null) {
            continue;
          }
          try {
            LocalFavoritesManager().linkFolderToNetwork(folderName, sourceKey,
                jsonDecode(folderSyncValue["sync_data"])["folderId"]);
          } catch (e, stack) {
            Log.error(e.toString(), stack);
          }
        }
        for (var folderName in folderNames) {
          if (!LocalFavoritesManager().existsFolder(folderName)) {
            LocalFavoritesManager().createFolder(folderName);
          }
          for (var book in db.select("SELECT * FROM \"$folderName\";")) {
            LocalFavoritesManager().addBook(
              folderName,
              FavoriteItem(
                id: book['target'],
                name: book['name'],
                coverPath: book['cover_path'],
                author: book['author'],
                type: BookType(switch (book['type']) {
                  0 => 'picacg'.hashCode,
                  1 => 'ehentai'.hashCode,
                  2 => 'jm'.hashCode,
                  3 => 'hitomi'.hashCode,
                  4 => 'wnacg'.hashCode,
                  6 => 'nhentai'.hashCode,
                  _ => book['type']
                }),
                tags: book['tags'].split(','),
              ),
            );
          }
        }
      } catch (e) {
        Log.error("Import Data", "Failed to import local favorite: $e");
      } finally {
        db.dispose();
      }
    }
    var historyFile = cacheDir.joinFile("history.db");
    if (historyFile.existsSync()) {
      var db = sqlite3.open(historyFile.path);
      try {
        for (var book in db.select("SELECT * FROM history;")) {
          HistoryManager().addHistory(
            History.fromMap({
              "type": switch (book['type']) {
                0 => 'picacg'.hashCode,
                1 => 'ehentai'.hashCode,
                2 => 'jm'.hashCode,
                3 => 'hitomi'.hashCode,
                4 => 'wnacg'.hashCode,
                5 => 'nhentai'.hashCode,
                _ => book['type']
              },
              "id": book['target'],
              "max_page": book["max_page"],
              "ep": book["ep"],
              "page": book["page"],
              "time": book["time"],
              "title": book["title"],
              "subtitle": book["subtitle"],
              "cover": book["cover"],
              "readEpisode": [book["ep"]],
            }),
          );
        }
        List<ImageFavoritesComic> imageFavoritesBookList =
            ImageFavoriteManager().books;
        for (var book in db.select("SELECT * FROM image_favorites;")) {
          String sourceKey = book["id"].split("-")[0];
          // 换名字了, 绅士漫画
          if (sourceKey.toLowerCase() == "htmanga") {
            sourceKey = "wnacg";
          }
          if (BookSource.find(sourceKey) == null) {
            continue;
          }
          String id = book["id"].split("-")[1];
          int page = book["page"];
          // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
          int ep = book["ep"] == 0 ? 1 : book["ep"];
          String title = book["title"];
          String epName = "";
          ImageFavoritesComic? tempBook = imageFavoritesBookList
              .firstWhereOrNull((e) => e.id == id && e.sourceKey == sourceKey);
          ImageFavorite curImageFavorite =
              ImageFavorite(page, "", null, "", id, ep, sourceKey, epName);
          if (tempBook == null) {
            tempBook = ImageFavoritesComic(id, [], title, sourceKey, [], [],
                DateTime.now(), "", {}, "", 1);
            tempBook.imageFavoritesEp = [
              ImageFavoritesEp("", ep, [curImageFavorite], epName, 1)
            ];
            imageFavoritesBookList.add(tempBook);
          } else {
            ImageFavoritesEp? tempEp =
                tempBook.imageFavoritesEp.firstWhereOrNull((e) => e.ep == ep);
            if (tempEp == null) {
              tempBook.imageFavoritesEp
                  .add(ImageFavoritesEp("", ep, [curImageFavorite], epName, 1));
            } else {
              // 如果已经有这个page了, 就不添加了
              if (tempEp.imageFavorites
                      .firstWhereOrNull((e) => e.page == page) ==
                  null) {
                tempEp.imageFavorites.add(curImageFavorite);
              }
            }
          }
        }
        for (var temp in imageFavoritesBookList) {
          ImageFavoriteManager().addOrUpdateOrDelete(
            temp,
            temp == imageFavoritesBookList.last,
          );
        }
      } catch (e, stack) {
        Log.error("Import Data", "Failed to import history: $e", stack);
      } finally {
        db.dispose();
      }
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
