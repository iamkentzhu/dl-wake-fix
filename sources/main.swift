// 亮屏后检查 DisplayLink 外接屏数量，不足则重启 DisplayLinkUserAgent 触发全量重建
// 背景：DisplayLink 熄屏时重建虚拟屏撞上睡眠窗口失败(kr=0x5)且不重试，导致亮屏后 FlipGo 一块屏挂空
import AppKit
import IOKit

let expected = 2
let log = FileHandle(forWritingAtPath: NSHomeDirectory() + "/Library/Logs/dl-wake-fix.log")
    ?? { FileManager.default.createFile(atPath: NSHomeDirectory() + "/Library/Logs/dl-wake-fix.log", contents: nil)
         return FileHandle(forWritingAtPath: NSHomeDirectory() + "/Library/Logs/dl-wake-fix.log")! }()
let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
func say(_ s: String) {
    log.seekToEndOfFile()
    log.write("\(fmt.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

func externalCount() -> Int {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }.count
}

func dockPresent() -> Bool {
    // USB 匹配规则不允许只给 idVendor，所以遍历后自己比对
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(it) }
    var found = false
    while case let s = IOIteratorNext(it), s != 0 {
        if let v = IORegistryEntryCreateCFProperty(s, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int, v == 0x17e9 { found = true }
        IOObjectRelease(s)
    }
    return found
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

func agentAlive() -> Bool {
    let p = Process(); p.launchPath = "/usr/bin/pgrep"; p.arguments = ["-x", "DisplayLinkUserAgent"]
    p.standardOutput = Pipe()
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

func restartAgent() {
    let t0 = Date()
    let k = Process(); k.launchPath = "/usr/bin/killall"; k.arguments = ["DisplayLinkUserAgent"]
    try? k.run(); k.waitUntilExit()
    // 每 100ms 查一次，进程一退就走，最多等 3 秒（实测通常 100~300ms）
    var waited = 0.0
    while agentAlive() && waited < 3 { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
    let o = Process(); o.launchPath = "/usr/bin/open"; o.arguments = ["-g", "-a", "DisplayLink Manager"]
    try? o.run(); o.waitUntilExit()
    say("restart took \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
}

// 轮询 1s。唤醒路径：醒来后给第一块屏 3s，仍缺屏立刻重启。慢速路径（拔插等）：缺屏持续 10s 才动手。冷却 30s，最多连续 3 次
// 不用 screensDidWakeNotification：命令行进程收不到该通知（2026-10-09 实测）
// 暂停：touch ~/Library/Scripts/dl-wake-fix/disabled
let disabledFlag = NSHomeDirectory() + "/Library/Scripts/dl-wake-fix/disabled"
var bad = 0
var cooldownUntil = Date.distantPast
var restarts = 0
var lastState = ""
var wasAsleep = false
var needRestore = false  // 外接屏出过异常（熄屏/缺屏/坞离线）后置位，解锁且两屏齐全时还原
var saveAfter = Date()   // 还原后一段时间不记录，避免把错乱布局存下来
var lastSave = Date.distantPast
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    let off = FileManager.default.fileExists(atPath: disabledFlag)
    let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0, dock = dockPresent(), c = externalCount()
    let locked = screenLocked()
    let state = "asleep=\(asleep) dock=\(dock) externals=\(c) locked=\(locked)" + (off ? " (disabled)" : "")
    if state != lastState { say(state); lastState = state }
    // 熄屏是唯一的触发源：醒来后 DisplayLink 不会自己补建 D1。给第一块屏 3s 出现，
    // 若仍缺屏就立刻重启，不必等连续 N 次轮询
    if wasAsleep && !asleep {
        wasAsleep = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !off, dockPresent(), externalCount() < expected,
               Date() > cooldownUntil, restarts < 3, !FileManager.default.fileExists(atPath: disabledFlag) {
                restarts += 1; bad = 0
                say("woke with externals=\(externalCount()) < \(expected), restarting (#\(restarts))")
                restartAgent()
                cooldownUntil = Date().addingTimeInterval(30)
            }
        }
    }
    if asleep { wasAsleep = true }
    let healthy = !asleep && dock && c >= expected
    if !healthy { needRestore = true }
    if healthy && !locked && needRestore {
        // 熄屏时 DisplayLink 会销毁两块虚拟屏，macOS 把窗口挪走；屏幕回来且解锁后按记录还原
        needRestore = false
        say("healthy & unlocked, restoring window layout")
        saveAfter = Date().addingTimeInterval(20)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { winlayout("restore") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { winlayout("restore") }
    }
    if healthy && !locked && !needRestore && Date() > saveAfter && Date().timeIntervalSince(lastSave) >= 15 {
        lastSave = Date(); saveLayout()
    }
    if off || asleep || !dock { bad = 0; restarts = 0; return }
    if c >= expected {
        if restarts > 0 { say("recovered externals=\(c) after \(restarts) restart(s)"); restarts = 0 }
        bad = 0; restarts = 0; return
    }
    bad += 1  // 1s 一次
    guard bad >= 10, Date() > cooldownUntil, restarts < 3 else { return }
    restarts += 1
    say("externals=\(c) < \(expected), restarting DisplayLinkUserAgent (#\(restarts))")
    restartAgent()
    bad = 0
    cooldownUntil = Date().addingTimeInterval(30)
}
say("started")
RunLoop.main.run()
