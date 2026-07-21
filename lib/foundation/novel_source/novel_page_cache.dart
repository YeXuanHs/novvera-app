/// In-memory text pages for novel chapters shown inside Venera's Reader.
///
/// Image URLs stay as normal http(s) keys; text paragraphs use `noveltxt://…`
/// keys so continuous / gallery modes can render text widgets instead of images.
class NovelPageCache {
  NovelPageCache._();

  static final Map<String, String> _map = {};
  static int _seq = 0;

  static const prefix = 'noveltxt://';

  static bool isTextKey(String key) => key.startsWith(prefix);

  static String put(String text) {
    final key = '$prefix${++_seq}';
    _map[key] = text;
    return key;
  }

  static String? get(String key) => _map[key];

  static void clear() => _map.clear();
}
