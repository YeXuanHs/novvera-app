import 'dart:io';

import 'package:flutter/services.dart';

/// Runtime platform + CPU ABI used to pick a Release asset / optional URL map.
class DeviceArch {
  const DeviceArch({
    required this.platform,
    required this.primary,
    required this.candidates,
  });

  /// `windows` | `android` | `macos` | `linux` | `ios` | `unknown`
  final String platform;

  /// Preferred arch key for this device (e.g. `x64`, `arm64-v8a`).
  final String primary;

  /// Preference-ordered arch keys (e.g. Android ABI list).
  final List<String> candidates;

  static const _channel = MethodChannel('novvera/method_channel');

  /// Detect once per process.
  static DeviceArch? _cached;

  static Future<DeviceArch> detect() async {
    if (_cached != null) return _cached!;
    final platform = _platformKey();
    final candidates = await _archCandidates(platform);
    final primary = candidates.isNotEmpty ? candidates.first : 'unknown';
    return _cached = DeviceArch(
      platform: platform,
      primary: primary,
      candidates: candidates,
    );
  }

  static String _platformKey() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  static Future<List<String>> _archCandidates(String platform) async {
    switch (platform) {
      case 'android':
        return _androidCandidates();
      case 'windows':
        return _windowsCandidates();
      case 'macos':
      case 'linux':
        return _unixCandidates(platform);
      case 'ios':
        // iOS updates are App Store only; keep a key for completeness.
        return const ['arm64', 'universal'];
      default:
        return const ['unknown'];
    }
  }

  /// Android: walk [Build.SUPPORTED_ABIS] in order, then universal.
  static Future<List<String>> _androidCandidates() async {
    final keys = <String>[];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getSupportedAbis');
      if (raw != null) {
        for (final a in raw) {
          final n = _normalizeAndroidAbi('$a');
          if (n != null && !keys.contains(n)) keys.add(n);
        }
      }
    } catch (_) {}
    // Fallback if channel missing (tests / odd builds).
    if (keys.isEmpty) {
      keys.addAll(const ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86']);
    }
    if (!keys.contains('universal')) keys.add('universal');
    return keys;
  }

  static String? _normalizeAndroidAbi(String abi) {
    final a = abi.trim().toLowerCase();
    switch (a) {
      case 'arm64-v8a':
      case 'arm64':
      case 'aarch64':
        return 'arm64-v8a';
      case 'armeabi-v7a':
      case 'armeabi':
      case 'armv7':
      case 'armv7a':
      case 'arm':
        return 'armeabi-v7a';
      case 'x86_64':
      case 'x64':
      case 'amd64':
        return 'x86_64';
      case 'x86':
      case 'i386':
      case 'i686':
        return 'x86';
      default:
        return a.isEmpty ? null : a;
    }
  }

  static List<String> _windowsCandidates() {
    final arch = (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '')
        .toUpperCase();
    final arch6432 = (Platform.environment['PROCESSOR_ARCHITEW6432'] ?? '')
        .toUpperCase();
    final effective = arch6432.isNotEmpty ? arch6432 : arch;

    if (effective.contains('ARM64') || effective == 'ARM') {
      return const ['arm64', 'x64', 'x86'];
    }
    if (effective.contains('64') || effective == 'AMD64' || effective == 'X86_64') {
      return const ['x64', 'x86'];
    }
    if (effective.contains('86') || effective == 'X86') {
      return const ['x86'];
    }
    return const ['x64', 'x86', 'arm64'];
  }

  static Future<List<String>> _unixCandidates(String platform) async {
    var machine = '';
    try {
      final r = await Process.run('uname', ['-m']);
      if (r.exitCode == 0) machine = '${r.stdout}'.trim().toLowerCase();
    } catch (_) {}

    if (machine.contains('aarch64') ||
        machine == 'arm64' ||
        machine.startsWith('armv8')) {
      return platform == 'macos'
          ? const ['arm64', 'universal', 'x64']
          : const ['arm64', 'x64'];
    }
    if (machine.contains('armv7') || machine == 'arm') {
      return const ['armv7', 'arm64', 'x64'];
    }
    if (machine.contains('x86_64') ||
        machine == 'amd64' ||
        machine == 'x64') {
      return platform == 'macos'
          ? const ['x64', 'universal', 'arm64']
          : const ['x64', 'arm64'];
    }
    if (machine.contains('i386') || machine.contains('i686')) {
      return const ['x86', 'x64'];
    }
    return platform == 'macos'
        ? const ['universal', 'arm64', 'x64']
        : const ['x64', 'arm64'];
  }

