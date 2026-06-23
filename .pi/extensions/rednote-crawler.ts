/**
 * rednote-crawler pi extension
 *
 * 自动启动小红书 MCP 服务（Python），注册工具供 pi 代理调用。
 *
 * 工作方式：
 *   1. session_start 时，以 SSE 模式启动 Python MCP 服务器（子进程）
 *   2. 连接 SSE 端点获取 session_id，建立 JSON-RPC 通信通道
 *   3. 注册 5 个工具，每个工具通过 HTTP POST 调用 MCP 服务
 *   4. session_end 时，关闭子进程
 *
 * 前置条件：
 *   - Python 3.10+ + uv 已安装
 *   - 已运行过 `uv run python scripts/verify_login.py` 完成扫码登录
 *   - 项目根目录为 cwd
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { spawn, type ChildProcess } from "child_process";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

// ============================================================
// 配置
// ============================================================

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PROJECT_DIR = resolve(__dirname, "../..");
const MCP_SERVER_SCRIPT = "mcp_server.py";
const MCP_HOST = "127.0.0.1";
const MCP_PORT = 8765; // 用不常见端口避免冲突
const MCP_TIMEOUT_MS = 600_000; // 单个工具调用最大等待 10 分钟

const TOOL_CONFIGS: Record<string, { timeout: number }> = {
  search_notes: { timeout: 130_000 },
  get_note_detail: { timeout: 100_000 },
  crawl_keyword: { timeout: 610_000 },
  check_login_status: { timeout: 20_000 },
  get_saved_data: { timeout: 5_000 },
};

// ============================================================
// SSE MCP 客户端
// ============================================================

interface PendingRequest {
  resolve: (data: unknown) => void;
  reject: (err: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
}

class SseMcpClient {
  private process: ChildProcess | null = null;
  private sessionId: string = "";
  private messageUrl: string = "";
  private aborter: AbortController | null = null;
  private pending = new Map<number, PendingRequest>();
  private nextId = 1;
  private connected = false;

  async start(): Promise<void> {
    const serverUrl = `http://${MCP_HOST}:${MCP_PORT}`;

    // 启动 Python MCP 服务器（SSE 模式）
    this.process = spawn("uv", [
      "run", "python", MCP_SERVER_SCRIPT,
      "--transport", "sse",
      "--host", MCP_HOST,
      "--port", String(MCP_PORT),
    ], {
      cwd: PROJECT_DIR,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env },
    });

    this.process.stdout?.on("data", (data: Buffer) => {
      const text = data.toString();
      if (text.includes("Uvicorn running on")) {
        // Server is ready, connect SSE
        this.connectSse(serverUrl);
      }
    });

    this.process.stderr?.on("data", (data: Buffer) => {
      // Server logs go to stderr, ignore them unless error
      const text = data.toString().toLowerCase();
      if (text.includes("error") || text.includes("traceback") || text.includes("exception")) {
        console.error("[rednote-crawler]", data.toString().trim());
      }
    });

    this.process.on("exit", (code) => {
      console.error(`[rednote-crawler] MCP server exited with code ${code}`);
      this.connected = false;
    });

    // Wait for server to be ready
    await this.waitForConnection(serverUrl);
  }

  private async connectSse(serverUrl: string): Promise<void> {
    this.aborter = new AbortController();

    try {
      const response = await fetch(`${serverUrl}/sse`, {
        signal: this.aborter.signal,
      });

      if (!response.ok || !response.body) {
        throw new Error(`SSE connection failed: ${response.status}`);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      // Parse SSE events
      const readLoop = async () => {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";

          let eventType = "";
          let data = "";

          for (const line of lines) {
            if (line.startsWith("event: ")) {
              eventType = line.slice(7).trim();
            } else if (line.startsWith("data: ")) {
              data = line.slice(6).trim();
            } else if (line === "") {
              // Empty line = end of event
              if (eventType === "endpoint") {
                this.messageUrl = data;
                // Extract session_id from URL
                const match = data.match(/session_id=([^&]+)/);
                if (match) {
                  this.sessionId = match[1];
                  this.connected = true;
                  console.error(`[rednote-crawler] MCP client connected (session=${this.sessionId})`);
                }
              } else if (eventType === "message" || eventType === "data") {
                this.handleMessage(data);
              }
              eventType = "";
              data = "";
            }
          }
        }
      };

      readLoop().catch((err) => {
        if (!this.aborter?.signal.aborted) {
          console.error(`[rednote-crawler] SSE read error: ${err}`);
        }
      });
    } catch (err) {
      if (!this.aborter?.signal.aborted) {
        console.error(`[rednote-crawler] SSE connection error: ${err}`);
      }
    }
  }

  private handleMessage(data: string): void {
    try {
      const msg = JSON.parse(data);
      if (msg.id != null && this.pending.has(msg.id)) {
        const pending = this.pending.get(msg.id)!;
        clearTimeout(pending.timeout);
        this.pending.delete(msg.id);

        if (msg.error) {
          pending.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        } else {
          // MCP returns result.content[0].text for text responses
          const content = msg.result?.content;
          if (content && content.length > 0) {
            const textItem = content.find((c: { type: string }) => c.type === "text");
            if (textItem) {
              try {
                pending.resolve(JSON.parse(textItem.text));
              } catch {
                pending.resolve(textItem.text);
              }
            } else {
              pending.resolve(msg.result);
            }
          } else {
            pending.resolve(msg.result);
          }
        }
      }
    } catch {
      // ignore parse errors
    }
  }

  private async waitForConnection(serverUrl: string, timeoutMs = 20_000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (this.connected) return;
      await sleep(200);
    }
    throw new Error("MCP client connection timeout");
  }

  async callTool(toolName: string, args: Record<string, unknown>, timeoutMs: number): Promise<unknown> {
    if (!this.connected || !this.messageUrl) {
      throw new Error("MCP client not connected");
    }

    const id = this.nextId++;
    const fullUrl = `http://${MCP_HOST}:${MCP_PORT}${this.messageUrl}`;

    const body = JSON.stringify({
      jsonrpc: "2.0",
      id,
      method: "tools/call",
      params: { name: toolName, arguments: args },
    });

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Tool ${toolName} timed out after ${timeoutMs / 1000}s`));
      }, timeoutMs);

      this.pending.set(id, { resolve, reject, timeout });

      fetch(fullUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      }).catch((err) => {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(new Error(`HTTP request failed: ${err.message}`));
      });
    });
  }

  async stop(): Promise<void> {
    this.aborter?.abort();
    this.connected = false;

    // Reject all pending requests
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("MCP client shutting down"));
    }
    this.pending.clear();

    if (this.process) {
      this.process.kill("SIGTERM");
      // Wait briefly for graceful shutdown
      await sleep(1000);
      if (this.process.exitCode === null) {
        this.process.kill("SIGKILL");
      }
      this.process = null;
    }
  }
}

// ============================================================
// Helper
// ============================================================

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ============================================================
// Extension 入口
// ============================================================

const mcpClient = new SseMcpClient();

export default async function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.notify("正在启动小红书 MCP 服务...", "info");

    try {
      await mcpClient.start();
      ctx.ui.notify("小红书 MCP 服务就绪 ✓", "success");
    } catch (err) {
      ctx.ui.notify(`小红书 MCP 服务启动失败: ${err}`, "error");
      console.error("[rednote-crawler] Failed to start MCP server:", err);
    }
  });

  pi.on("session_end", async () => {
    await mcpClient.stop();
  });

  // ============================================================
  // 注册工具
  // ============================================================

  // 1. check_login_status
  pi.registerTool({
    name: "check_login_status",
    label: "检查小红书登录状态",
    description: "检查小红书登录状态。未登录时请运行 `uv run python scripts/verify_login.py` 完成扫码登录后重启。",
    parameters: Type.Object({}),
    async execute() {
      if (!mcpClient.connected) {
        return {
          content: [{ type: "text", text: JSON.stringify({
            error: true,
            code: "MCP_NOT_CONNECTED",
            message: "MCP 服务未连接。请检查 MCP 服务是否正常启动。",
            action: "重启 pi 或运行 /reload",
          }) }],
          details: {},
        };
      }
      const result = await mcpClient.callTool("check_login_status", {}, TOOL_CONFIGS.check_login_status.timeout);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], details: { result } };
    },
  });

  // 2. search_notes
  pi.registerTool({
    name: "search_notes",
    label: "搜索小红书笔记",
    description: "按关键词搜索小红书笔记，返回摘要列表（标题、作者、点赞数、链接等）。搜索前请确认登录态有效。",
    parameters: Type.Object({
      keyword: Type.String({ description: "搜索关键词（必填）" }),
      max_count: Type.Optional(Type.Number({ description: "最多返回笔记数（默认 20，范围 1-50）", default: 20 })),
    }),
    async execute(_id, params) {
      const result = await mcpClient.callTool("search_notes", params as Record<string, unknown>, TOOL_CONFIGS.search_notes.timeout);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], details: { result } };
    },
  });

  // 3. get_note_detail
  pi.registerTool({
    name: "get_note_detail",
    label: "采集笔记详情",
    description: "采集单篇小红书笔记的详情（标题、正文、互动数据、标签、图片列表）和评论列表。需要完整笔记 URL。",
    parameters: Type.Object({
      note_url: Type.String({ description: "笔记详情页完整 URL，如 https://www.xiaohongshu.com/explore/{id}?xsec_token=..." }),
      max_comments: Type.Optional(Type.Number({ description: "最多采集评论数（默认 20，范围 0-50）", default: 20 })),
    }),
    async execute(_id, params) {
      const result = await mcpClient.callTool("get_note_detail", params as Record<string, unknown>, TOOL_CONFIGS.get_note_detail.timeout);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], details: { result } };
    },
  });

  // 4. crawl_keyword
  pi.registerTool({
    name: "crawl_keyword",
    label: "完整采集关键词",
    description: "完整流程：搜索关键词 → 采集笔记详情 + 评论 → 保存到本地文件。操作耗时较长（2-15分钟）。建议先用 search_notes 验证关键词。",
    parameters: Type.Object({
      keyword: Type.String({ description: "搜索关键词（必填）" }),
      max_notes: Type.Optional(Type.Number({ description: "最多采集笔记数（默认 10，范围 1-20）", default: 10 })),
      max_comments: Type.Optional(Type.Number({ description: "每条笔记最多采集评论数（默认 20，范围 0-50）", default: 20 })),
    }),
    async execute(_id, params) {
      const result = await mcpClient.callTool("crawl_keyword", params as Record<string, unknown>, TOOL_CONFIGS.crawl_keyword.timeout);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], details: { result } };
    },
  });

  // 5. get_saved_data
  pi.registerTool({
    name: "get_saved_data",
    label: "查询已保存数据",
    description: "查询本地已保存的采集数据文件列表（JSON/Excel），可按关键词模糊过滤。不传参数返回全部文件。",
    parameters: Type.Object({
      keyword: Type.Optional(Type.String({ description: "关键词过滤（可选，不区分大小写，模糊匹配）" })),
    }),
    async execute(_id, params) {
      const result = await mcpClient.callTool("get_saved_data", params as Record<string, unknown>, TOOL_CONFIGS.get_saved_data.timeout);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], details: { result } };
    },
  });
}
