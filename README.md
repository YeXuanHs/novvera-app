# Novvera

开源双端轻小说阅读器（Windows / macOS / Linux / Android / iOS）。

基于 [Venera](https://github.com/venera-app/venera) 改造；当前版本 **1.1.0**。

仓库：https://github.com/YeXuanHs/novvera-app  
下载：https://github.com/YeXuanHs/novvera-app/releases/latest

## 功能

- 内置书源：**轻小说文库（wenku8）**、**哔哩轻小说（linovelib）**、**幻梦轻小说（huanmeng）**
- 搜索、排行、详情、分卷目录、正文阅读（含插图）
- 文字阅读器，支持连续 / 分页与本地阅读进度
- 本机收藏与历史（不依赖云端账号）
- EPUB 导出：自选保存目录，按 `书名 / 卷名 / 章节名.epub` 分层；可整卷全选或单选章节
- 应用内更新：读取 GitHub Latest Release，按设备架构自动匹配安装包（默认走代理，失败回退直连）

## 书源说明

| 源 | 说明 |
|---|---|
| 轻小说文库 | 启动时可自动处理账号会话；搜索 / 排行 / 目录 / 章节 |
| 哔哩轻小说 | 支持搜索与排行；遇 Cloudflare 时可在应用内验证 |
| 幻梦轻小说 | 搜索 / 排行 / 详情 / 分卷章节 |

## 构建

推送到 `main` 或发布 Release 时，GitHub Actions 会构建各平台产物；发布 Release 后安装包会自动挂到该 Release 的 Assets。

仅改文档时请在提交说明中带 `[skip ci]`，避免无谓触发构建。

## 致谢

UI 与桌面壳来自上游 Venera；本仓库以 Novvera 名义维护轻小说阅读版。

## 许可

继承上游开源许可。
