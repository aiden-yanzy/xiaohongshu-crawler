# rednote-crawler Docker 部署

# ---- 构建阶段 ----
FROM python:3.10-slim AS builder

WORKDIR /app

# 安装 uv 包管理器
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# 先复制依赖文件，利用 Docker 缓存层
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# ---- 运行阶段 ----
FROM python:3.10-slim

WORKDIR /app

# 安装 Chromium 所需系统依赖 + 清理缓存减小镜像体积
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Playwright Chromium 依赖
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libdbus-1-3 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libpango-1.0-0 libcairo2 libasound2 \
    libatspi2.0-0 \
    # 工具
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# 从 builder 复制 uv 和虚拟环境
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY --from=builder /app/.venv /app/.venv

# 复制项目源码
COPY pyproject.toml ./
COPY mcp_server.py ./
COPY src/ ./src/
COPY config/ ./config/

# 安装 Playwright Chromium 浏览器（系统依赖已在前面手动安装）
RUN uv run playwright install chromium

# 创建挂载目录
RUN mkdir -p /app/auth_state /app/data /app/logs

# MCP SSE 服务端口
EXPOSE 8000

# 健康检查（SSE 是长连接，用超时方式检测端口可达性）
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -sf --max-time 3 http://localhost:8000/sse || [ $? -eq 28 ] || exit 1

# 启动 MCP 服务（SSE transport）
ENV PYTHONUNBUFFERED=1
CMD ["uv", "run", "python", "mcp_server.py", \
     "--transport", "sse", \
     "--host", "0.0.0.0", \
     "--port", "8000"]
