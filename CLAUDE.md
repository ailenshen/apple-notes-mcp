# Apple Notes MCP Server

## 项目目标

一个简洁的 Apple Notes MCP server，让 LLM 通过 MCP 协议读写 Apple Notes。

前置条件：macOS 26 (Tahoe) 或以上。

---

## 使用方式

### 安装

```bash
cd /Users/elonshen/Documents/Projects/apple-notes-mcp
npm install
npm run build
```

### 配置 Claude Code

在 `~/.claude/settings.json` 中添加：

```json
{
  "mcpServers": {
    "apple-notes": {
      "command": "node",
      "args": ["/Users/elonshen/Documents/Projects/apple-notes-mcp/dist/index.js"]
    }
  }
}
```

### 配置 Claude Desktop

在 `~/Library/Application Support/Claude/claude_desktop_config.json` 中添加同样的配置。

### 权限要求

- **Accessibility 权限**：系统设置 → 隐私与安全 → 辅助功能
  - 用于 System Events 自动点击 Import 确认弹窗
  - 需要授权的是 **`node`**（不是终端应用），因为 MCP server 以 `node` 子进程运行，系统会提示为 node 申请权限
  - `node` 路径通常为 `/usr/local/bin/node` 或 Homebrew 的 `/opt/homebrew/bin/node`
- **NoteStore.sqlite 读取**：全磁盘访问权限，同样授权给 `node`

### 运行测试

```bash
npm test
```

集成测试会创建一个带 UUID 后缀的临时笔记，走完 create → verify → update → verify → delete → verify 全流程，最后验证原有笔记数量未变。

---

## 架构总览

```
Claude Code / Claude Desktop（本地 stdio）
    │
    ▼
MCP Server（stdio transport）
    │
    ├─ 读 ── SQLite 直连（列表/搜索）
    │         + AppleScript（单篇正文 HTML，直接返回）
    │
    ├─ 写 ── 临时 .md → open -g -a Notes → 自动确认 Import
    │         → 移动到目标文件夹 → show 选中笔记
    │         → 清理 Imported Notes → 切回原前台应用
    │
    └─ 删 ── AppleScript
```

### 文件结构

```
src/
├── index.ts          # MCP server 入口，注册 5 个工具，stdio transport
├── db.ts             # SQLite 直连 NoteStore.sqlite（readonly），list/search/find 查询
├── applescript.ts    # AppleScript 封装：读正文、创建、删除
└── test.ts           # 集成测试：create → get → update → get → delete → get
```

---

## 传输层决策

### 第一阶段：stdio（本地直连）

MCP server 通过 stdio transport 运行，Claude Code 或 Claude Desktop 直接以子进程方式启动。

优势：
- **零认证**：不需要 OAuth、不需要网络，进程间直接通信
- **最快上线**：省掉 Express、auth 整套代码，只需实现 MCP 工具逻辑
- **调试简单**：本地进程，日志直接看

### 第二阶段（未来）：Streamable HTTP + OAuth 2.1

如果需要远程接入 Claude Web，再加 Express + OAuth 层。当前不实现。

---

## MCP 工具集（5 个）

| 工具 | 参数 | 说明 |
|------|------|------|
| `list_notes` | `folder?`, `limit?` | SQLite 查询，返回标题、文件夹、日期、是否置顶等全部元数据 |
| `search_notes` | `query`, `limit?` | SQLite LIKE 搜索标题和摘要 |
| `get_note` | `title`, `folder?` | AppleScript 读正文，直接返回 HTML |
| `create_note` | `markdown`, `folder?` | 导入 .md → 移动到目标文件夹 → 选中 → 清理 |
| `delete_note` | `title`, `folder?` | AppleScript 删除（移入 Recently Deleted） |

**update = delete + create**，不单独提供 update 工具。

---

## 关键决策

### 1. 读列表/搜索 — SQLite 直连

AppleScript 遍历 900+ 篇笔记超 30 秒超时。SQLite 直连 `NoteStore.sqlite`（WAL + readonly）< 100ms，不锁库。

### 2. 读正文 — AppleScript HTML 直接返回

- SQLite 中正文是 gzip + protobuf 私有格式，逆向不可靠，排除
- AppleScript `note.body()` 返回官方 HTML，单篇 ~1s 可接受
- **不做 HTML → Markdown 转换**：LLM 直接读 HTML，省掉依赖和转换层

### 3. 写入 — `open -a Notes` 原生 Markdown 导入

| 候选方案 | 淘汰原因 |
|----------|----------|
| AppleScript 写 HTML | 需逆向维护 Notes 私有 HTML 方言 |
| AppleScript 触发菜单 | 依赖 UI 布局，菜单变动即失效 |
| Shortcuts CLI | 需手动预建 workflow，非开箱即用 |
| **`open -a Notes`** | **选中：零依赖、原生解析、一行命令** |

#### 导入完整流程（后台执行）

`open -g -a Notes` 导入的笔记会自动落入 "Imported Notes" 文件夹。完整的 create_note 流程：

```
1. 记住当前前台应用
2. 写临时 .md 到 /tmp/
3. open -g -a Notes /tmp/note.md（-g 避免 Notes 抢焦点）
4. System Events 自动点击 Import 确认 sheet，返回前台应用名
5. 等待 Notes 处理完成
6. 通过首行内容（笔记标题）在 Imported Notes 中定位新笔记
7. AppleScript 将笔记移动到用户指定的目标文件夹
8. show 选中该笔记（下次打开 Notes 时直接可见）
9. 若 Imported Notes 文件夹已空，删除该文件夹
10. 切回原前台应用
11. 删除临时 .md 文件
```

需要 Accessibility 权限（用于 System Events 自动点击 Import sheet）。

### 4. 笔记标识 — 首行文本（ZTITLE1）

已验证：SQLite `ZTITLE1` = 笔记首行纯文本。同时有 `ZIDENTIFIER`（UUID）可做精确匹配。导入后通过首行内容在 Imported Notes 文件夹中定位。

### 5. 更新策略 — 删除 + 重建

1. 通过 ZTITLE1 或 ZIDENTIFIER 定位目标笔记，记录其所在文件夹
2. AppleScript 删除原笔记
3. `open -a Notes` 导入新版本（走完整 create 流程，移动到原文件夹）

### 6. 传输层 — 先 stdio，后 HTTP

先用 stdio 本地直连跑通全部功能，远程接入作为未来扩展。省掉 Express + OAuth 整套代码。

---

## Markdown 渲染支持（Notes 自身限制）

| 元素 | 结果 |
|------|------|
| 标题 / 加粗 / 斜体 / 列表 / 行内代码 | ✅ |
| 引用块 | ⚠️ 内容保留，无缩进样式 |
| 链接 | ⚠️ 文字保留，href 丢失 |
| 表格 / 脚注 | ❌ 不支持 |

---

## 数据流

| 操作 | 路径 | 速度 |
|------|------|------|
| list_notes / search_notes | SQLite + JOIN | < 100ms |
| get_note | AppleScript → HTML | ~1s |
| create_note | .md → open → 确认 → 移动 → 选中 → 切回 | ~3-4s |
| delete_note | AppleScript | ~1s |
| update_note（逻辑） | delete + create | ~4-5s |
