# Novvera

[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/YeXuanHs/novvera-app)](https://github.com/YeXuanHs/novvera-app/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/YeXuanHs/novvera-app?cacheSeconds=60)](https://github.com/YeXuanHs/novvera-app/releases/latest)
[![stars](https://img.shields.io/github/stars/YeXuanHs/novvera-app?style=flat&cacheSeconds=60)](https://github.com/YeXuanHs/novvera-app/stargazers)

开源双端轻小说阅读器。支持 **Windows / macOS / Linux / Android / iOS**。

在 [Venera](https://github.com/venera-app/venera) 的基础上改造，面向轻小说阅读场景：内置书源、分卷目录、插图正文、EPUB 导出与应用内更新。

**最新版下载：** https://github.com/YeXuanHs/novvera-app/releases/latest

QQ 交流群：https://qm.qq.com/q/P2br4CwKsy

---

## 功能

- **在线阅读**：搜索、排行 / 推荐、书籍详情、分卷目录、章节正文（含插图）
- **阅读体验**：文字阅读器，支持连续滚动与分页；阅读进度保存在本机
- **收藏与历史**：本地收藏、阅读历史，不依赖云端账号
- **EPUB 导出**
  - 自选保存文件夹
  - 自动创建目录：`书名 / 卷名 / 章节名.epub`
  - 可按卷一键全选，也可单选章节；未导出的卷不会创建空文件夹
- **应用内更新**：检测 GitHub Latest Release，按当前设备架构自动选择安装包（如 Android `arm64-v8a`、Windows 安装包等），并显示下载进度
- **多平台安装包**：Release 提供 Windows / macOS / Linux / Android 等产物（以各次 Release Assets 为准）

## 内置书源

| 书源 | 说明 |
|------|------|
| **轻小说文库（wenku8）** | 搜索、排行、详情、目录、章节等走**官方 API**；仅首页「推荐书籍」走网页抓取，因此需要账号会话 |
| **哔哩轻小说（linovelib）** | **网页爬取**；搜索分页有缺陷：无论点哪一页内容都相同（根因是未登录账号） |
| **幻梦轻小说（huanmeng）** | **官方 bookapi**（目录/搜索/正文走接口，按卷名正确分组） |

> 网站规则、接口与反爬策略可能变化；若某源暂时不可用，以应用内提示为准。请支持正版轻小说。

## 下载与安装

1. 打开 [Releases](https://github.com/YeXuanHs/novvera-app/releases/latest)
2. 按自己的系统选择对应文件，例如：
   - Windows：`Novvera-*-windows-installer.exe` 或 `.zip`
   - Android：`novvera-*-arm64-v8a.apk`（或其它 ABI / 通用包）
   - macOS：`Novvera-*-macos.dmg`
   - Linux：`*.tar.gz` 或 `.deb`
3. 也可在应用「关于」中检查更新并直接下载

## 从源码构建

1. 克隆本仓库  
2. 安装 [Flutter](https://flutter.dev/docs/get-started/install)（与 `pubspec.yaml` 中版本对齐）  
3. 安装 [Rust](https://rustup.rs/)（部分依赖需要）  
4. 执行例如：

```bash
flutter pub get
flutter build windows   # 或 apk / macos / linux / ios
```

发布正式安装包时，推送 Release（tag）会触发 GitHub Actions，自动构建并将产物上传到该 Release。

## 致谢

- 界面、桌面壳与大量基础能力来自上游 [Venera](https://github.com/venera-app/venera)
- 轻小说文库相关官方 API 的对接，参考并得益于 [轻小说文库安卓客户端（MewX）](https://github.com/MewX/light-novel-library_Wenku8_Android) 的发布包分析；该仓库源码本身未包含 API 实现，但其客户端行为对本项目实现文库书源帮助很大。发布页：https://github.com/MewX/light-novel-library_Wenku8_Android/releases
- 标签中文翻译等资源亦受益于社区相关项目（参见上游致谢）

## 许可

本项目以 **[GNU General Public License v3.0（GPL-3.0）](./LICENSE)** 发布。

你可以自由使用、修改和分发本软件，但若对外分发修改版或衍生作品，也须以 GPL-3.0（或兼容条款）开源，并保留相应版权与许可声明。完整条款见仓库根目录 [`LICENSE`](./LICENSE) 文件。

Novvera 基于 Venera 修改而来；Venera 同样采用 GPL-3.0。使用本项目即表示你了解并接受上述许可要求。
