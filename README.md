# Novvera — Windows desktop light novel reader (fork of Venera).

- Repo: https://github.com/YeXuanHs/Novvera-app-desktop
- Builtin sources: wenku8, linovelib (in-process Dart; no Python sidecar)
- Favorites / history: local only

## Build with GitHub Actions

Push to `master` / `main`, or run **Actions → Build PC → Run workflow**.  
Builds all desktop targets in parallel:

| Platform | Artifact |
|---|---|
| Windows x64 | `Novvera-*-windows.zip` + Inno Setup `.exe` |
| macOS | `Novvera-*-macos.dmg` |
| Linux x64 | `Novvera-*-linux-x64.tar.gz` (+ `.deb` if available) |
| Linux ARM64 | `Novvera-*-linux-arm64.tar.gz` (+ `.deb` if available) |

Creating a GitHub Release uploads all of the above to the release assets.

## Build locally

Requires Flutter (see `pubspec.yaml` `flutter:`), Rust, and Visual Studio with Desktop C++.

```powershell
$env:RUSTFLAGS='--cfg reqwest_unstable'
flutter pub get
flutter build windows --release
# optional installer:
# pip install httpx
# python windows/build.py
```

## License

Inherited from upstream Venera; this fork is published as Novvera.
