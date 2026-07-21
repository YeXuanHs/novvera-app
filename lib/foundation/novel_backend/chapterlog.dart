/// Fisher–Yates paragraph restore for linovelib `/scripts/chapterlog.js`.
List<int> chapterlogOrder(int n, int cid) {
  if (n <= 0) return [];
  if (n <= 20) return List.generate(n, (i) => i);
  final fixed = List.generate(20, (i) => i);
  final rest = List.generate(n - 20, (i) => i + 20);
  const m = 233280, a = 9302, c = 49397;
  var s = cid * 127 + 235;
  for (var i = rest.length - 1; i > 0; i--) {
    s = (s * a + c) % m;
    final j = (s * (i + 1)) ~/ m;
    final tmp = rest[i];
    rest[i] = rest[j];
    rest[j] = tmp;
  }
  return [...fixed, ...rest];
}

List<String> restoreParagraphs(List<String> paragraphs, int cid) {
  final order = chapterlogOrder(paragraphs.length, cid);
  final out = List<String>.filled(paragraphs.length, '');
  for (var i = 0; i < paragraphs.length; i++) {
    out[order[i]] = paragraphs[i];
  }
  return out;
}
