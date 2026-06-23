#!/bin/bash
# rednote-crawler Docker 管理脚本
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="rednote-crawler"
CONTAINER="rednote-crawler"

case "${1:-help}" in
  build)
    echo "🔨 构建 Docker 镜像..."
    docker build -t "$IMAGE" "$PROJECT_DIR"
    echo "✅ 构建完成"
    ;;

  up|start)
    # 确保 auth_state 目录存在
    mkdir -p "$PROJECT_DIR/auth_state" "$PROJECT_DIR/data" "$PROJECT_DIR/logs"
    echo "🚀 启动 MCP 服务..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d
    echo "✅ 服务已启动 (http://localhost:18765/sse)"

    # 检查登录态
    sleep 3
    if [ -f "$PROJECT_DIR/auth_state/state.json" ]; then
      echo "✅ 登录态文件已加载"
    else
      echo "⚠️  未检测到登录态文件，Hermes 首次调用需先完成登录"
      echo "   请用本地命令完成登录后复制:"
      echo "   cp $PROJECT_DIR/auth_state/state.json 到容器同路径"
    fi
    ;;

  down|stop)
    echo "🛑 停止 MCP 服务..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" down
    echo "✅ 服务已停止"
    ;;

  restart)
    echo "🔄 重启 MCP 服务..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" restart
    echo "✅ 服务已重启"
    ;;

  logs)
    docker logs -f "$CONTAINER"
    ;;

  status)
    docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    ;;

  *)
    echo "用法: $0 {build|start|stop|restart|logs|status}"
    echo ""
    echo "  build    - 构建 Docker 镜像"
    echo "  start    - 启动 MCP 服务 (后台运行)"
    echo "  stop     - 停止 MCP 服务"
    echo "  restart  - 重启 MCP 服务"
    echo "  logs     - 查看实时日志"
    echo "  status   - 查看运行状态"
    echo ""
    echo "Hermes 配置地址: http://localhost:18765/sse"
    exit 1
    ;;
esac
