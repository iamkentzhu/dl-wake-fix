// 亮屏后检查 DisplayLink 外接屏数量，不足则重启 DisplayLinkUserAgent 触发全量重建
// 背景：DisplayLink 熄屏时重建虚拟屏撞上睡眠窗口失败(kr=0x5)且不重试，导致亮屏后 FlipGo 一块屏挂空
import AppKit
import IOKit

let expectedPanels: Set<String> = ["FlipGo-D1", "FlipGo-D2"]
let wakeDelay: TimeInterval = 3
let reconnectDelay: TimeInterval = 10
let log = FileHandle(forWritingAtPath: NSHomeDirectory() + "/Library/Logs/dl-wake-fix.log")
    ?? { FileManager.default.createFile(atPath: NSHomeDirectory() + "/Library/Logs/dl-wake-fix.log", contents: nil)
         return FileHandle(forWritingAtPath: NSHomeDirectory() + "/Library/Logs/dl-wake-fix.log")! }()
let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
func say(_ s: String) {
    log.seekToEndOfFile()
    log.write("\(fmt.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

func activePanels() -> Set<String> {
    let names = NSScreen.screens.compactMap { screen -> String? in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsActive(number.uint32Value) != 0,
              CGDisplayIsBuiltin(number.uint32Value) == 0 else { return nil }
        return screen.localizedName
    }
    return Set(names)
}

func flipGoMatching() -> CFDictionary {
    var query = IOServiceMatching("IOUSBHostDevice") as? [String: Any] ?? [:]
    query["idVendor"] = 0x17e9
    query["idProduct"] = 0x6000
    return query as CFDictionary
}

func dockPresent() -> Bool {
    let device = IOServiceGetMatchingService(kIOMainPortDefault, flipGoMatching())
    guard device != 0 else { return false }
    IOObjectRelease(device)
    return true
}

// 窗口布局交给独立二进制 dl-winlayout（辅助功能授权绑定其 cdhash，本文件改动不影响授权）
// 用 disclaim 方式 spawn：否则 TCC 按父进程 dl-wake-fix 判权限，子进程拿不到授权
typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
let disclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
    .map { unsafeBitCast($0, to: DisclaimFn.self) }

func winlayout(_ cmd: String) {
    let path = NSHomeDirectory() + "/Library/Scripts/dl-wake-fix/dl-winlayout"
    var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
    _ = disclaim?(&attr, 1)
    var fa: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
    var fds: [Int32] = [0, 0]; pipe(&fds)
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
    posix_spawn_file_actions_addclose(&fa, fds[0])
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup(cmd), nil]
    defer { argv.forEach { free($0) } }
    let rc = posix_spawn(&pid, path, &fa, &attr, argv, environ)
    close(fds[1])
    guard rc == 0 else { close(fds[0]); say("winlayout \(cmd) spawn failed rc=\(rc)"); return }
    let out = String(data: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile(), encoding: .utf8) ?? ""
    var st: Int32 = 0; waitpid(pid, &st, 0)
    // save 每 15s 一次，日志只记失败；restore 全记
    if cmd == "restore" || st != 0 {
        out.split(separator: "\n").forEach { say("winlayout \(cmd): \($0)") }
    }
}

func screenLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

let layoutPath = NSHomeDirectory() + "/Library/Scripts/dl-wake-fix/layout.json"
// 记录前留备份，读到空窗口列表（锁屏/切换用户等）时回退，避免覆盖有效布局
func saveLayout() {
    let backup = FileManager.default.contents(atPath: layoutPath)
    winlayout("save")
    let now = FileManager.default.contents(atPath: layoutPath)
    if let b = backup, let n = now, String(data: n, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" {
        try? b.write(to: URL(fileURLWithPath: layoutPath)); say("empty layout discarded")
    }
}

// DisplayLink 里被用户（或"停止所有共享"）禁用的屏数。这类缺屏重启救不回来，反复重启只会添乱
// 直接读 plist 文件而非 UserDefaults：DisplayLink 是沙盒应用，偏好在它的容器里
let dlPrefs = NSHomeDirectory() + "/Library/Containers/com.displaylink.DisplayLinkUserAgent/Data/Library/Preferences/com.displaylink.DisplayLinkUserAgent.plist"
func disabledByUser() -> Int {
    guard let d = NSDictionary(contentsOfFile: dlPrefs),
          let e = d["EnabledDisplays"] as? [String: Any] else { return 0 }
    return e.values.filter { ($0 as? Bool) == false || ($0 as? Int) == 0 }.count
}

// DisplayLinkUserAgent 的 PID 列表（一次 pgrep）
func agentPIDs() -> [pid_t] {
    let p = Process(); p.launchPath = "/usr/bin/pgrep"; p.arguments = ["-u", String(getuid()), "-x", "DisplayLinkUserAgent"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

// 布局摘要："bundle@屏幕" 列表，屏幕按窗口顶边中点所在的显示器判定
func layoutSummary(_ data: Data?) -> String {
    guard let d = data, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return "unreadable" }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    let items: [String] = arr.map { w in
        let b = (w["bundle"] as? String ?? "?").split(separator: ".").last.map(String.init) ?? "?"
        let x = w["x"] as? Double ?? 0, y = w["y"] as? Double ?? 0, wd = w["w"] as? Double ?? 0
        let pt = CGPoint(x: x + wd / 2, y: y + 10)
        // 熄屏时 active 列表为空，所以用 online 列表（屏幕熄了仍在）判定所在屏
        let scr = ids.prefix(Int(n)).first { CGDisplayBounds($0).contains(pt) }
        let tag = scr.map { CGDisplayIsBuiltin($0) != 0 ? "builtin" : "ext\(Int(CGDisplayBounds($0).minX))" } ?? "offscreen"
        return "\(b)@\(tag)"
    }
    return "\(arr.count) windows: " + items.joined(separator: " ")
}

// Process.waitUntilExit 会转主 runloop，重启期间暂缓处理新的显示器事件。
var restarting = false
var launcher: Process? = nil

// 按 PID 等旧进程退出，而非按进程名：DisplayLink 自带的重启助手会在旧进程退出后
// 0.2s 内把它重新拉起，按名字轮询看不到这个空档，会一直等到上限
// （2026-11-03 09:40 实测因此空等 9.5s，两块屏 1.5s 就绪了窗口却晚 8s 才归位）。
// 若旧进程退出后已有新实例在跑（被助手拉起），就不再 open。
func restartAgent() {
    guard !restarting else { return }
    restarting = true
    defer { restarting = false }
    let t0 = Date()
    let old = agentPIDs()
    for pid in old { kill(pid, SIGTERM) }
    // 每 50ms 用 kill(pid, 0) 检查，最多 5 秒（实测正常清理 0.3~1.4s）
    while old.contains(where: { kill($0, 0) == 0 }) && Date().timeIntervalSince(t0) < 5 {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard !old.contains(where: { kill($0, 0) == 0 }) else {
        say("restart: old DisplayLink agent did not exit within 5s")
        return
    }
    let gone = String(format: "%.1f", Date().timeIntervalSince(t0))
    let now = agentPIDs().filter { !old.contains($0) }
    if !now.isEmpty {
        say("restart: old agent exited in \(gone)s, already relaunched by DisplayLink (pid \(now[0]))")
        return
    }
    let o = Process(); o.launchPath = "/usr/bin/open"; o.arguments = ["-g", "-a", "DisplayLink Manager"]
    try? o.run()
    launcher = o
    say("restart: old agent exited in \(gone)s, relaunched via open")
}

// AppKit 的事件循环使 launchd 启动的进程也能收到熄屏和亮屏通知。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let disabledFlag = NSHomeDirectory() + "/Library/Scripts/dl-wake-fix/disabled"

struct DisplayState {
    let panels = activePanels()
    let dock = dockPresent()
    let userOff = disabledByUser()
    let paused = FileManager.default.fileExists(atPath: disabledFlag)
    var missing: Set<String> { expectedPanels.subtracting(panels) }
    var healthy: Bool { dock && missing.isEmpty }
}

var displaySleeping = CGDisplayIsAsleep(CGMainDisplayID()) != 0
var dockAtSleep = false
var wakeDeadline: DispatchTime?
var lastDock: Bool?
var lastMissing: Set<String>?
var lastStatus = ""
var recoveryCheck: DispatchWorkItem?
var retryBudgetReset: DispatchWorkItem?
var restarts = 0
var needRestore = false
var frozen: Data?
var restoreJobs: [DispatchWorkItem] = []
var saveAfter = Date.distantPast
var logNextSave = false

func freezeLayout() {
    restoreJobs.forEach { $0.cancel() }
    restoreJobs.removeAll()
    guard !needRestore else { return }
    needRestore = true
    // 还原期间再次缺屏时，继续用上一次冻结的布局。
    if Date() > saveAfter || frozen == nil {
        frozen = FileManager.default.contents(atPath: layoutPath)
        say("froze layout: \(layoutSummary(frozen))")
    }
}

func restoreLayoutIfReady() {
    guard needRestore, !screenLocked() else { return }
    needRestore = false
    guard let layout = frozen else { return }
    say("healthy & unlocked, restoring window layout")
    saveAfter = Date().addingTimeInterval(35)
    logNextSave = true
    restoreJobs = [2.0, 5, 10, 20, 30].map { delay in
        let job = DispatchWorkItem {
            guard !displaySleeping, !restarting, DisplayState().healthy, !screenLocked() else {
                freezeLayout()
                return
            }
            do {
                try layout.write(to: URL(fileURLWithPath: layoutPath), options: .atomic)
                winlayout("restore")
            } catch {
                say("cannot restore frozen layout: \(error)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
        return job
    }
}

func scheduleRecovery(at deadline: DispatchTime, fast: Bool) {
    guard recoveryCheck == nil else { return }
    let job = DispatchWorkItem {
        recoveryCheck = nil
        let state = DisplayState()
        guard !displaySleeping, !restarting, state.dock, !state.paused,
              state.userOff == 0, !state.missing.isEmpty, restarts < 3 else { return }
        // 亮屏时第一块屏也还没回来，给驱动一个完整的初始化窗口。
        if fast && state.missing.count == expectedPanels.count {
            wakeDeadline = nil
            scheduleRecovery(at: .now() + reconnectDelay, fast: false)
            return
        }
        wakeDeadline = nil
        restarts += 1
        say("missing \(state.missing.sorted().joined(separator: ",")), restarting (#\(restarts))")
        restartAgent()
        updateDisplays()
    }
    recoveryCheck = job
    DispatchQueue.main.asyncAfter(deadline: deadline, execute: job)
}

func cancelRecovery() {
    recoveryCheck?.cancel()
    recoveryCheck = nil
}

func updateDisplays() {
    guard !restarting else { return }
    let state = DisplayState()
    let panelsChanged = state.missing != lastMissing
    lastMissing = state.missing
    if let lastDock, lastDock != state.dock {
        cancelRecovery()
        if !state.dock {
            wakeDeadline = nil
            dockAtSleep = false
        }
        restarts = 0
    }
    lastDock = state.dock
    let locked = screenLocked()
    let status = "asleep=\(displaySleeping) dock=\(state.dock) panels=\(state.panels.sorted().joined(separator: ",")) locked=\(locked) userOff=\(state.userOff) paused=\(state.paused)"
    if status != lastStatus {
        lastStatus = status
        say(status)
    }

    if !displaySleeping && state.healthy {
        cancelRecovery()
        wakeDeadline = nil
        if restarts > 0 && retryBudgetReset == nil {
            // 两块屏稳定后再清零，短暂的假恢复不能重置重试上限。
            let job = DispatchWorkItem {
                retryBudgetReset = nil
                if !displaySleeping && DisplayState().healthy {
                    say("both FlipGo panels recovered after \(restarts) restart(s)")
                    restarts = 0
                }
            }
            retryBudgetReset = job
            DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: job)
        }
        restoreLayoutIfReady()
        return
    }

    retryBudgetReset?.cancel()
    retryBudgetReset = nil
    freezeLayout()
    guard !displaySleeping, state.dock, !state.paused, state.userOff == 0, restarts < 3 else {
        cancelRecovery()
        return
    }
    let fastDeadline = wakeDeadline
    if let fastDeadline {
        // 枚举时第一块面板刚出现，给第二块一点时间。只对面板集合变化延时，
        // 不让重复通知无限延长等待；最长仍以亮屏时刻加重连窗口为准。
        if panelsChanged { cancelRecovery() }
        let latest = fastDeadline + (reconnectDelay - wakeDelay)
        let settled = min(latest, max(fastDeadline, .now() + wakeDelay))
        scheduleRecovery(at: settled, fast: true)
    } else {
        scheduleRecovery(at: .now() + reconnectDelay, fast: false)
    }
}

func screensDidSleep() {
    guard !displaySleeping else { return }
    displaySleeping = true
    dockAtSleep = dockPresent()
    wakeDeadline = nil
    restarts = 0
    cancelRecovery()
    updateDisplays()
}

func screensDidWake() {
    guard displaySleeping else { return }
    displaySleeping = false
    wakeDeadline = dockAtSleep && dockPresent() ? .now() + wakeDelay : nil
    cancelRecovery()
    updateDisplays()
}

let workspace = NSWorkspace.shared.notificationCenter
let sleepObservers = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification].map { name in
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in screensDidSleep() }
}
let wakeObservers = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification].map { name in
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
        if name == NSWorkspace.screensDidWakeNotification || CGDisplayIsAsleep(CGMainDisplayID()) == 0 {
            say("received \(name.rawValue)")
            screensDidWake()
        }
    }
}
let displayObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in updateDisplays() }
let distributed = DistributedNotificationCenter.default()
let sessionObservers = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.displaylink.DisplayListUpdated"].map { name in
    distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in updateDisplays() }
}

