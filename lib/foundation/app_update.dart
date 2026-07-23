import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/device_arch.dart';
import 'package:novvera/foundation/log.dart';
import 'package:novvera/network/app_dio.dart';
import 'package:novvera/utils/io.dart';
import 'package:yaml/yaml.dart';

enum AppUpdateStatus {
  idle,
  checking,
  latest,
  available,
  downloading,
  downloaded,
  error,
}

class AppUpdateHistoryEntry {
  const AppUpdateHistoryEntry({required this.version, required this.desc});
  final String version;
  final String desc;
}

class AppUpdateProgress {
  const AppUpdateProgress({
    required this.percent,
    required this.transferred,
    required this.total,
    required this.bytesPerSecond,
  });

  final double percent;
  final int transferred;
  final int total;
  final int bytesPerSecond;

  String get display {
    final pct = percent.isFinite ? percent.round().clamp(0, 100) : 0;
    return '$pct%（${_fmt(transferred)}/${_fmt(total)}）';
  }

  /// Under 1024MB keep MB; at/above that use GB.
  static String _fmt(int n) {
    const mb = 1024 * 1024;
    const gbCut = 1024 * mb;
    if (n >= gbCut) {
      final g = n / (1024 * mb);
      if ((g * 10).round() % 10 == 0) {
        return '${g.round()}GB';
      }
      return '${g.toStringAsFixed(1)}GB';
    }
    final m = n / mb;
    if (m >= 10 || (m - m.round()).abs() < 0.05) {
      return '${m.round()}MB';
    }
    if (m < 0.1 && n > 0) {
      return '${(n / 1024).round()}KB';
    }
    return '${m.toStringAsFixed(1)}MB';
  }
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.desc,
    this.history = const [],
    this.downloadUrl,
    this.assetName,
    this.archKey,
  });

  final String version;
  final String desc;
  final List<AppUpdateHistoryEntry> history;
  final String? downloadUrl;
  final String? assetName;
  /// Matched downloads key, e.g. `arm64-v8a` / `x64`.
  final String? archKey;
}

/// In-app updater: GitHub Releases API (primary) → version.json fallback.
class AppUpdateService extends ChangeNotifier {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  AppUpdateStatus status = AppUpdateStatus.idle;
  AppUpdateInfo? remote;
  AppUpdateProgress? progress;
  String? errorMessage;
  String? localFilePath;
  DeviceArch? deviceArch;

  bool get isDownloading => status == AppUpdateStatus.downloading;
  bool get hasUpdate {
    final r = remote;
    if (r == null || r.version == '0.0.0') return false;
    return compareVersion(r.version, App.version) > 0;
  }

  String? get ignoredVersion =>
      appdata.implicitData['updateIgnoreVersion']?.toString();

  set ignoredVersion(String? v) {
    if (v == null) {
      appdata.implicitData.remove('updateIgnoreVersion');
    } else {
      appdata.implicitData['updateIgnoreVersion'] = v;
    }
    appdata.writeImplicitData();
    notifyListeners();
  }

  bool get isIgnored =>
      remote != null && ignoredVersion == remote!.version;

  bool get suppressFailTip {
    final t = int.tryParse(
          '${appdata.implicitData['updateCheckFailedTip'] ?? 0}',
        ) ??
        0;
    return DateTime.now().millisecondsSinceEpoch - t < 7 * 86400000;
  }

  void dismissFailTipForWeek() {
    appdata.implicitData['updateCheckFailedTip'] =
        DateTime.now().millisecondsSinceEpoch;
    appdata.writeImplicitData();
    notifyListeners();
  }

