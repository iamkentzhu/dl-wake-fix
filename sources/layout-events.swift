import AppKit
import ApplicationServices
import IOKit

private let panelNames: Set<String> = ["FlipGo-D1", "FlipGo-D2"]
private let fullScreenAttribute = "AXFullScreen"
private let args = Set(CommandLine.arguments.dropFirst())
private let observeOnly = args.contains("--observe-only")
private let allowFullScreen = args.contains("--restore-full-screen")
private let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Scripts/dl-wake-fix/event-layout", isDirectory: true)

private func log(_ line: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(line)")
    fflush(stdout)
}

private struct Panel: Equatable {
    let bounds: CGRect
    let id: CGDirectDisplayID
}

/// Coordinate space matches the global AX window frame (not AppKit's Y-up space).
private func panels() -> [String: Panel] {
    var query = IOServiceMatching("IOUSBHostDevice") as? [String: Any] ?? [:]
    query["idVendor"] = 0x17e9
    query["idProduct"] = 0x6000
    let device = IOServiceGetMatchingService(kIOMainPortDefault, query as CFDictionary)
    guard device != 0 else { return [:] }
    IOObjectRelease(device)
    var result: [String: Panel] = [:]
    for screen in NSScreen.screens where panelNames.contains(screen.localizedName) {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsActive(n.uint32Value) != 0 else { continue }
        guard result[screen.localizedName] == nil else { return [:] }
        result[screen.localizedName] = Panel(bounds: CGDisplayBounds(n.uint32Value), id: n.uint32Value)
    }
    return result
}

private func locked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return session["CGSSessionScreenIsLocked"] as? Bool == true
}

private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result as? T
}

private func frame(_ element: AXUIElement) -> CGRect? {
    guard let p: AXValue = attribute(element, kAXPositionAttribute),
          let s: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
          size.width >= 50, size.height >= 50 else { return nil }
    return CGRect(origin: point, size: size)
}

private func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
    abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
}

private enum Kind: String, Codable {
    case ordinary
    case standaloneFullScreen
    case splitOrUnknownFullScreen
}

private func kind(isFullScreen: Bool, rect: CGRect, display: CGRect?) -> Kind {
    guard isFullScreen else { return .ordinary }
    guard let display, nearlyEqual(rect, display, tolerance: 24) else { return .splitOrUnknownFullScreen }
    return .standaloneFullScreen
}

private struct WindowKey: Hashable, Codable {
    let bundle: String
    let title: String
}

private struct SavedWindow: Codable, Equatable {
    let key: WindowKey
    let panel: String
    let kind: Kind
    let relativeFrame: CGRect
}

private struct SavedLayout: Codable, Equatable {
    var windows: [WindowKey: SavedWindow] = [:]
    private(set) var protectedKeys: Set<WindowKey> = []
    private(set) var pendingRestore = false

    mutating func record(_ key: WindowKey, _ next: SavedWindow?, confirmedAtBaseline: Bool = false) {
        if protectedKeys.contains(key) {
            guard confirmedAtBaseline else { return }
            protectedKeys.remove(key)
        }
        windows[key] = next
    }

    mutating func disconnected() {
        if !windows.isEmpty { pendingRestore = true }
    }

    mutating func finishedRestoring(unresolved: Set<WindowKey>) {
        protectedKeys = unresolved.intersection(windows.keys)
        pendingRestore = false
    }
}

private struct Window {
    let key: WindowKey
    let element: AXUIElement
    let rect: CGRect
    let kind: Kind
}

private func matchesBaseline(_ window: Window, _ entry: SavedWindow, _ panel: Panel) -> Bool {
    guard window.kind == entry.kind else { return false }
    if entry.kind == .standaloneFullScreen {
        return nearlyEqual(window.rect, panel.bounds, tolerance: 24)
    }
    let target = entry.relativeFrame.offsetBy(dx: panel.bounds.minX, dy: panel.bounds.minY)
    return nearlyEqual(window.rect, target)
}

private func settable(_ element: AXUIElement, _ name: String) -> Bool {
    var allowed = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name as CFString, &allowed) == .success && allowed.boolValue
}

@discardableResult
private func move(_ element: AXUIElement, to rect: CGRect, resize: Bool = true) -> Bool {
    var point = rect.origin
    var size = rect.size
    guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) == .success else { return false }
    if resize {
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
    }
    return true
}

private final class LayoutObserver {
    private let saveURL = directory.appendingPathComponent("windows-v2.json")
    private let legacySaveURL = directory.appendingPathComponent("windows.json")
    private var baseline = SavedLayout()
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var watched: [pid_t: [AXUIElement]] = [:]
    private var captureJob: DispatchWorkItem?
    private var restoreJob: DispatchWorkItem?
    private var priorPanels: [String: Panel]?
    private var sleeping = false
    private var needsRestore = false
    private var missing: Set<WindowKey> = []
    private var restoreActive = false
    private var fullScreenActive = false
    private var triedFullScreen: Set<WindowKey> = []

