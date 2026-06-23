#!/bin/bash
# Docker 重新登录脚本
#
# 用法:
#   ./docker-login.sh              # 自动检测：有显示器用本地浏览器，无显示器提示用 noVNC
#   ./docker-login.sh local        # 强制本地浏览器登录
#   ./docker-login.sh remote       # noVNC 远程登录（Linux 服务器）
#   ./docker-login.sh scp 服务器IP # 从本地 scp 登录态到服务器

set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="rednote-crawler"

case "${1:-auto}" in
  local)
    echo "🔑 本地浏览器登录..."
    cd "$PROJECT_DIR"
    uv run python -c '
import asyncio
from src.browser import BrowserManager, AUTH_STATE_PATH
async def main():
    async with BrowserManager(headless=False) as bm:
        page = await bm.new_page()
        await page.goto("https://www.xiaohongshu.com/explore")
        print("请在浏览器中完成扫码登录")
        print("等待登录... (最长 5 分钟)")
        for i in range(150):
            await asyncio.sleep(2)
            btn = await page.query_selector(".side-bar-component.login-btn")
            if btn is None:
                el = await page.query_selector("a[href*=\"/user/profile/\"]:not([href*=\"explore_feed\"])")
                if el:
                    name = (await el.inner_text()).strip()
                    if name:
                        print(f"✅ 检测到用户: {name}")
                        await bm.save_state()
                        print(f"✅ 登录态已保存: {AUTH_STATE_PATH}")
                        return
            if i % 30 == 0: print(f"  ⏳ {i*2}秒")
        print("❌ 超时")
asyncio.run(main())
    ' 2>&1
    echo "✅ 完成"
    ;;

  remote)
    echo "🌐 启动 noVNC 远程登录容器..."
    echo "   启动后浏览器打开 http://服务器IP:18766 即可看到登录页面"
    echo ""

    # 先构建登录镜像（首次需要，后续有缓存）
    docker compose -f "$PROJECT_DIR/docker-compose.login.yml" build

    # 启动登录容器
    docker compose -f "$PROJECT_DIR/docker-compose.login.yml" up

    echo ""
    echo "登录完成后，auth_state/state.json 已更新"
    echo "运行 docker compose up -d 启动正常 MCP 服务"
    ;;

  scp)
    SERVER="${2:?请指定服务器地址，例如: ./docker-login.sh scp user@192.168.1.100}"
    echo "📤 上传登录态到 $SERVER..."
    ssh "$SERVER" "mkdir -p $(pwd)/auth_state"
    scp "$PROJECT_DIR/auth_state/state.json" "$SERVER:$(pwd)/auth_state/state.json"
    echo "✅ 已上传"
    echo "   在服务器上执行: docker compose restart"
    ;;

  auto|*)
    # 自动检测
    if [ -n "$DISPLAY" ] || [ "$(uname)" = "Darwin" ]; then
      echo "🖥️  检测到图形环境，使用本地浏览器登录"
      exec "$0" local
    elif [ -f /.dockerenv ] || [ -n "$SSH_TTY" ]; then
      echo "🖥️  检测到服务器环境"
      echo ""
      echo "  请选择登录方式:"
      echo "    ./docker-login.sh remote  - 启动 noVNC 远程登录（浏览器打开 18766 端口）"
      echo "    ./docker-login.sh scp IP  - 从本地 scp 登录态到服务器"
    else
      exec "$0" local
    fi
    ;;
esac
