# rednote-crawler — 小红书数据采集 MCP 服务

## 概述

本 skill 提供小红书的自动化数据采集能力，基于 Playwright 真实浏览器 + 双层反检测（playwright-stealth + browserforge）。

### 工作模式

通过 MCP 协议（stdio transport）暴露 5 个工具，pi 通过 subprocess 调用。MCP 服务在 pi 会话启动时自动打开，关闭时自动停止。

### 前置条件

- Python 3.10+ 已安装
- `uv` 包管理器已安装
- `config/settings.yaml` 已配置
- 已执行过 `uv run python scripts/verify_login.py` 完成扫码登录（登录态保存在 `auth_state/state.json`）

### 重新登录

如果登录态失效（工具返回 `LOGIN_EXPIRED` 错误），请在终端中运行：

```bash
cd /Users/yanzeyu/ai-lab/xiaohongshu-crawler
uv run python scripts/verify_login.py
```

然后重启 pi 或重新加载此 skill。

## MCP 工具列表

### 1. `check_login_status`

检查小红书登录状态。

- **返回**: `logged_in`（bool）、`browser_running`（bool）、`message`（str）
- **耗时**: 5-10 秒
- **调用时机**: 使用其他任何工具前应检查一次

### 2. `search_notes`

按关键词搜索小红书笔记，返回摘要列表。

- **参数**:
  - `keyword` (string, required): 搜索关键词
  - `max_count` (number, optional, default=20, range 1-50): 最多返回条数
- **返回**: 笔记摘要列表，每条含 `note_id` / `title` / `author` / `likes` / `note_url` 等
- **耗时**: 30-90 秒（含页面加载 + 瀑布流滚动）
- **超时**: 120 秒

### 3. `get_note_detail`

采集单篇小红书笔记的详情和评论。

- **参数**:
  - `note_url` (string, required): 笔记详情页完整 URL（如 `https://www.xiaohongshu.com/explore/{id}?xsec_token=...`）
  - `max_comments` (number, optional, default=20, range 0-50): 最多采集评论数
- **返回**: 笔记详情字典（含 `title` / `content` / `author` / `likes` / `collects` / `tags` / `images` / `comments` 等）
- **耗时**: 15-60 秒
- **超时**: 90 秒

### 4. `crawl_keyword`

完整采集流程：搜索关键词 → 采集笔记详情 + 评论 → 保存到本地文件。

- **参数**:
  - `keyword` (string, required): 搜索关键词
  - `max_notes` (number, optional, default=10, range 1-20): 最多采集笔记数
  - `max_comments` (number, optional, default=20, range 0-50): 每条笔记最多采集评论数
- **返回**: `keyword` / `search_count` / `detail_count` / `total_comments` / `summary`
- **耗时**: 2-15 分钟
- **超时**: 600 秒
- **建议**: 先用 `search_notes` 验证关键词是否有结果，再调用本工具

### 5. `get_saved_data`

查询本地已保存的采集数据文件列表。

- **参数**:
  - `keyword` (string, optional): 关键词过滤（不区分大小写，模糊匹配）
- **返回**: 文件列表，每条含 `path` / `keyword` / `created_at` / `size_bytes`
- **耗时**: < 1 秒

## 数据输出

采集的数据保存在 `data/` 目录下：

```
data/
├── raw/
│   ├── {keyword}_{timestamp}.json          # 搜索结果
│   └── notes_{keyword}_{timestamp}.json    # 笔记详情+评论
└── processed/
    └── {keyword}_{timestamp}.xlsx          # Excel 工作簿
        ├── Sheet 1: 搜索结果 (8 列)
        ├── Sheet 2: 笔记详情 (13 列)
        └── Sheet 3: 评论数据 (8 列)
```

## 配置

编辑 `config/settings.yaml` 可调整：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `crawler.keywords` | `["示例关键词"]` | 搜索关键词列表（`main.py` 使用） |
| `crawler.max_notes_per_keyword` | `20` | 每个关键词最多采集笔记数 |
| `crawler.max_comments_per_note` | `20` | 每条笔记最多采集评论数 |
| `crawler.scroll_pause` | `1.5` | 滚动后等待时间（秒） |
| `browser.headless` | `false` | 是否无头模式（MCP 默认 True） |

## 错误处理

所有工具在失败时返回统一的错误字典：

```json
{
  "error": true,
  "code": "BROWSER_NOT_RUNNING | BROWSER_CRASHED | LOGIN_EXPIRED | TIMEOUT | INVALID_INPUT | CRAWL_FAILED",
  "message": "人类可读的描述",
  "action": "建议的修复操作"
}
```

常见错误及处理：

| 错误码 | 含义 | 修复 |
|--------|------|------|
| `LOGIN_EXPIRED` | 登录态失效 | 终端运行 `uv run python scripts/verify_login.py` 重新登录后重启 |
| `BROWSER_CRASHED` | 浏览器崩溃 | 重启 MCP 服务 |
| `TIMEOUT` | 操作超时 | 减少采集数量后重试 |

## 使用示例

### 查询某个关键词的笔记

```
使用 search_notes 工具，关键词设为"Python爬虫教程"，max_count=10
```

### 获取某篇笔记的详情

```
先用 search_notes 找到笔记后得到 note_url，
再用 get_note_detail 传入该 URL，max_comments=30
```

### 完整采集某个话题

```
使用 crawl_keyword 工具，keyword="小红书运营技巧"，max_notes=15，max_comments=30
完成后用 get_saved_data 查看保存的文件
```

### 编程技巧类小红书内容调研

```
1. check_login_status 确认登录态
2. search_notes("Python入门教程", max_count=5) 搜索几个不同关键词
3. search_notes("编程学习", max_count=5)
4. 从结果中挑选热度高的笔记，用 get_note_detail 获取详情
5. 汇总热门标题和内容趋势
```
