#!/bin/bash
# Docker 登录容器入口 — 启动虚拟桌面 + VNC + 浏览器
set -e

echo "============================================"
echo "  小红书 Docker 远程登录"
echo "============================================"
echo ""

# 1. 启动 Xvfb 虚拟显示器
Xvfb :99 -screen 0 1280x900x24 -ac &
XVFB_PID=$!
sleep 1
echo "✅ 虚拟显示器启动 (1280x900)"

# 2. 启动 x11vnc（将虚拟显示器暴露为 VNC）
x11vnc -display :99 -forever -nopw -quiet -listen 0.0.0.0 -rfbport 5900 &
VNC_PID=$!
sleep 1
echo "✅ VNC 服务启动 (端口 5900)"

# 3. 启动 websockify + noVNC（将 VNC 转为浏览器可访问的 WebSocket）
python3 -m websockify --web /opt/noVNC 6080 localhost:5900 &
NOVNC_PID=$!
sleep 2
echo "✅ noVNC 启动 (端口 6080)"
echo ""
echo "============================================"
echo "  👉 浏览器打开 http://服务器IP:18766"
echo "  在 VNC 窗口中完成小红书扫码登录"
echo "  登录完成后按 Ctrl+C 退出"
echo "  登录态会自动保存到 auth_state/state.json"
echo "============================================"
echo ""

# 4. 运行登录脚本（在虚拟显示器中打开浏览器）
cleanup() {
    echo ""
    echo "正在清理..."
    kill $NOVNC_PID $VNC_PID $XVFB_PID 2>/dev/null
    exit 0
}
trap cleanup INT TERM

DISPLAY=:99 uv run python -c '
import asyncio, sys
from src.browser import BrowserManager, AUTH_STATE_PATH

async def main():
    async with BrowserManager(headless=False) as bm:
        page = await bm.new_page()
        await page.goto("https://www.xiaohongshu.com/explore")
        print("[浏览器已打开] 请在 VNC 中完成登录...")
        print("[等待登录] (最长 10 分钟)")

        for i in range(300):
            await asyncio.sleep(2)
            # 检查登录状态：登录按钮消失且有用户信息
            btn = await page.query_selector(".side-bar-component.login-btn")
            if btn is None:
                el = await page.query_selector(
                    "a[href*=\"/user/profile/\"]:not([href*=\"explore_feed\"])"
                )
                if el:
                    name = (await el.inner_text()).strip()
                    if name:
                        print(f"✅ 检测到登录用户: {name}")
                        await bm.save_state()
                        print(f"✅ 登录态已保存: {AUTH_STATE_PATH}")
                        print("")
                        print("现在可以关闭此容器，启动正常 MCP 服务：")
                        print("  docker compose -f docker-compose.login.yml down")
                        print("  docker compose up -d")
                        return
            if i % 30 == 0 and i > 0:
                print(f"  ⏳ 等待中... {i*2}秒")
        print("❌ 超时")

asyncio.run(main())
'

echo ""
echo "登录脚本结束。如需重新登录，重新运行此容器即可。"
wait