  /// Optional legacy helper: pick URL from a nested/flat `downloads` map.
  /// Installers are normally resolved via [pickReleaseAsset].
  ///
  /// Expected shape (legacy):
  /// ```json
  /// "downloads": {
  ///   "windows": { "x64": "url", "arm64": "url" },
  ///   "android": { "arm64-v8a": "url", "universal": "url" }
  /// }
  /// ```
  /// Also accepts flat keys like `"windows-x64": "url"`.
  static (String archKey, String url)? pickDownloadUrl(
    Map? downloads,
    DeviceArch arch,
  ) {
    if (downloads == null || downloads.isEmpty) return null;

    // Nested: downloads[platform][arch]
    final platformNode = downloads[arch.platform];
    if (platformNode is Map) {
      for (final key in arch.candidates) {
        final u = _asUrl(platformNode[key]);
        if (u != null) return (key, u);
      }
      // last resort: any non-empty under platform
      for (final e in platformNode.entries) {
        final u = _asUrl(e.value);
        if (u != null) return ('${e.key}', u);
      }
    }

    // Flat: downloads["android-arm64-v8a"] / downloads["windows-x64"]
    for (final key in arch.candidates) {
      final flat = '${arch.platform}-$key';
      final u = _asUrl(downloads[flat]);
      if (u != null) return (key, u);
    }
    final platformOnly = _asUrl(downloads[arch.platform]);
    if (platformOnly != null) return (arch.primary, platformOnly);

    return null;
  }

  /// Pick a GitHub Release asset browser_download_url for this device.
  ///
  /// Expected names (case-insensitive), e.g.:
  /// - `novvera-1.0.0-arm64-v8a.apk`
  /// - `Novvera-1.0.0-windows-installer.exe`
  /// - `Novvera-1.0.0-macos.dmg`
  /// Returns `(archKey, url, assetName)`.
  static (String archKey, String url, String name)? pickReleaseAsset(
    List assets,
    DeviceArch arch,
    String version,
  ) {
    final items = <({String name, String url})>[];
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] ?? '').toString();
      final url = (a['browser_download_url'] ?? '').toString();
      if (name.isEmpty || url.isEmpty) continue;
      items.add((name: name, url: url));
    }
    if (items.isEmpty) return null;

    bool match(String name, RegExp re) => re.hasMatch(name);
    ({String name, String url})? find(RegExp re) {
      for (final it in items) {
        if (match(it.name, re)) return it;
      }
      return null;
    }

    final ver = RegExp.escape(version);
    switch (arch.platform) {
      case 'android':
        for (final key in arch.candidates) {
          if (key == 'universal') {
            final exact = find(RegExp(
              r'^novvera[-_]' + ver + r'\.apk$',
              caseSensitive: false,
            ));
            if (exact != null) return (key, exact.url, exact.name);
            continue;
          }
          final archEsc = RegExp.escape(key);
          final hit = find(RegExp(
            r'^novvera[-_]' + ver + r'[-_]' + archEsc + r'\.apk$',
            caseSensitive: false,
          ));
          if (hit != null) return (key, hit.url, hit.name);
        }
        final anyApk = find(RegExp(r'\.apk$', caseSensitive: false));
        if (anyApk != null) return (arch.primary, anyApk.url, anyApk.name);
        break;
      case 'windows':
        final installer = find(RegExp(
          r'^novvera[-_]' + ver + r'[-_]windows[-_]installer\.exe$',
          caseSensitive: false,
        ));
        if (installer != null) {
          return ('installer', installer.url, installer.name);
        }
        final zip = find(RegExp(
          r'^novvera[-_]' + ver + r'[-_]windows\.zip$',
          caseSensitive: false,
        ));
        if (zip != null) return ('zip', zip.url, zip.name);
        final anyExe = find(RegExp(r'\.exe$', caseSensitive: false));
        if (anyExe != null) return ('exe', anyExe.url, anyExe.name);
        break;
      case 'macos':
        final dmg = find(RegExp(
          r'^novvera[-_]' + ver + r'[-_]macos\.dmg$',
          caseSensitive: false,
        ));
        if (dmg != null) return ('universal', dmg.url, dmg.name);
        final anyDmg = find(RegExp(r'\.dmg$', caseSensitive: false));
        if (anyDmg != null) return ('dmg', anyDmg.url, anyDmg.name);
        break;
      case 'linux':
        for (final key in arch.candidates) {
          final archEsc = RegExp.escape(key);
          final tar = find(RegExp(
            r'^novvera[-_]' + ver + r'[-_]linux[-_]' + archEsc + r'\.tar\.gz$',
            caseSensitive: false,
          ));
          if (tar != null) return (key, tar.url, tar.name);
          final debArch = key == 'x64' ? 'amd64' : key;
          final deb = find(RegExp(
            r'^novvera[_-]' +
                ver +
                r'[_-]' +
                RegExp.escape(debArch) +
                r'\.deb$',
            caseSensitive: false,
          ));
          if (deb != null) return (key, deb.url, deb.name);
        }
        break;
      case 'ios':
        final ipa = find(RegExp(
          r'^novvera[-_]' + ver + r'[-_]ios\.ipa$',
          caseSensitive: false,
        ));
        if (ipa != null) return ('arm64', ipa.url, ipa.name);
        break;
    }
    return null;
  }

  static String? _asUrl(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    if (!(s.startsWith('http://') || s.startsWith('https://'))) return null;
    return s;
  }
}
