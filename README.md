# dl-wake-fix

[English](#english) · [中文](#中文)

macOS 上 DisplayLink 双屏在熄屏唤醒后只回来一块屏的兜底修复。

A workaround for a DisplayLink bug on macOS: after the screens sleep and wake, only one of two external displays comes back.

写于 **JSAUX FlipGo Pro 16** 双屏便携显示器（DisplayLink "Hybrid Dock"，USB `17e9:6000`）+ **MacBook Air M5 / macOS 26.5.2**，但故障在 DisplayLink 而非显示器，任何 macOS 26 上的 DisplayLink 扩展坞都可能遇到。

---

## English

### The problem

One USB-C cable from the Mac to the FlipGo drives two 2560×1600 panels through DisplayLink, plus the built-in display — three distinct screens.

After the displays turn off (idle timeout, ⌃⌘Q lock, closing the lid) and then wake, **only one of the two FlipGo panels comes back**. The other never lights up. Unplugging and replugging the USB-C cable fixes it every time. Nothing else does — not waiting, not opening System Settings, not toggling "Detect Displays".

### Root cause

DisplayLink tears down both virtual displays when the screens sleep, then immediately tries to recreate them — while macOS is already inside its sleep window, so the recreation is rejected. It retries three times within 1.5 s and then **permanently gives up**, never recreating the display on wake.

```
13:51:55.349  kCGSDisplayWillSleep                      # screens go to sleep
13:52:05.954  CDVirtualDisplayDestroy(0x754c9adf0)      # D2 destroyed
13:52:05.955  CDVirtualDisplayDestroy(0x754f18fa0)      # D1 destroyed
13:52:05.960  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.466  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.973  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
```

On wake, DisplayLink only rebuilds the panel that *disappeared from its device list during sleep* — that panel is re-detected as a new device. The other panel stayed in the list the whole time, so nothing triggers its recreation:

```
13:53:34.378  FlipGo-D1  CGID = 0x0    isEnabled = true    # listed, bound to no display
              FlipGo-D2  CGID = 0x17   isEnabled = true    # recreated
```

`CGGetActiveDisplayList` returns an empty array while asleep while `CGGetOnlineDisplayList` still lists all three, so "is a screen missing" has to be judged from the *active* list.

Why this is a DisplayLink bug, not a hardware fault:

- The failure is in a pure software call (`spawnProxy`), not in the USB link — the dock enumerates once and never disconnects across a sleep/wake cycle.
- The same recreation occasionally succeeds (`kr=0x0` at 14:01:28 in the same session), so it is a race with the sleep window, not a stuck device.
- Restarting the DisplayLink process alone restores both screens in ~5 s, with no change to cable or monitor.
- Reproduces on **DisplayLink Manager 16.2.39 and 17.0.24** (macOS 26.5.2). Neither release note mentions a fix; there is no release newer than 17.0 as of October 2026.

The FlipGo's behaviour makes it easier to hit: its two panels enter low power differently (one leaves the DisplayLink device list, one doesn't) and its scaler is slow to wake, briefly reporting a fallback EDID.

### The fix

A launchd daemon polling once per second, restarting the DisplayLink agent when the screens are awake, the dock is present, and fewer than two external displays exist:

1. **Wake path (fast).** When `CGDisplayIsAsleep` flips to false, wait 3 s for the first panel. If the second is still missing, `killall DisplayLinkUserAgent` + `open -g -a "DisplayLink Manager"` forces a full rebuild. Measured **6 s from wake to both screens up**.
2. **Slow path.** Scenarios without a sleep transition (replugging) use a 10 s window, so it doesn't fight panels appearing one after another.
3. **Window layout restore.** Because DisplayLink destroys both virtual displays, macOS evicts every window that was on them. A helper records window positions while healthy and puts them back once both displays are up and the session is unlocked.

Restarting the agent is required — merely activating the already-running DisplayLink Manager does not recreate the missing display (tested: 16 s, no recovery).

---

## 中文

### 问题

一根 USB-C 线从 Mac 接 FlipGo，通过 DisplayLink 驱动两块 2560×1600 屏，加上内建屏共三块。

熄屏（空闲超时、⌃⌘Q 锁屏、合盖）后再唤醒，**两块 FlipGo 只有一块能亮**，另一块始终黑屏。插拔一次 USB-C 线必定恢复，其他手段都无效：等待、打开系统设置、重新检测显示器，都不行。

### 原因

DisplayLink 在熄屏时销毁两块虚拟显示屏，随即立刻重建，但此时 macOS 已经进入睡眠窗口，重建被拒绝。它在 1.5 秒内重试 3 次后**永久放弃**，亮屏时不再补建。

```
13:51:55.349  kCGSDisplayWillSleep                      # 熄屏
13:52:05.954  CDVirtualDisplayDestroy(0x754c9adf0)      # D2 被销毁
13:52:05.955  CDVirtualDisplayDestroy(0x754f18fa0)      # D1 被销毁
13:52:05.960  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.466  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.973  spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
```

