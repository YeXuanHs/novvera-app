import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:novvera/components/components.dart';
import 'package:novvera/foundation/app.dart';
import 'package:novvera/foundation/app_update.dart';
import 'package:novvera/foundation/appdata.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/utils/translations.dart';

/// Show LX-style update dialog. Closing does not cancel an in-progress download.
Future<void> showAppUpdateModal({
  bool autoStartDownload = false,
}) async {
  final svc = AppUpdateService.instance;
  if (svc.status == AppUpdateStatus.idle ||
      svc.status == AppUpdateStatus.checking) {
    await svc.check();
  }

  if (svc.hasUpdate &&
      autoStartDownload &&
      svc.status == AppUpdateStatus.available &&
      !svc.isIgnored) {
    // Fire-and-forget; dialog listens via ChangeNotifier.
    unawaited(svc.startDownload());
  }

  if (!App.rootContext.mounted) return;

  await showDialog(
    context: App.rootContext,
    barrierDismissible: true,
    builder: (context) => const _UpdateModalDialog(),
  );
}

class _UpdateModalDialog extends StatefulWidget {
  const _UpdateModalDialog();

  @override
  State<_UpdateModalDialog> createState() => _UpdateModalDialogState();
}

class _UpdateModalDialogState extends State<_UpdateModalDialog> {
  final _svc = AppUpdateService.instance;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChanged);
  }

  @override
  void dispose() {
    _svc.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_svc.status) {
      AppUpdateStatus.latest => 'Already up to date'.tl,
      AppUpdateStatus.error => 'Failed to get update info'.tl,
      AppUpdateStatus.downloaded => 'Update ready'.tl,
      _ => _svc.hasUpdate
          ? 'New version available'.tl
          : 'Check for updates'.tl,
    };

    return ContentDialog(
      title: title,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: _buildBody(context),
          ),
        ),
      ),
      actions: _buildActions(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_svc.status == AppUpdateStatus.checking && _svc.remote == null) {
      return Text('Checking for updates...'.tl);
    }

    if (_svc.status == AppUpdateStatus.error ||
        (_svc.remote?.version == '0.0.0')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${'Current version'.tl}: ${App.version}'),
          const SizedBox(height: 8),
          Text(
            'Could not fetch update info (GitHub may be unreachable). Please check manually.'.tl,
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '${'Open'.tl} '),
                TextSpan(
                  text: 'Releases'.tl,
                  style: TextStyle(
                    color: context.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => launchUrlString(appRepoReleasesUrl),
                ),
                TextSpan(
                  text:
                      ' ${'and compare the Latest tag with'.tl} ${App.version}.',
                ),
              ],
            ),
          ),
        ],
      );
    }

    final remote = _svc.remote;
    final history = _svc.historyNewerThanCurrent();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (remote != null) ...[
          Text('${'Latest version'.tl}: ${remote.version}'),
          Text('${'Current version'.tl}: ${App.version}'),
          const SizedBox(height: 8),
          Text('Changelog'.tl,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          SelectableText(
            remote.desc.isEmpty ? '—' : remote.desc,
            style: const TextStyle(height: 1.4),
          ),
        ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Version history'.tl,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          for (final h in history) ...[
            const SizedBox(height: 8),
            Text('v${h.version}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            SelectableText(h.desc, style: const TextStyle(height: 1.35)),
          ],
        ],
        if (_svc.hasUpdate) ...[
          const SizedBox(height: 12),
          Text(
            'You can update in-app or download manually from Releases.'.tl,
            style: TextStyle(
              fontSize: 13,
              color: context.colorScheme.primary,
            ),
          ),
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 13,
                color: context.colorScheme.primary,
              ),
              children: [
                TextSpan(
                  text: 'Releases'.tl,
                  style: const TextStyle(decoration: TextDecoration.underline),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => launchUrlString(appRepoReleasesUrl),
                ),
              ],
            ),
          ),
        ],
        if (_svc.status == AppUpdateStatus.downloading) ...[
          const SizedBox(height: 10),
          Text(
            _svc.progress?.display ?? 'Preparing download...'.tl,
            style: TextStyle(
              fontSize: 13,
              color: context.colorScheme.primary,
            ),
          ),
        ],
        if (_svc.status == AppUpdateStatus.downloaded) ...[
          const SizedBox(height: 10),
          Text(
            Platform.isAndroid
                ? 'Download complete. Tap install to open the system installer.'.tl
                : 'Download complete. Open the installer to finish updating.'.tl,
            style: TextStyle(
              fontSize: 13,
              color: context.colorScheme.primary,
            ),
          ),
        ],
        if (_svc.errorMessage != null &&
            _svc.status == AppUpdateStatus.available) ...[
          const SizedBox(height: 8),
          Text(
            _svc.errorMessage!,
            style: TextStyle(color: context.colorScheme.error, fontSize: 12),
          ),
        ],
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    final actions = <Widget>[];

    if (_svc.status == AppUpdateStatus.error ||
        _svc.remote?.version == '0.0.0') {
      actions.add(
        Button.text(
          onPressed: () {
            _svc.dismissFailTipForWeek();
            Navigator.pop(context);
          },
          child: Text("Don't remind for a week".tl),
        ),
      );
      actions.add(
        Button.filled(
          isLoading: _svc.status == AppUpdateStatus.checking,
          onPressed: () => _svc.check(force: true),
          child: Text('Recheck'.tl),
        ),
      );
      return actions;
    }

    if (_svc.status == AppUpdateStatus.latest) {
      actions.add(
        Button.filled(
          isLoading: _svc.status == AppUpdateStatus.checking,
          onPressed: () => _svc.check(force: true),
          child: Text('Recheck'.tl),
        ),
      );
      return actions;
    }

    if (_svc.status == AppUpdateStatus.downloaded) {
      actions.add(
        Button.filled(
          onPressed: () async {
            try {
              await _svc.installOrOpen();
            } catch (e) {
              if (context.mounted) {
                context.showMessage(message: e.toString());
              }
            }
          },
          child: Text(Platform.isAndroid ? 'Install'.tl : 'Open installer'.tl),
        ),
      );
      return actions;
    }

    if (_svc.hasUpdate) {
      actions.add(
        Button.text(
          onPressed: () {
            if (_svc.isIgnored) {
              _svc.ignoredVersion = null;
            } else {
              _svc.ignoredVersion = _svc.remote?.version;
            }
          },
          child: Text(
            _svc.isIgnored ? 'Unignore this version'.tl : 'Ignore this version'.tl,
          ),
        ),
      );
      actions.add(
        Button.filled(
          isLoading: _svc.status == AppUpdateStatus.downloading,
          onPressed: _svc.status == AppUpdateStatus.downloading
              ? () {}
              : () {
                  if (_svc.isIgnored) _svc.ignoredVersion = null;
                  _svc.startDownload();
                },
          child: Text(
            _svc.status == AppUpdateStatus.downloading
                ? 'Downloading...'.tl
                : 'Download update'.tl,
          ),
        ),
      );
    } else if (_svc.status == AppUpdateStatus.checking) {
      actions.add(
        Button.filled(
          isLoading: true,
          onPressed: () {},
          child: Text('Checking for updates...'.tl),
        ),
      );
    }

    return actions;
  }
}

/// Manual / startup entry used by About & init.
Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  final svc = AppUpdateService.instance;
  try {
    await svc.check();
    if (delay) {
      await Future.delayed(const Duration(seconds: 2));
    }

    if (svc.status == AppUpdateStatus.error ||
        svc.remote?.version == '0.0.0') {
      if (showMessageIfNoUpdate && !svc.suppressFailTip) {
        await showAppUpdateModal();
      } else if (showMessageIfNoUpdate) {
        App.rootContext.showMessage(
          message: 'Failed to get update info'.tl,
        );
      }
      return;
    }

    if (!svc.hasUpdate) {
      if (showMessageIfNoUpdate) {
        await showAppUpdateModal();
      }
      return;
    }

    if (svc.isIgnored && !showMessageIfNoUpdate) {
      // Startup: respect ignore.
      return;
    }

    final auto = appdata.settings['tryAutoUpdate'] == true;
    await showAppUpdateModal(autoStartDownload: auto && !svc.isIgnored);
  } catch (e) {
    if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: e.toString());
    }
  }
}
