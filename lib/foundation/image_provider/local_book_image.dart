import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:novvera/foundation/local.dart';
import 'package:novvera/utils/io.dart';
import 'base_image_provider.dart';
import 'local_comic_image.dart' as image_provider;

class LocalBookImageProvider
    extends BaseImageProvider<image_provider.LocalBookImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const LocalBookImageProvider(this.book);

  final LocalBook book;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    File? file = book.coverFile;
    if(! await file.exists()) {
      file = null;
      var dir = Directory(book.directory);
      if (! await dir.exists()) {
        throw "Error: Book not found.";
      }
      Directory? firstDir;
      await for (var entity in dir.list()) {
        if(entity is File) {
          if(["jpg", "jpeg", "png", "webp", "gif", "jpe", "jpeg"].contains(entity.extension)) {
            file = entity;
            break;
          }
        } else if(entity is Directory) {
          firstDir ??= entity;
        }
      }
      if(file == null && firstDir != null) {
        await for (var entity in firstDir.list()) {
          if(entity is File) {
            if(["jpg", "jpeg", "png", "webp", "gif", "jpe", "jpeg"].contains(entity.extension)) {
              file = entity;
              break;
            }
          }
        }
      }
    }
    if(file == null) {
      throw "Error: Cover not found.";
    }
    checkStop();
    var data = await file.readAsBytes();
    if(data.isEmpty) {
      throw "Exception: Empty file(${file.path}).";
    }
    return data;
  }

  @override
  Future<LocalBookImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "local${book.id}${book.bookType.value}";
}
