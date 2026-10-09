#!/bin/bash
# 部署 dl-wake-fix 到 ~/Library/Scripts/dl-wake-fix/ 并加载 LaunchAgent
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/Library/Scripts/dl-wake-fix"
PLIST="$HOME/Library/LaunchAgents/com.kent.dl-wake-fix.plist"
DOMAIN="gui/$(id -u)"

mkdir -p "$DST"
install -m 755 "$SRC/bin/dl-wake-fix" "$DST/dl-wake-fix"
install -m 755 "$SRC/bin/dl-winlayout" "$DST/dl-winlayout"
install -m 644 "$SRC/sources/main.swift" "$DST/main.swift"
install -m 644 "$SRC/sources/winlayout.swift" "$DST/winlayout.swift"

# 占位替换：plist 里的路径按当前用户生成
sed "s|/Users/[^/]*/Library/Scripts/dl-wake-fix|$HOME/Library/Scripts/dl-wake-fix|" \
    "$SRC/launchd/com.kent.dl-wake-fix.plist" > "$PLIST"

rm -f "$DST/disabled"
launchctl bootout "$DOMAIN/com.kent.dl-wake-fix" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/com.kent.dl-wake-fix"

echo "已部署到 $DST"
echo "日志：$HOME/Library/Logs/dl-wake-fix.log"
echo
echo "还需要一步人工操作："
echo "  系统设置 → 隐私与安全性 → 辅助功能 → 添加 $DST/dl-winlayout"
echo "  未授权时窗口还原不生效，屏幕恢复仍然正常。"
