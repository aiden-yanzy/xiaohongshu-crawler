# Dockerfile — 登录专用镜像（带 noVNC 远程桌面）
# 基于主镜像，额外安装虚拟桌面 + VNC + noVNC

FROM rednote-crawler:latest

# 安装虚拟桌面 + VNC 工具 + noVNC 依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb x11vnc xauth procps fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*

# 用 uv 安装 websockify（noVNC 的 WebSocket 后端）
RUN uv pip install websockify --system

# 下载 noVNC 前端（纯静态文件）
ADD https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz /tmp/novnc.tar.gz
RUN tar -xzf /tmp/novnc.tar.gz -C /opt \
    && mv /opt/noVNC-* /opt/noVNC \
    && rm /tmp/novnc.tar.gz

# 登录启动脚本
COPY docker-entrypoint-login.sh /app/
RUN chmod +x /app/docker-entrypoint-login.sh

CMD ["/app/docker-entrypoint-login.sh"]
