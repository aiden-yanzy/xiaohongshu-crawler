# rednote-crawler Docker 镜像
#
# 本地构建（仅当前架构）:
#   docker compose up -d --build
#
# 发布到 GitHub Container Registry（供 NAS 拉取）:
#   ./docker.sh push

FROM python:3.10-slim

WORKDIR /app

# 第 1 层：系统依赖（极少变动）
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libdbus-1-3 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libpango-1.0-0 libcairo2 libasound2 \
    libatspi2.0-0 \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# 第 2 层：uv + Python 依赖（pyproject.toml 变更时重建）
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# 第 3 层：Chromium 浏览器（playwright 版本变更时重建）
RUN uv run playwright install chromium

# 第 4 层：项目源码（频繁变动）
COPY mcp_server.py ./
COPY src/ ./src/
COPY config/ ./config/

# 运行时目录
RUN mkdir -p /app/auth_state /app/data /app/logs

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -sf --max-time 3 http://127.0.0.1:8000/sse || [ $? -eq 28 ] || exit 1

ENV PYTHONUNBUFFERED=1
CMD ["uv", "run", "python", "mcp_server.py", \
     "--transport", "sse", \
     "--host", "0.0.0.0", \
     "--port", "8000"]
