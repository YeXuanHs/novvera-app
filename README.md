# Novvera

开源轻小说桌面阅读器。

基于 [Venera](https://github.com/venera-app/venera) 改造，面向 Windows / macOS / Linux。

仓库：https://github.com/YeXuanHs/Novvera-app-desktop

## 功能

- 内置两个书源：**轻小说文库（wenku8）**、**哔哩轻小说（linovelib）**
- 搜索、排行榜、详情、目录、正文阅读（含插图）
- 文字滚动阅读器，支持本地阅读进度
- 哔哩轻小说部分章节可能受 Cloudflare 影响；遇到时会提示「需要验证」，点验证后在网页里过人机校验即可
- 收藏与历史仅保存在本机，不依赖云端账号
- 抓取逻辑在 App 内用 Dart 实现，无需额外后端进程

## 书源说明

| 源 | 说明 |
|---|---|
| 轻小说文库 | 启动时可自动处理账号会话；搜索 / 排行 / 目录 / 章节 |
| 哔哩轻小说 | 支持搜索与排行；遇 Cloudflare 时可在应用内人工验证 |

## 致谢

UI 与桌面壳来自上游 Venera；本仓库以 Novvera 名义维护轻小说桌面版。

## 许可

继承上游开源许可。
