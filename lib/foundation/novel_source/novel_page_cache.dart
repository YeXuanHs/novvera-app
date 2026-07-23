import 'package:novvera/foundation/novel_source/novel_paginator.dart';

/// In-memory novel chapter data for Venera's Reader.
///
/// - Continuous mode reads [blocks] as a vertical text+image stream.
/// - Gallery mode paginates [blocks] into fill-viewport pages (images exclusive).
/// - [pageKeys] holds the current gallery (or fallback) page keys for the comic
///   reader shell (`noveltxt://…` or http image URLs).
class NovelPageCache {
  NovelPageCache._();

  static final Map<String, String> _map = {};
  static int _seq = 0;
  static List<NovelBlock> _blocks = const [];
  static int _chapterEpoch = 0;

  static const prefix = 'noveltxt://';

  static bool isTextKey(String key) => key.startsWith(prefix);

  static List<NovelBlock> get blocks => List.unmodifiable(_blocks);

  /// Bumps when chapter blocks are replaced (gallery pager must reset).
  static int get chapterEpoch => _chapterEpoch;

  static void setBlocks(List<NovelBlock> blocks) {
    _blocks = List<NovelBlock>.from(blocks);
    _chapterEpoch++;
  }

  static String put(String text) {
    final key = '$prefix${++_seq}';
    _map[key] = text;
    return key;
  }

  static String? get(String key) => _map[key];

  static void clear() {
    _map.clear();
    _blocks = const [];
    _seq = 0;
    _chapterEpoch++;
  }

  /// Drop text page keys only (keep chapter [blocks] for re-pagination).
  static void clearTexts() {
    _map.clear();
    _seq = 0;
  }
}
