# rednote-crawler 应用镜像
# 基于基础镜像（系统依赖 + Python + Chromium），仅覆盖源码
#
# 用法：
#   首次: docker build -f Dockerfile.base -t rednote-crawler-base .
#   日常: docker compose up -d --build   (秒级，只 COPY 源码)

FROM rednote-crawler-base:latest

# 复制源码（频繁变动，但只影响这一层）
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
