# 日志证据

采集环境：MacBook Air M17,3（Apple M5）、macOS 26.5.2 (25F84)、DisplayLink Manager 17.0.24 / 16.2.39、JSAUX FlipGo Pro 16（DisplayLink Hybrid Dock，USB 17e9:6000）。

## 1. 熄屏时重建失败

2026-10-09 13:51:55 熄屏（`kCGSDisplayWillSleep`）：

```
13:52:05.954  CDVirtualDisplayDestroy(0x754c9adf0)   # D2
13:52:05.955  CDVirtualDisplayDestroy(0x754f18fa0)   # D1
13:52:05.960  RPC spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.466  RPC spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
13:52:06.973  RPC spawnProxy client<-server displayID=0x0 kr=0x5((os/kern) failure)
```

三次失败后不再重试。

## 2. 亮屏后只回来一块屏

```
13:53:34.057  spawnProxy displayID=0x17 kr=0x0 成功后，DisplayLink 的显示器列表为：
              13:53:34.378  FlipGo-D1  CGID = 0x0   isEnabled = true
                            FlipGo-D2  CGID = 0x17  isEnabled = true
```

D1 留在列表里但 `CGID = 0x0`，没有绑定任何显示器；`system_profiler SPDisplaysDataType` 也只剩 FlipGo-D2。

对比：`CGGetActiveDisplayList` 在熄屏时返回空数组，`CGGetOnlineDisplayList` 仍返回 3 个（内建 + D1 + D2）。因此判断"缺屏"必须用 active 列表。

## 3. 重启进程可以恢复，仅插拔也能恢复

`killall DisplayLinkUserAgent` 后 `open -g -a "DisplayLink Manager"`，5 秒内 D1、D2 均以 2560×1600 恢复。实测进程退出只需 0.1～0.3 秒。

无效的手段（2026-10-09 实测）：只执行 `open -g -a "DisplayLink Manager"` 不杀进程，缺的屏 16 秒内没有回来。

## 4. DisplayLink 自身的触发时机

熄屏后约 10 秒销毁虚拟屏，此时系统已进入睡眠窗口。同一时刻另一处日志显示，偶尔（14:01:28）重建会成功（`kr=0x0`），说明是与睡眠窗口的竞态，不是确定性失败。

## 5. 版本对比

| 版本 | 结果 |
|---|---|
| 17.0.24 | 复现（15:13、15:14、15:48 三次） |
| 16.2.39 | 复现（13:52、13:59 两次） |

两个版本的更新说明均未提到该问题的修复；官方页面也没有比 17.0 更新的版本。

## 复现命令

```sh
pmset displaysleepnow                 # 熄屏
caffeinate -u -d -t 60 &              # 60 秒后自动唤醒
# 观察
log show --last 5m --predicate 'process CONTAINS "DisplayLink" AND eventMessage CONTAINS "spawnProxy"' --style compact
```