亮屏后，DisplayLink 只重建了**熄屏期间从它的设备列表里消失过**的那块面板，因为那块被当作新设备重新检出。另一块全程留在列表里，没有任何事件触发它的重建：

```
13:53:34.378  FlipGo-D1  CGID = 0x0    isEnabled = true    # 在列表里，但没绑定任何显示器
              FlipGo-D2  CGID = 0x17   isEnabled = true    # 已重建
```

熄屏时 `CGGetActiveDisplayList` 返回空数组，而 `CGGetOnlineDisplayList` 仍列出全部三块，所以判断"是否缺屏"必须用 active 列表。

判断这是 DisplayLink 的软件缺陷、而非硬件故障的依据：

- 失败发生在纯软件调用（`spawnProxy`）里，与 USB 链路无关。内核日志显示扩展坞只在接入时枚挙一次，此后经历熄屏、亮屏全程从未断开。
- 同一会话里同类重建偶尔成功（14:01:28 报 `kr=0x0`），说明是与睡眠窗口的竞态，不是设备卡死。
- 只重启 DisplayLink 进程即可恢复两块屏，约 5 秒，线材和显示器都没动过。
- **DisplayLink Manager 16.2.39 与 17.0.24** 均可复现（macOS 26.5.2）。两个版本的更新说明都没提到修复，截至 2026 年 10 月也没有比 17.0 更新的版本。

FlipGo 的行为让这个 bug 更容易命中：两块面板进入低功耗的表现不一样（一块从 DisplayLink 设备列表消失，另一块不消失），而且它的主控唤醒较慢，会短暂上报兜底 EDID。

### 解决

一个 launchd 守护进程，每秒轮询一次；当屏幕醒着、扩展坞在线、外接屏少于 2 块时重启 DisplayLink 进程：

1. **唤醒路径（快）**：`CGDisplayIsAsleep` 由 true 变 false 后等 3 秒，若第二块屏仍未出现，执行 `killall DisplayLinkUserAgent` + `open -g -a "DisplayLink Manager"` 强制全量重建。实测**亮屏到两屏齐 6 秒**。
2. **慢速路径**：不经过熄屏的场景（拔插数据线）用 10 秒窗口兜底，避免和陆续出现的屏幕互相打架。
3. **窗口还原**：因为 DisplayLink 销毁了两块虚拟屏，macOS 会把上面的窗口全部挪走。独立帮手在系统正常时记录窗口位置，两块屏就位且解锁后摆回原位。

只执行 `open` 激活已在运行的 DisplayLink Manager 是无效的，必须重启进程（实测 16 秒无恢复）。

---

## Repository layout / 目录结构

| Path | Contents |
|---|---|
| `sources/main.swift` | daemon / 守护进程 |
| `sources/winlayout.swift` | window layout record & restore / 窗口记录与还原 |
| `bin/` | prebuilt binaries + SHA256SUMS |
| `launchd/` | LaunchAgent definition |
| `install.sh` | deploy to `~/Library/Scripts/dl-wake-fix/` |
| `docs/evidence.md` | raw log excerpts and reproduction commands / 日志证据与复现命令 |
| `docs/parameters.md` | every timing value with its measured justification / 参数取值依据 |
| `AGENTS.md` | constraints for AI agents working on this repo |

## Install / 安装

```sh
./install.sh
```

Then grant **Accessibility** to `~/Library/Scripts/dl-wake-fix/dl-winlayout` in System Settings → Privacy & Security → Accessibility.
然后在「系统设置 → 隐私与安全性 → 辅助功能」中给该程序授权。

Without it, screen recovery still works; only window restoration is skipped.
未授权时屏幕恢复仍正常，仅窗口还原不生效。

Logs / 日志：`~/Library/Logs/dl-wake-fix.log`
Pause / 暂停：`touch ~/Library/Scripts/dl-wake-fix/disabled`

## ⚠️ Note for contributors / 修改须知

Accessibility permission is bound to the binary's cdhash. **Recompiling `sources/winlayout.swift` invalidates the granted permission** and requires re-adding the binary in System Settings. Prefer changing `sources/main.swift`, which needs no permissions.

辅助功能授权绑定二进制的 cdhash。**重新编译 `sources/winlayout.swift` 会让已授予的权限失效**，必须在系统设置里重新添加。优先修改 `sources/main.swift`，它不需要任何权限。

## Status / 状态

Workaround, not a fix. It compensates for a driver defect that should be corrected inside DisplayLink Manager. If Synaptics ships a version that recreates the display on wake, delete this daemon.

这是兜底方案，不是修复。它绕过一个本该由 DisplayLink Manager 修正的驱动缺陷。如果 Synaptics 发布了能在唤醒时补建显示屏的版本，请删掉这个守护进程。
