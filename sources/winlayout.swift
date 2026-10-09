// dl-winlayout save|restore|check — 记录/还原各 App 窗口位置（辅助功能 API）
// 单独成二进制：辅助功能授权绑定 cdhash，守护逻辑改动不应让授权失效
import AppKit
import ApplicationServices

let store = NSHomeDirectory() + "/Library/Scripts/dl-wake-fix/layout.json"

struct Win: Codable { var bundle: String; var title: String; var x, y, w, h: Double }

func attr<T>(_ e: AXUIElement, _ k: String) -> T? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v as? T : nil
}
func frame(_ w: AXUIElement) -> CGRect? {
    guard let p: AXValue = attr(w, kAXPositionAttribute), let s: AXValue = attr(w, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt); AXValueGetValue(s, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

// 每个普通 App 的可移动窗口（排除最小化、全屏、非标准窗口）
func currentWindows() -> [(bundle: String, title: String, el: AXUIElement, f: CGRect)] {
    var out: [(String, String, AXUIElement, CGRect)] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let b = app.bundleIdentifier else { continue }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let wins: [AXUIElement] = attr(ax, kAXWindowsAttribute) else { continue }
        for w in wins {
            if (attr(w, kAXSubroleAttribute) as String?) != kAXStandardWindowSubrole { continue }
            if (attr(w, kAXMinimizedAttribute) as Bool?) == true { continue }
            if (attr(w, "AXFullScreen") as Bool?) == true { continue }
            guard let f = frame(w), f.width > 50, f.height > 50 else { continue }
            out.append((b, (attr(w, kAXTitleAttribute) as String?) ?? "", w, f))
        }
    }
    return out
}

func save() {
    let ws = currentWindows().map { Win(bundle: $0.bundle, title: $0.title, x: $0.f.minX, y: $0.f.minY, w: $0.f.width, h: $0.f.height) }
    let data = try! JSONEncoder().encode(ws)
    try! data.write(to: URL(fileURLWithPath: store + ".tmp"))
    _ = try? FileManager.default.removeItem(atPath: store)
    try! FileManager.default.moveItem(atPath: store + ".tmp", toPath: store)
    print("saved \(ws.count) windows")
}

func onAnyScreen(_ r: CGRect) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let c = CGPoint(x: r.midX, y: r.minY + 10)
    return ids.prefix(Int(n)).contains { CGDisplayBounds($0).contains(c) }
}

func restore() {
    guard let data = FileManager.default.contents(atPath: store),
          var saved = try? JSONDecoder().decode([Win].self, from: data) else { print("no layout"); return }
    let cur = currentWindows()
    var pending: [(AXUIElement, CGRect, Win)] = []
    var unmatched: [(bundle: String, title: String, el: AXUIElement, f: CGRect)] = []
    // 先按 bundle+标题精确匹配
    for c in cur {
        if let i = saved.firstIndex(where: { $0.bundle == c.bundle && $0.title == c.title }) {
            pending.append((c.el, c.f, saved.remove(at: i)))
        } else { unmatched.append(c) }
    }
    // 标题变了：同一 App 两边都只剩一个窗口时配对
    for c in unmatched {
        let s = saved.indices.filter { saved[$0].bundle == c.bundle }
        let u = unmatched.filter { $0.bundle == c.bundle }
        if s.count == 1 && u.count == 1 { pending.append((c.el, c.f, saved.remove(at: s[0]))) }
    }
    var moved = 0
    for (el, f, w) in pending {
        let target = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
        guard onAnyScreen(target) else { continue }
        if abs(f.minX - target.minX) < 4 && abs(f.minY - target.minY) < 4 && abs(f.width - target.width) < 4 && abs(f.height - target.height) < 4 { continue }
        var p = target.origin, s = target.size
        let pv = AXValueCreate(.cgPoint, &p)!, sv = AXValueCreate(.cgSize, &s)!
        // 先挪位置再改尺寸再挪一次：跨屏时尺寸受目标屏约束
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
        moved += 1
        print("moved \(w.bundle) \"\(w.title.prefix(40))\" -> \(Int(w.x)),\(Int(w.y))")
    }
    print("restored \(moved)/\(pending.count) matched, \(cur.count) current")
}

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
    print("NOT_TRUSTED"); exit(2)
}
switch CommandLine.arguments.dropFirst().first {
case "save": save()
case "restore": restore()
default: print("trusted")
}
