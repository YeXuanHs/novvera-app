import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:novvera/utils/data_sync.dart';
import 'package:novvera/foundation/book_source/book_source.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/pages/book_source_page.dart';
import 'package:novvera/init.dart';
import 'package:novvera/foundation/follow_updates.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/favorites.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if(Platform.isLinux || Platform.isMacOS){
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({'status': 'error', 'message': 'No command provided for headless mode.'});
    exit(1);
  }

  // Need to initialize the app for some features to work
  await init();

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length) ? args[commandIndex + 1] : null;

  switch (command) {
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        await DataSync().uploadData();
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({'status': 'running', 'message': 'Downloading WebDAV data...'});
        await DataSync().downloadData();
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid webdav command. Use "up" or "down".'});
        exit(1);
      }
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({'status': 'running', 'message': 'Checking for book source script updates...'});
        await BookSourcePage.checkBookSourceUpdate();
        var updates = BookSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all book source scripts...',
            'data': {
              'total': total,
              'current': 0,
              'updated': 0,
              'errors': 0,
            }
          });
          for (var key in updates.keys) {
            var source = BookSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                }
              };
              try {
                await BookSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {
                    ...data,
                    'error': e.toString(),
                  },
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {
              'total': total,
              'updated': updated,
              'errors': errors,
            }
          });
        }
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid updatescript command. Use "all".'});
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({'status': 'running', 'message': 'Updating subscribed books...'});
      var folder = appdata.settings["followUpdatesFolder"];
      if (folder == null) {
        cliPrint({'status': 'error', 'message': 'Follow updates folder is not configured.'});
        exit(1);
      }

      var updateIndex = args.indexOf('--update-book-by-id-type');
      if (updateIndex != -1) {
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var books = LocalFavoritesManager().getBooksWithUpdatesInfo(folder);
        var book = books.firstWhere((c) => c.id == id && c.type.sourceKey == type);
        
        var result = await updateBook(book, folder);
        
        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'book': {
            'id': book.id,
            'name': book.name,
            'coverUrl': book.coverPath,
            'author': book.author,
            'type': book.type.sourceKey,
            'updateTime': book.updateTime,
            'tags': book.tags,
          }
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({
          'status': 'running',
          'message': message,
          'data': data,
        });

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          }
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedBooksAsJson(folder);
        cliPrint({
          'status': result.errorMessage != null ? 'error' : 'success',
          'message': 'Updated books list.',
          'data': jsonDecode(json),
        });
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in updateFolder(folder, true)) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.book != null) {
            data['book'] = {
              'id': progress.book!.id,
              'name': progress.book!.name,
              'coverUrl': progress.book!.coverPath,
              'author': progress.book!.author,
              'type': progress.book!.type.sourceKey,
              'updateTime': progress.book!.updateTime,
              'tags': progress.book!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({
            'status': 'running',
            'message': message,
            'data': data,
          });
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': total,
            'updated': updated,
            'errors': errors,
          }
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedBooksAsJson(folder);
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated books list.',
          'data': jsonDecode(json),
        });
      }
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}