  static int compareVersion(String a, String b) {
    final va = a.split('+').first.split('.');
    final vb = b.split('+').first.split('.');
    final n = math.max(va.length, vb.length);
    for (var i = 0; i < n; i++) {
      final x = i < va.length ? int.tryParse(va[i]) ?? 0 : 0;
      final y = i < vb.length ? int.tryParse(vb[i]) ?? 0 : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  Future<T> _getWithFallback<T>(
    String proxiedUrl,
    String directUrl,
    FutureOr<T> Function(Response res) parse,
  ) async {
    final dio = AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'user-agent': webUA, 'Accept': 'application/json'},
      ),
    );
    try {
      final res = await dio.get(proxiedUrl);
      if (res.statusCode != null && res.statusCode! >= 400) {
        throw DioException(
          requestOptions: res.requestOptions,
          response: res,
          message: 'HTTP ${res.statusCode}',
        );
      }
      return await parse(res);
    } catch (e) {
      Log.warning('AppUpdate', 'proxy failed ($proxiedUrl): $e → direct');
      final res = await dio.get(directUrl);
      if (res.statusCode != null && res.statusCode! >= 400) {
        throw DioException(
          requestOptions: res.requestOptions,
          response: res,
          message: 'HTTP ${res.statusCode}',
        );
      }
      return await parse(res);
    }
  }

  Future<AppUpdateInfo> _fetchFromReleasesApi() async {
    final arch = await DeviceArch.detect();
    deviceArch = arch;

    return _getWithFallback(appReleasesApiUrl, appReleasesApiUrlDirect, (res) {
      final raw = res.data;
      final map = raw is Map
          ? Map<String, dynamic>.from(raw)
          : jsonDecode(raw is String ? raw : raw.toString())
              as Map<String, dynamic>;
      var tag = (map['tag_name'] ?? map['name'] ?? '').toString().trim();
      if (tag.toLowerCase().startsWith('v')) {
        tag = tag.substring(1);
      }
      if (tag.isEmpty) throw StateError('empty release tag');
      final desc = (map['body'] ?? '').toString().trim();
      final assets = map['assets'];
      final picked = DeviceArch.pickReleaseAsset(
        assets is List ? assets : const [],
        arch,
        tag,
      );
      return AppUpdateInfo(
        version: tag.split('+').first,
        desc: desc,
        downloadUrl: picked?.$2,
        assetName: picked?.$3,
        archKey: picked?.$1,
      );
    });
  }

  Future<AppUpdateInfo> _fetchVersionJson() async {
    final arch = deviceArch ?? await DeviceArch.detect();
    deviceArch = arch;

    return _getWithFallback(appVersionJsonUrl, appVersionJsonUrlDirect, (res) {
      final raw = res.data;
      final map = raw is Map
          ? Map<String, dynamic>.from(raw)
          : jsonDecode(raw is String ? raw : raw.toString())
              as Map<String, dynamic>;
      final ver = (map['version'] ?? '').toString().trim();
      if (ver.isEmpty) throw StateError('empty version.json');
      final history = <AppUpdateHistoryEntry>[];
      final h = map['history'];
      if (h is List) {
        for (final e in h) {
          if (e is! Map) continue;
          final v = (e['version'] ?? '').toString();
          if (v.isEmpty) continue;
          history.add(AppUpdateHistoryEntry(
            version: v,
            desc: (e['desc'] ?? '').toString(),
          ));
        }
      }

      final picked = DeviceArch.pickDownloadUrl(
        map['downloads'] is Map ? map['downloads'] as Map : null,
        arch,
      );
      String? url = picked?.$2;
      String? archKey = picked?.$1;
      String? assetName;
      if (url != null) {
        assetName = Uri.tryParse(url)?.pathSegments.lastOrNull;
        if (assetName == null || assetName.isEmpty) {
          assetName = _defaultAssetName(ver.split('+').first, archKey);
        }
      }

      return AppUpdateInfo(
        version: ver.split('+').first,
        desc: (map['desc'] ?? '').toString(),
        history: history,
        downloadUrl: url,
        assetName: assetName,
        archKey: archKey,
      );
    });
  }

  String _defaultAssetName(String version, String? archKey) {
    final arch = archKey ?? 'unknown';
    if (Platform.isWindows) {
      return 'Novvera-$version-windows-installer.exe';
    }
    if (Platform.isAndroid) {
      if (arch == 'universal') return 'novvera-$version.apk';
      return 'novvera-$version-$arch.apk';
    }
    if (Platform.isMacOS) return 'Novvera-$version-macos.dmg';
    if (Platform.isLinux) return 'Novvera-$version-linux-$arch.tar.gz';
    return 'Novvera-$version-$arch.bin';
  }

  /// Version-only fallback when release API / version.json are unreachable.
  Future<AppUpdateInfo> _fetchFromPubspec() async {
    return _getWithFallback(appRepoPubspecUrl, appRepoPubspecUrlDirect, (res) {
      final data = loadYaml(res.data.toString());
      final ver = (data['version'] ?? '0.0.0').toString().split('+').first;
      return AppUpdateInfo(version: ver, desc: '');
    });
  }

  Future<AppUpdateInfo> fetchRemoteInfo() async {
    try {
      return await _fetchFromReleasesApi();
    } catch (e) {
      Log.warning('AppUpdate', 'releases api: $e');
    }
    try {
      return await _fetchVersionJson();
    } catch (e) {
      Log.warning('AppUpdate', 'version.json: $e');
    }
    try {
      return await _fetchFromPubspec();
    } catch (e) {
      Log.error('AppUpdate', 'all fetch failed: $e');
      return const AppUpdateInfo(version: '0.0.0', desc: '');
    }
  }

  Future<void> check({bool force = false}) async {
    if (status == AppUpdateStatus.checking && !force) return;
    if (status == AppUpdateStatus.downloading && !force) return;
    status = AppUpdateStatus.checking;
    errorMessage = null;
    notifyListeners();
    try {
      final info = await fetchRemoteInfo();
      remote = info;
      if (info.version == '0.0.0') {
        status = AppUpdateStatus.error;
        errorMessage = 'failed';
      } else if (compareVersion(info.version, App.version) <= 0) {
        status = AppUpdateStatus.latest;
      } else {
        status = AppUpdateStatus.available;
        final existing = _localPathFor(info);
        if (existing != null && File(existing).existsSync()) {
          localFilePath = existing;
          status = AppUpdateStatus.downloaded;
        }
      }
    } catch (e, s) {
      Log.error('AppUpdate', '$e\n$s');
      status = AppUpdateStatus.error;
      errorMessage = e.toString();
      remote ??= const AppUpdateInfo(version: '0.0.0', desc: '');
    }
    notifyListeners();
  }

  String? _localPathFor(AppUpdateInfo info) {
    final name = info.assetName ??
        _defaultAssetName(info.version, info.archKey);
    final dir = Directory(FilePath.join(App.cachePath, 'updates'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return FilePath.join(dir.path, name);
  }

  /// Only proxy GitHub hosts; leave other CDNs alone (try as-is).
  bool _isGithubHost(String url) {
    final u = url.toLowerCase();
    return u.contains('github.com') || u.contains('githubusercontent.com');
  }

  Future<void> startDownload() async {
    final info = remote;
    if (info == null || !hasUpdate) return;
    if (status == AppUpdateStatus.downloading) return;

    final url = info.downloadUrl;
    if (url == null || url.isEmpty) {
      final arch = deviceArch ?? await DeviceArch.detect();
      errorMessage =
          'No download asset for ${arch.platform}/${arch.primary} in latest release';
      status = AppUpdateStatus.available;
      notifyListeners();
      return;
    }

    status = AppUpdateStatus.downloading;
    progress = null;
    errorMessage = null;
    notifyListeners();

    final path = _localPathFor(remote!)!;
    final tmp = '$path.part';
    final file = File(tmp);

    try {
      await _downloadFile(url, file, path);
      localFilePath = path;
      status = AppUpdateStatus.downloaded;
      progress = null;
    } catch (e, s) {
      Log.error('AppUpdate', 'download failed: $e\n$s');
      errorMessage = e.toString();
      status = AppUpdateStatus.available;
      progress = null;
    }
    notifyListeners();
  }

  Future<void> _downloadFile(String url, File tmpFile, String finalPath) async {
    Future<void> attempt(String u, {bool allowRange = true}) async {
      final dio = AppDio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(minutes: 30),
          responseType: ResponseType.stream,
          headers: {'user-agent': webUA},
        ),
      );

      var start = 0;
      if (allowRange && tmpFile.existsSync()) {
        start = await tmpFile.length();
      } else if (tmpFile.existsSync()) {
        await tmpFile.delete();
        start = 0;
      }

      final headers = <String, dynamic>{'user-agent': webUA};
      if (start > 0) headers['Range'] = 'bytes=$start-';

      final res = await dio.get<ResponseBody>(
        u,
        options: Options(headers: headers, responseType: ResponseType.stream),
      );
      final code = res.statusCode ?? 0;
      if (code >= 400) {
        throw StateError('HTTP $code');
      }

      if (start > 0 && code == 200) {
        await tmpFile.delete();
        start = 0;
      }

      final totalHeader = res.headers.value('content-length');
      final contentLen = int.tryParse(totalHeader ?? '') ?? 0;
      final total = start > 0 && code == 206
          ? start + contentLen
          : (contentLen > 0 ? contentLen : 0);

      final sink = tmpFile.openWrite(mode: FileMode.append);
      var transferred = start;
      var lastTick = DateTime.now();
      var lastBytes = transferred;
      var speed = 0;

      try {
        await for (final chunk in res.data!.stream) {
          sink.add(chunk);
          transferred += chunk.length;
          final now = DateTime.now();
          final dt = now.difference(lastTick).inMilliseconds;
          if (dt >= 400) {
            speed = ((transferred - lastBytes) * 1000 / dt).round();
            lastTick = now;
            lastBytes = transferred;
          }
          final pct =
              total > 0 ? (transferred * 100 / total).clamp(0, 100) : 0.0;
          progress = AppUpdateProgress(
            percent: pct.toDouble(),
            transferred: transferred,
            total: total > 0 ? total : transferred,
            bytesPerSecond: speed,
          );
          notifyListeners();
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (File(finalPath).existsSync()) {
        await File(finalPath).delete();
      }
      await tmpFile.rename(finalPath);
    }

    if (_isGithubHost(url)) {
      final proxied = githubProxied(githubDirect(url));
      final direct = githubDirect(url);
      try {
        await attempt(proxied);
      } catch (e) {
        Log.warning('AppUpdate', 'proxied download failed: $e → direct');
        if (tmpFile.existsSync()) {
          try {
            await tmpFile.delete();
          } catch (_) {}
        }
        await attempt(direct, allowRange: false);
      }
    } else {
      await attempt(url);
    }
  }

  Future<void> installOrOpen() async {
    final path = localFilePath;
    if (path == null || !File(path).existsSync()) return;
    try {
      if (Platform.isWindows) {
        await Process.start(
          path,
          const [],
          mode: ProcessStartMode.detached,
        );
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else if (Platform.isAndroid) {
        // Best-effort: open via file URI; proper install Intent needs FileProvider.
        await Process.run('am', [
          'start',
          '-a',
          'android.intent.action.VIEW',
          '-t',
          'application/vnd.android.package-archive',
          '-d',
          'file://$path',
        ]);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (e) {
      try {
        final dir = File(path).parent.path;
        if (Platform.isWindows) {
          await Process.run('explorer', [dir]);
        } else if (Platform.isMacOS) {
          await Process.run('open', [dir]);
        } else {
          await Process.run('xdg-open', [dir]);
        }
      } catch (e2) {
        Log.error('AppUpdate', 'open failed: $e / $e2');
        rethrow;
      }
    }
  }

  List<AppUpdateHistoryEntry> historyNewerThanCurrent() {
    final list = remote?.history ?? const [];
    return list
        .where((e) => compareVersion(e.version, App.version) > 0)
        .toList();
  }
}
