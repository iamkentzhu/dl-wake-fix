# 事件式窗口布局原型

此实现独立于 `dl-winlayout`，由同一个 Aqua LaunchAgent 启动救屏逻辑和窗口助手。
默认安装方式仍然不变；下面的命令显式切换新版。旧辅助程序不会被修改或重编译。

- 窗口移动、缩放、打开和桌面切换会触发一次去抖合并后的快照，不再每 15 秒保存。
- 只记录两块 FlipGo 上的窗口，保存相对于目标面板的坐标。熄屏或断开时保留最后一次双屏快照。
- 双屏回来且解锁后按 App 和窗口标题匹配；匹配不唯一时不移动窗口。延迟出现的窗口有有限次补试，已就位的窗口不会反复套用布局。
- 补试结束仍未归位的窗口保留旧位置；其他窗口变化、错屏位置和匹配歧义均不会覆盖它。该窗口回到记录的位置后解除保护。若服务在断开与还原之间重启，会先继续还原再接受新位置。
- 普通窗口可以恢复位置和尺寸，包括非原生全屏的半屏平铺。
- 单窗口原生全屏已在正确面板时不操作。显式启用 `--restore-full-screen` 后，才会尝试把错位或已退出全屏的单窗口移动并重新全屏。它不承诺重建桌面顺序。
- Split View 与其他无法确认是独立全屏的窗口只检测和记录，不自动解组。公开辅助功能 API 不提供恢复 Split View 配对的接口；需要自动恢复两窗口并排时，可改用非全屏平铺。

### 安装与回退

```sh
bash install-event-layout.sh
# 仅当希望自动尝试恢复单窗口原生全屏时：
bash install-event-layout.sh --restore-full-screen
```

在「辅助功能」里只需允许 `FlipGo Window Layout`。授权后如助手已退出，重新运行上面的安装命令即可。
脚本保留已经签名的窗口应用，更新救屏程序时不会打掉现有窗口权限。没有授权时，后台服务仍然能救屏。
新版启用后旧助手不会再保存或恢复窗口。之前的 LaunchAgent 配置保存在
`~/Library/Scripts/dl-wake-fix/event-layout/previous-agent.plist`，如需回退，可以停载当前服务，再复制回
`~/Library/LaunchAgents/com.kent.dl-wake-fix.plist` 并重新加载；旧窗口助手需恢复授权。

首次调试可直接启动独立助手的 `--observe-only` 模式：该模式保存本地快照、记录匹配情况，不移动窗口或切换全屏。
不要在新版 LaunchAgent 已经运行时并行启动独立助手。

```sh
app="/path/to/FlipGo Window Layout.app"
mkdir -p "$app/Contents/MacOS"
cp launchd/LayoutEvents-Info.plist "$app/Contents/Info.plist"
xcrun swiftc -O -warnings-as-errors sources/layout-events.swift -o "$app/Contents/MacOS/layout-events"
codesign --sign - "$app"
"$app/Contents/MacOS/layout-events" --self-test
open -g "$app" --args --observe-only
```

快照包含窗口标题，保存在当前用户的 `Library/Scripts/dl-wake-fix/event-layout/windows-v2.json`，不上传。
此前的 `windows.json` 会被读取迁移，原文件保留用于回退。日志只记录窗口类别和数量。

### 实机验证（2026-11-28，UTC+8）

- 00:42:44：同一个 Aqua LaunchAgent 启动救屏程序和窗口助手，未重新签名已获授权的窗口应用。
- 00:42:45：窗口助手以可恢复模式启动，保留 D1、D2 各一个全屏窗口的快照。
- 00:48:51、00:48:54：D1 上的普通测试窗口被记录，随后一次移动事件更新了相对坐标；未等待 15 秒周期。
- 00:49:03：关闭测试窗口后，下一份快照只剩两块屏原来的全屏窗口。

以上验证了部署、权限和事件式保存，不等于验证了错位全屏或普通窗口跨屏还原。