    func start() {
        if FileManager.default.fileExists(atPath: saveURL.path) {
            do {
                baseline = try JSONDecoder().decode(SavedLayout.self, from: Data(contentsOf: saveURL))
                // If interrupted after disconnect, resume restoration before observing new positions.
                needsRestore = baseline.pendingRestore
            } catch {
                log("could not read protected window snapshot; leaving it unchanged")
                NSApp.terminate(nil)
                return
            }
        } else if let bytes = try? Data(contentsOf: legacySaveURL),
                  let entries = try? JSONDecoder().decode([SavedWindow].self, from: bytes) {
            for entry in entries where panelNames.contains(entry.panel) { baseline.record(entry.key, entry) }
            persist()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.screensDidSleepNotification || name == NSWorkspace.willSleepNotification {
                    self.sleeping = true
                } else if name == NSWorkspace.screensDidWakeNotification {
                    self.sleeping = false
                }
                self.topologyChanged()
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if name == NSWorkspace.didTerminateApplicationNotification {
                    self.detach(app.processIdentifier)
                    // Do not relaunch closed apps, but preserve the frozen baseline during disconnection.
                    if !self.needsRestore, !self.restoreActive, self.ready(panels()), let bundle = app.bundleIdentifier {
                        let before = self.baseline
                        for key in Array(self.baseline.windows.keys) where key.bundle == bundle {
                            self.baseline.record(key, nil)
                        }
                        if before != self.baseline { self.persist() }
                    }
                } else {
                    self.observe(app)
                }
                self.windowChanged()
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.topologyChanged() })
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.displaylink.DisplayListUpdated"] {
            tokens.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in self?.topologyChanged() })
        }
        NSWorkspace.shared.runningApplications.forEach(observe)
        log("ready: observe-only=\(observeOnly), standalone-full-screen=\(allowFullScreen), observed-apps=\(observers.count)")
        topologyChanged()
    }

    private func observe(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.bundleIdentifier != nil,
              app.processIdentifier != getpid(), observers[app.processIdentifier] == nil else { return }
        var instance: AXObserver?
        let create = AXObserverCreate(app.processIdentifier, { _, _, _, context in
            guard let context else { return }
            Unmanaged<LayoutObserver>.fromOpaque(context).takeUnretainedValue().windowChanged()
        }, &instance)
        guard create == .success, let observer = instance else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for event in [kAXWindowCreatedNotification, kAXMainWindowChangedNotification,
                      kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            _ = AXObserverAddNotification(observer, root, event as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[app.processIdentifier] = observer
    }

    private func detach(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        watched.removeValue(forKey: pid)
    }

    private func windows() -> [Window] {
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsActive(id.uint32Value) != 0 else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
        return NSWorkspace.shared.runningApplications.flatMap { app -> [Window] in
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(),
                  let bundle = app.bundleIdentifier else { return [] }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.2)
            guard let elements: [AXUIElement] = attribute(root, kAXWindowsAttribute) else { return [] }
            let notificationNames = [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification,
                                     kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification]
            if let observer = observers[app.processIdentifier] {
                let old = watched[app.processIdentifier] ?? []
                let context = Unmanaged.passUnretained(self).toOpaque()
                for element in old where !elements.contains(where: { CFEqual(element, $0) }) {
                    for event in notificationNames { _ = AXObserverRemoveNotification(observer, element, event as CFString) }
                }
                for element in elements where !old.contains(where: { CFEqual(element, $0) }) {
                    for event in notificationNames { _ = AXObserverAddNotification(observer, element, event as CFString, context) }
                }
                watched[app.processIdentifier] = elements
            }
            return elements.compactMap { element in
                guard (attribute(element, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
                      (attribute(element, kAXMinimizedAttribute) as Bool?) != true,
                      let rect = frame(element) else { return nil }
                let title: String = attribute(element, kAXTitleAttribute) ?? ""
                let isFullScreen: Bool = attribute(element, fullScreenAttribute) ?? false
                let display = displays.first { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
                return Window(key: WindowKey(bundle: bundle, title: title), element: element, rect: rect,
                              kind: kind(isFullScreen: isFullScreen, rect: rect, display: display))
            }
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(baseline)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            log("could not save window snapshot: \(error.localizedDescription)")
        }
    }

    private func ready(_ current: [String: Panel]) -> Bool {
        !sleeping && !locked() && panelNames.isSubset(of: current.keys) && AXIsProcessTrusted() &&
        !FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("disabled").path)
    }

    private func topologyChanged() {
        let current = panels()
        if sleeping || !panelNames.isSubset(of: current.keys) {
            captureJob?.cancel()
            restoreJob?.cancel()
            restoreJob = nil
            let before = baseline
            baseline.disconnected()
            if baseline != before {
                persist()
                log("froze \(baseline.windows.count) saved external windows")
            }
            needsRestore = true
            restoreActive = false
            missing.removeAll()
            triedFullScreen.removeAll()
        }
        if ready(current) {
            if needsRestore {
                if !restoreActive || priorPanels != current {
                    restoreJob?.cancel()
                    restoreActive = true
                    missing = Set(baseline.windows.keys)
                    triedFullScreen.removeAll()
                    scheduleRestore(step: 0)
                }
            } else {
                windowChanged()
            }
        }
        priorPanels = current
    }

    private func windowChanged() {
        guard !restoreActive, !needsRestore else { return }
        captureJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.capture() }
        captureJob = job
        // AX often emits a burst for a single drag. Read only once it quiets down.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(650), execute: job)
    }

    private func capture() {
        let current = panels()
        guard !needsRestore, !restoreActive, ready(current), priorPanels == current else { return }
        let live = Dictionary(grouping: windows(), by: \.key)
        guard !live.isEmpty, panels() == current, ready(current) else { return }
        let before = baseline
        for (key, group) in live where group.count == 1 {
            let window = group[0]
            let center = CGPoint(x: window.rect.midX, y: window.rect.midY)
            guard let (name, panel) = current.first(where: { $0.value.bounds.contains(center) }) else {
                baseline.record(key, nil)
                continue
            }
            let relative = window.rect.offsetBy(dx: -panel.bounds.minX, dy: -panel.bounds.minY)
            let confirmed = baseline.windows[key].map {
                $0.panel == name && matchesBaseline(window, $0, panel)
            } ?? false
            baseline.record(key, SavedWindow(key: key, panel: name, kind: window.kind, relativeFrame: relative),
                            confirmedAtBaseline: confirmed)
        }
        for (key, group) in live where group.count > 1 { baseline.record(key, nil) }
        guard before != baseline else { return }
        persist()
        let counts = Dictionary(grouping: baseline.windows.values, by: \.kind).mapValues(\.count)
        log("saved external windows from events: ordinary=\(counts[.ordinary, default: 0]), full-screen=\(counts[.standaloneFullScreen, default: 0]), split/unknown=\(counts[.splitOrUnknownFullScreen, default: 0]), protected=\(baseline.protectedKeys.count)")
    }

    private func scheduleRestore(step: Int) {
        // Match the current helper's maximum window for Electron to re-register.
        // Each pass only considers windows not seen or not restored yet.
        let delays: [Double] = [2, 3, 5, 10, 10]
        let job = DispatchWorkItem { [weak self] in self?.restore(step: step) }
        restoreJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[step], execute: job)
    }

    private func restore(step: Int) {
        let current = panels()
        guard restoreActive, needsRestore else { return }
        guard ready(current), current == priorPanels else {
            restoreJob = nil
            restoreActive = false
            topologyChanged()
            return
        }
        let live = Dictionary(grouping: windows(), by: \.key)
        guard ready(current), panels() == current else { restoreActive = false; topologyChanged(); return }
        for key in Array(missing) {
            guard let entry = baseline.windows[key], let panel = current[entry.panel], let options = live[key],
                  options.count == 1 else { continue }
            let window = options[0]
            if matchesBaseline(window, entry, panel) {
                missing.remove(key)
                continue
            }
            let target = entry.relativeFrame.offsetBy(dx: panel.bounds.minX, dy: panel.bounds.minY)
            switch entry.kind {
            case .ordinary:
                guard window.kind == .ordinary else { continue }
                if !observeOnly && settable(window.element, kAXPositionAttribute) && move(window.element, to: target),
                   let actual = frame(window.element), nearlyEqual(actual, target) {
                    missing.remove(key)
                    log("restored one ordinary window to \(entry.panel)")
                }
            case .standaloneFullScreen:
                if allowFullScreen && !observeOnly && !fullScreenActive && !triedFullScreen.contains(key) &&
                          window.kind != .splitOrUnknownFullScreen && settable(window.element, fullScreenAttribute) {
                    triedFullScreen.insert(key)
                    restoreFullScreen(window, panel: entry.panel)
                }
            case .splitOrUnknownFullScreen:
                // Never toggle a tiled full-screen window: it can dissolve an existing Split View pair.
                break
            }
        }
        if !missing.isEmpty && step < 4 {
            scheduleRestore(step: step + 1)
        } else {
            let unresolved = Dictionary(grouping: missing.compactMap { baseline.windows[$0] }, by: \.kind).mapValues(\.count)
            baseline.finishedRestoring(unresolved: missing)
            persist()
            log("window pass complete: unresolved ordinary=\(unresolved[.ordinary, default: 0]), full-screen=\(unresolved[.standaloneFullScreen, default: 0]), split/unknown=\(unresolved[.splitOrUnknownFullScreen, default: 0])")
            restoreJob = nil
            needsRestore = false
            restoreActive = false
            // Normal recording resumes, but each unsuccessful match remains pinned
            // to the saved baseline until it is observed there or restored later.
        }
    }

    private func restoreFullScreen(_ window: Window, panel name: String) {
        let element = window.element
        let wasFullScreen = window.kind == .standaloneFullScreen
        if wasFullScreen {
            guard AXUIElementSetAttributeValue(element, fullScreenAttribute as CFString, kCFBooleanFalse) == .success else { return }
        }
        fullScreenActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            defer { self.fullScreenActive = false }
            let current = panels()
            guard self.restoreActive, self.ready(current), self.priorPanels == current,
                  let target = current[name], let oldFrame = frame(element),
                  (attribute(element, fullScreenAttribute) as Bool?) == false else {
                if wasFullScreen, !locked() {
                    _ = AXUIElementSetAttributeValue(element, fullScreenAttribute as CFString, kCFBooleanTrue)
                }
                return
            }
            let point = CGPoint(x: target.bounds.midX - min(oldFrame.width, target.bounds.width) / 2,
                                y: target.bounds.minY + 40)
            _ = move(element, to: CGRect(origin: point, size: oldFrame.size), resize: false)
            if let actual = frame(element), target.bounds.contains(CGPoint(x: actual.midX, y: actual.midY)) {
                _ = AXUIElementSetAttributeValue(element, fullScreenAttribute as CFString, kCFBooleanTrue)
            } else if wasFullScreen {
                _ = AXUIElementSetAttributeValue(element, fullScreenAttribute as CFString, kCFBooleanTrue)
            }
        }
    }
}

