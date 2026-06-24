# rednote-crawler Docker 部署

# ---- 构建阶段（仅安装 Python 依赖）----
# digest 锁定避免每次拉取新版本导致缓存失效
FROM python:3.10-slim@sha256:fa184fce49c170a8b1032a4f752f9fe1a7e463e7f5795a3952ca275e166fa913 AS builder

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# ---- 运行阶段 ----
FROM python:3.10-slim@sha256:fa184fce49c170a8b1032a4f752f9fe1a7e463e7f5795a3952ca275e166fa913

WORKDIR /app

# 第 1 层：系统依赖（极少变动，永久缓存）
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libdbus-1-3 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libpango-1.0-0 libcairo2 libasound2 \
    libatspi2.0-0 \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# 第 2 层：uv + Python 依赖（pyproject.toml 变动才重建）
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY --from=builder /app/.venv /app/.venv
COPY pyproject.toml ./

# 第 3 层：Chromium 浏览器（playwright 版本变动才重建，~160MB，永久缓存）
RUN uv run playwright install chromium

# 第 4 层：项目源码（频繁变动，但不会触发上面几层重建）
COPY mcp_server.py ./
COPY src/ ./src/
COPY config/ ./config/

# 第 5 层：运行时目录
RUN mkdir -p /app/auth_state /app/data /app/logs

EXPOSE 8000

# 健康检查（SSE 是长连接，用超时方式检测端口可达性）
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -sf --max-time 3 http://127.0.0.1:8000/sse || [ $? -eq 28 ] || exit 1

ENV PYTHONUNBUFFERED=1
CMD ["uv", "run", "python", "mcp_server.py", \
     "--transport", "sse", \
     "--host", "0.0.0.0", \
     "--port", "8000"]
