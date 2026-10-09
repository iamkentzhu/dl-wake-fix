# dl-wake-fix 工作约束

给 agent 的行为约束。项目背景和部署方式见 `README.md`，故障原理和参数取舍见 `docs/`。

## 硬约束

- **不要重新编译 `sources/winlayout.swift`。** 辅助功能授权绑定 cdhash，重编译会让 Kent 已授予的权限失效，必须人工重新授权。需要改窗口逻辑时先问 Kent。
- **改动窗口行为优先落在 `sources/main.swift`**（守护进程，不需要任何权限）。
- **不要在没读 `docs/parameters.md` 的情况下调参数**：每个值都有实测依据，改前先看代价一栏。
- 验证必须在真实链路：`pmset displaysleepnow` + `caffeinate -u -d -t` 自动唤醒，或让 Kent 自然熄屏。不接受只在代码层推断就宣称修好。
- 报告结论时给日志时间戳，不要只给"已修复"。

## 环境事实

- 目标机器：Kent 的 MacBook Air（M5，macOS 26），FlipGo 双屏走 DisplayLink，是唯一使用场景。
- 守护进程由 launchd 常驻，日志 `~/Library/Logs/dl-wake-fix.log`，只在状态变化时写行。
- 暂停开关：`touch ~/Library/Scripts/dl-wake-fix/disabled`。
- `dl-winlayout` 的 `save` / `restore` / `check` 可以手动调用做验证，不会改授权。

## 已知限制（不要当成 bug 去修）

- 匹配窗口靠「App + 窗口标题」，标题变化的窗口可能对不上，保持原位不动属预期。
- 最小化、全屏、其他桌面空间的窗口不处理。
- 熄屏前最后 15 秒内挪动的窗口会被还原到挪动前的位置。
- 用户故意只接一块 FlipGo 屏时，慢速路径会误判并重启最多 3 次；用暂停开关规避。