if args.contains("--self-test") {
    let display = CGRect(x: -1280, y: 300, width: 1280, height: 800)
    precondition(kind(isFullScreen: false, rect: display, display: display) == .ordinary)
    precondition(kind(isFullScreen: true, rect: display, display: display) == .standaloneFullScreen)
    precondition(kind(isFullScreen: true, rect: CGRect(x: -1280, y: 300, width: 640, height: 800), display: display) == .splitOrUnknownFullScreen)
    precondition(kind(isFullScreen: true, rect: display, display: nil) == .splitOrUnknownFullScreen)
    print("layout classification checks passed")
    let a = WindowKey(bundle: "test.a", title: "Unresolved")
    let b = WindowKey(bundle: "test.b", title: "Restored")
    let first = SavedWindow(key: a, panel: "FlipGo-D1", kind: .ordinary, relativeFrame: display)
    let wrong = SavedWindow(key: a, panel: "FlipGo-D2", kind: .ordinary, relativeFrame: display)
    let second = SavedWindow(key: b, panel: "FlipGo-D2", kind: .ordinary, relativeFrame: display)
    var baseline = SavedLayout()
    baseline.record(a, first)
    baseline.record(b, second)
    baseline.disconnected()
    func reopened(_ snapshot: SavedLayout) throws -> SavedLayout {
        try JSONDecoder().decode(SavedLayout.self, from: JSONEncoder().encode(snapshot))
    }
    let duringRecovery = try reopened(baseline)
    precondition(duringRecovery.pendingRestore && duringRecovery.windows[a] == first)
    baseline.finishedRestoring(unresolved: [a])
    baseline = try reopened(baseline)
    precondition(!baseline.pendingRestore)
    baseline.record(a, nil)
    baseline.record(a, wrong)
    baseline.record(b, nil)
    precondition(baseline.windows[a] == first && baseline.windows[b] == nil)
    baseline.record(a, first, confirmedAtBaseline: true)
    baseline.record(a, wrong)
    precondition(baseline.windows[a] == wrong && baseline.protectedKeys.isEmpty)
    print("unresolved layout survives an unrelated update and restart")
    exit(0)
}

if args.contains("--check-accessibility") {
    let trusted = AXIsProcessTrusted()
    print(trusted ? "TRUSTED" : "NOT_TRUSTED")
    fflush(stdout)
    exit(trusted ? 0 : 2)
}

do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
} catch {
    log("could not create layout directory: \(error.localizedDescription)")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let observer = LayoutObserver()
DispatchQueue.main.async {
    if AXIsProcessTrusted() {
        observer.start()
    } else {
        log("NOT_TRUSTED: grant Accessibility to the Layout Events app, then relaunch it")
        app.terminate(nil)
    }
}
app.run()
