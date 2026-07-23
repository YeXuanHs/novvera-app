part of 'settings_page.dart';

class ReaderSettings extends StatefulWidget {
  const ReaderSettings({
    super.key,
    this.onChanged,
    this.comicId,
    this.comicSource,
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<ReaderSettings> {
  @override
  Widget build(BuildContext context) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    final key = "$comicId@$sourceKey";

    bool isEnabledSpecificSettings =
        comicId != null &&
        appdata.settings.isComicSpecificSettingsEnabled(comicId, sourceKey);
    bool useDeviceSpecificSettings =
        !isEnabledSpecificSettings &&
        appdata.settings.isDeviceSpecificSettingsEnabled();

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Reading".tl)),
        if (comicId != null && sourceKey != null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                title: Text("Enable book-specific settings".tl),
                value: isEnabledSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledComicSpecificSettings(
                      comicId,
                      sourceKey,
                      b,
                    );
                  });
                },
              ).toSliver(),
              if (isEnabledSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetComicReaderSettings(key);
                      });
                    },
                    child: Text(
                      "Clear specific reader settings for this book".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        if (comicId == null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                title: Text("Enable device specific settings".tl),
                value: useDeviceSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledDeviceSpecificSettings(b);
                  });
                  appdata.saveData();
                },
              ).toSliver(),
              if (useDeviceSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetDeviceReaderSettings();
                      });
                      appdata.saveData();
                    },
                    child: Text(
                      "Clear specific reader settings for this device".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        _SwitchSetting(
          title: "Tap to turn Pages".tl,
          settingKey: "enableTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("enableTapToTurnPages");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Reverse tap to turn Pages".tl,
          settingKey: "reverseTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("reverseTapToTurnPages");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Page animation".tl,
          settingKey: "enablePageAnimation",
          onChanged: () {
            widget.onChanged?.call("enablePageAnimation");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SelectSetting(
          title: "Reading mode".tl,
          settingKey: "readerMode",
          optionTranslation: {
            "galleryLeftToRight": "Paginated (Left to Right)".tl,
            "galleryRightToLeft": "Paginated (Right to Left)".tl,
            "galleryTopToBottom": "Paginated (Top to Bottom)".tl,
            "continuousLeftToRight": "Continuous (Left to Right)".tl,
            "continuousRightToLeft": "Continuous (Right to Left)".tl,
            "continuousTopToBottom": "Continuous (Top to Bottom)".tl,
          },
          onChanged: () {
            setState(() {});
            var readerMode = appdata.settings['readerMode'];
            if (readerMode?.toLowerCase().startsWith('continuous') ?? false) {
              appdata.settings['readerScreenPicNumberForLandscape'] = 1;
              widget.onChanged?.call('readerScreenPicNumberForLandscape');
              appdata.settings['readerScreenPicNumberForPortrait'] = 1;
              widget.onChanged?.call('readerScreenPicNumberForPortrait');
            }
            widget.onChanged?.call("readerMode");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SliderSetting(
          title: "Auto page turning interval".tl,
          settingsIndex: "autoPageTurningInterval",
          interval: 1,
          min: 1,
          max: 20,
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("autoPageTurningInterval");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: appdata.settings['readerMode']!.startsWith('continuous'),
          child: _SliderSetting(
            title: "Mouse scroll speed".tl,
            settingsIndex: "readerScrollSpeed",
            interval: 0.1,
            min: 0.5,
            max: 3,
            onChanged: () {
              widget.onChanged?.call("readerScrollSpeed");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        _SwitchSetting(
          title: 'Double tap to zoom'.tl,
          settingKey: 'enableDoubleTapToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableDoubleTapToZoom');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: 'Long press to zoom'.tl,
          settingKey: 'enableLongPressToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableLongPressToZoom');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: appdata.settings['enableLongPressToZoom'] == true,
          child: SelectSetting(
            title: "Long press zoom position".tl,
            settingKey: "longPressZoomPosition",
            optionTranslation: {
              "press": "Press position".tl,
              "center": "Screen center".tl,
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        if (App.isAndroid)
          _SwitchSetting(
            title: 'Turn page by volume keys'.tl,
            settingKey: 'enableTurnPageByVolumeKey',
            onChanged: () {
              widget.onChanged?.call('enableTurnPageByVolumeKey');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
        _SwitchSetting(
          title: "Display time & battery info in reader".tl,
          settingKey: "enableClockAndBatteryInfoInReader",
          onChanged: () {
            widget.onChanged?.call("enableClockAndBatteryInfoInReader");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Show system status bar".tl,
          settingKey: "showSystemStatusBar",
          onChanged: () {
            widget.onChanged?.call("showSystemStatusBar");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SliderSetting(
          title: "Number of pages preloaded".tl,
          settingsIndex: "preloadImageCount",
          interval: 1,
          min: 1,
          max: 16,
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Show Page Number".tl,
          settingKey: "showPageNumberInReader",
          onChanged: () {
            widget.onChanged?.call("showPageNumberInReader");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
      ],
    );
  }
}