// USB 连接和断开也能触发检查，即使两块虚拟屏都没有创建。
var usbIterators: [io_iterator_t] = []
let usbNotifications = IONotificationPortCreate(kIOMainPortDefault)
if let usbNotifications {
    IONotificationPortSetDispatchQueue(usbNotifications, .main)
    for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(usbNotifications, kind, flipGoMatching(), { _, iterator in
            while case let device = IOIteratorNext(iterator), device != 0 { IOObjectRelease(device) }
            updateDisplays()
        }, nil, &iterator)
        if result == KERN_SUCCESS {
            while case let device = IOIteratorNext(iterator), device != 0 { IOObjectRelease(device) }
            usbIterators.append(iterator)
        } else {
            say("cannot subscribe to USB notification \(kind): \(result)")
        }
    }
}

// 监视暂停文件所在目录，删除暂停文件时重新检查当前状态。
let directory = (disabledFlag as NSString).deletingLastPathComponent
let watchFD = open(directory, O_EVTONLY)
var pauseWatcher: DispatchSourceFileSystemObject?
if watchFD >= 0 {
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watchFD, eventMask: .write, queue: .main)
    var wasPaused = FileManager.default.fileExists(atPath: disabledFlag)
    source.setEventHandler {
        let paused = FileManager.default.fileExists(atPath: disabledFlag)
        guard paused != wasPaused else { return }
        wasPaused = paused
        updateDisplays()
    }
    source.setCancelHandler { close(watchFD) }
    source.resume()
    pauseWatcher = source
}

// 已授权的 dl-winlayout 仍负责记录窗口，定时器只用于布局快照。
func recordLayoutIfReady() {
    guard !displaySleeping, !restarting, !needRestore, !screenLocked(),
          Date() > saveAfter, DisplayState().healthy else { return }
    saveLayout()
    if logNextSave {
        logNextSave = false
        say("layout after restore: \(layoutSummary(FileManager.default.contents(atPath: layoutPath)))")
    }
}
let layoutTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in recordLayoutIfReady() }
DispatchQueue.main.async {
    say("started (display events)")
    updateDisplays()
    recordLayoutIfReady()
}
app.run()
