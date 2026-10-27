import ScreenCaptureKit
import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dock: DockController!
    private var bar: TopBar!
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Chaval is the desktop: never let App Nap throttle its timers or priority (that's what made keys and glides lag).
        // Idle system sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Chaval is the dock and window manager")
        // Newest instance wins (relaunch, or the LaunchAgent taking over); the old one must not restore the Dock.
        let me = NSRunningApplication.current
        if let bid = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: bid).filter { $0 != me }.forEach { $0.forceTerminate() }
        }
        let store = Store.shared
        if !store.imported { SystemDock.importLayout(into: store) }
        SystemDock.hide()
        dock = DockController()
        bar = TopBar()
        StillWallpaper.shared.sync()
        registerHotKeys()
        Themes.refreshFiles()
        KeepAwake.apply() // the Awake toggle, if it was on before Chaval last quit
        Switcher.shared.sync()
        Tiler.shared.sync()
        Updater.start()
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            SettingsWindow.show()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logout/restart/shutdown carry a quit reason; keep the system Dock hidden for next login then.
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        if reason == nil { SystemDock.restore() }
        Switcher.shared.restoreSystem() // macOS keeps ⌘Tab off otherwise, until the next login
        KeepAwake.release() // sleep back to normal (lid-closed included)
        return .terminateNow
    }

    /// Every shortcut is a HotKeys action or command (⌃⌥D, not ⌥⌘D, hides the dock: the system Dock owns that one).
    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &key)
            HotKeys.fire(key.id)
            return noErr
        }, 1, &spec, nil, nil)
        HotKeys.register()
        var cmdTab = Store.shared.settings.cmdTab
        NotificationCenter.default.addObserver(forName: .chavalChanged, object: nil, queue: .main) { _ in
            HotKeys.register()
            if Store.shared.settings.cmdTab != cmdTab { cmdTab = Store.shared.settings.cmdTab; Switcher.shared.sync() }
        }
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--dump-extras") {
    MenuExtras.dump(to: CommandLine.arguments.dropFirst(i + 1).first ?? "/dev/stdout")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-bar") { // diagnostic: draws the top bar into a PNG
    let path = CommandLine.arguments.dropFirst(i + 1).first ?? "bar.png"
    let bar = TopBar()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { bar.snapshot(to: path); Dashboard.shared.snapshot(to: path + ".dash") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { exit(0) }
    NSApplication.shared.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--render-dash") { // diagnostic: draws a dashboard page off screen into a PNG
    _ = NSApplication.shared
    Dashboard.shared.render(page: CommandLine.arguments[i + 1], tab: CommandLine.arguments[i + 2], to: CommandLine.arguments[i + 3])
    exit(0)
}
if CommandLine.arguments.contains("--dump-windows") { // diagnostic: the windows the dock's window mode would list
    for app in NSWorkspace.shared.runningApplications where app.isRegular {
        for w in AX.windows(app) { print(app.localizedName ?? "?", "|", AX.title(w).debugDescription, "|", AX.frame(w) ?? .zero, AX.isMinimized(w) ? "min" : "") }
    }
    for w in CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [] where (w[kCGWindowOwnerName as String] as? String ?? "").contains("Libre") {
        print("cg", w[kCGWindowLayer as String] ?? "", (w[kCGWindowName as String] as? String).debugDescription, w[kCGWindowBounds as String] ?? "", w[kCGWindowIsOnscreen as String] ?? "")
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--watch-black") { // diagnostic: the screen's average brightness (8x8, no picture kept) every frame for N s; prints dark frames
    _ = NSApplication.shared
    final class Meter: NSObject, SCStreamOutput {
        var last = -1.0
        func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let pb = sb.imageBuffer else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            var sum = 0.0
            for y in 0..<h { let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self); for x in 0..<w { sum += Double(p[x * 4]) + Double(p[x * 4 + 1]) + Double(p[x * 4 + 2]) } }
            let luma = sum / Double(w * h * 3), t = CMTimeGetSeconds(sb.presentationTimeStamp)
            if luma < 12 || (last > 0 && luma < last * 0.5) { print(String(format: "%.3f dark frame: brightness %.0f (was %.0f)", t, luma, last)) }
            last = luma
        }
    }
    let meter = Meter()
    Task { do {
        let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let d = all.displays.first { $0.displayID == NSScreen.screens[0].displayID }!
        let c = SCStreamConfiguration(); c.width = 8; c.height = 8; c.minimumFrameInterval = CMTime(value: 1, timescale: 120); c.showsCursor = false; c.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: c, delegate: nil)
        try s.addStreamOutput(meter, type: .screen, sampleHandlerQueue: .global())
        try await s.startCapture()
        print(String(format: "watching from %.3f", CACurrentMediaTime()))
        try await Task.sleep(nanoseconds: UInt64(Double(CommandLine.arguments[i + 1])! * 1e9))
        try await s.stopCapture(); exit(0)
    } catch { print("failed:", error); exit(1) } }
    RunLoop.main.run(until: Date().addingTimeInterval(60)); exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--shoot-backdrop") { // diagnostic: the bare-desktop picture the compositor glides over, into a PNG
    _ = NSApplication.shared
    Task { do {
        let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let s = NSScreen.screens[0], d = all.displays.first { $0.displayID == s.displayID }!
        let c = SCStreamConfiguration(); c.width = Int(s.frame.width); c.height = Int(s.frame.height); c.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: all.windows.filter { $0.windowLayer >= 0 }), configuration: c)
        print(all.windows.filter { $0.windowLayer < 0 }.map { "\($0.owningApplication?.applicationName ?? "?") layer \($0.windowLayer)" })
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    } catch { print("failed:", error); exit(1) } }
    RunLoop.main.run(until: Date().addingTimeInterval(10)); exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--shoot-app") { // diagnostic: the largest window of APP (wherever it is) into a PNG, at most 1600 wide
    _ = NSApplication.shared
    Task { do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let w = content.windows.filter({ $0.owningApplication?.applicationName == CommandLine.arguments[i + 1] && $0.windowLayer == 0 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { print("no window"); exit(1) }
        let c = SCStreamConfiguration(), k = min(1, 1600 / w.frame.width)
        c.width = Int(w.frame.width * k); c.height = Int(w.frame.height * k); c.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: c)
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
        exit(0)
    } catch { print("failed:", error); exit(1) } }
    RunLoop.main.run(until: Date().addingTimeInterval(10)); exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--shoot") { // diagnostic: screenshot of the bottom strip (the dock) of the main display into a PNG
    Task {
        let content = try await SCShareableContent.current
        let d = content.displays.first!
        let c = SCStreamConfiguration(); c.width = d.width * 2; c.height = d.height * 2
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: c)
        let rep = NSBitmapImageRep(cgImage: img.cropping(to: CGRect(x: 0, y: CommandLine.arguments.contains("top") ? 0 : img.height - 150, width: img.width, height: CommandLine.arguments.contains("top") ? 80 : 150))!) // the dock strip, or with "top" the bar, only
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(10)); exit(1)
}
if CommandLine.arguments.contains("--dump-desktops") { // diagnostic: apps per desktop
    for (i, apps) in Desktops.apps().enumerated() { print(i + 1, apps.map { $0.localizedName ?? "?" }) }
    print("current", Desktops.current.index + 1)
    print("fullscreen", NSScreen.screens.map { Space.isFullscreen($0) }, "space", NSScreen.screens.map { Desktops.inFullscreenSpace($0) })
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-popout") { // diagnostic: draws a bar popout off screen into a PNG
    _ = NSApplication.shared
    BarPopout.render(CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2])
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-widget") { // diagnostic: draws a dock widget (as the dock would, 48 px tall) into a PNG
    _ = NSApplication.shared
    let kind = WidgetKind(rawValue: CommandLine.arguments[i + 1]) ?? .desktops
    if kind == .desktops { Widgets.desks = Desktops.apps() }
    let span = kind == .desktops ? Widgets.deskSpan : 1
    if var img = Widgets.render(Item(kind: .widget, widget: kind), key: "render", px: 96, span: span).0 {
        if kind == .desktops, case let (over?, h) = Widgets.desksActive(Item(kind: .widget, widget: kind), px: 96, span: span) {
            // The dock's sliding pill, composited where it comes to rest.
            let W = CGFloat(img.width), H = CGFloat(img.height)
            img = Icons.draw(img.width, img.height) {
                let ctx = NSGraphicsContext.current!.cgContext
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
                ctx.addPath(CGPath(roundedRect: CGRect(x: h.minX * W + H * 0.04, y: H * 0.06, width: h.width * W - H * 0.08, height: H * 0.88), cornerWidth: H * 0.2, cornerHeight: H * 0.2, transform: nil))
                ctx.clip()
                ctx.draw(over, in: CGRect(x: 0, y: 0, width: W, height: H))
            } ?? img
        }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--capbench") { // diagnostic: how long screen captures take
    Task {
        var out: [String] = []
        let t0 = CACurrentMediaTime()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        out.append("shareable content \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
        let d = content.displays.first!, me = content.applications.filter { $0.processID == getpid() || $0.bundleIdentifier == "dev.chaval.dock" }
        let c = SCStreamConfiguration(); c.width = d.width * 2; c.height = d.height * 2; c.showsCursor = false
        for _ in 0..<5 {
            let t = CACurrentMediaTime()
            _ = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), configuration: c)
            out.append("display capture \(Int((CACurrentMediaTime() - t) * 1000)) ms")
        }
        try out.joined(separator: "\n").write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
        exit(0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(15)); exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--compositortest") { // diagnostic: does the tiling overlay line up with the screen?
    _ = NSApplication.shared
    Task { await Compositor.selfCheck(to: CommandLine.arguments[i + 1]); exit(0) }
    RunLoop.main.run(until: Date().addingTimeInterval(20)); exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-launcher") { // diagnostic: draws the launcher off screen, searching QUERY, into a PNG
    _ = NSApplication.shared
    Launcher.shared.render(CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2])
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-switcher") { // diagnostic: draws the ⌘Tab panel off screen into a PNG
    _ = NSApplication.shared
    Switcher.render(to: CommandLine.arguments[i + 1])
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--record") { // diagnostic: records the main display at 60 fps (half size) into DIR as JPEGs, for checking animations
    final class Recorder: NSObject, SCStreamOutput {
        let dir: String; var n = 0; var times: [String] = []
        let q = DispatchQueue(label: "rec")
        init(_ d: String) { dir = d }
        func stream(_ s: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let px = b.imageBuffer else { return }
            let ci = CIImage(cvPixelBuffer: px)
            guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
            n += 1
            times.append(String(format: "%05d %.4f", n, CACurrentMediaTime()))
            let url = URL(fileURLWithPath: String(format: "%@/f%05d.jpg", dir, n)) as CFURL
            if let d = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary); CGImageDestinationFinalize(d)
            }
        }
    }
    let secs = Double(CommandLine.arguments[i + 1]) ?? 10, dir = CommandLine.arguments[i + 2]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let rec = Recorder(dir)
    Task {
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let d = c.displays.first!
        let cfg = SCStreamConfiguration()
        cfg.width = d.width / 2; cfg.height = d.height / 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60); cfg.showsCursor = false; cfg.queueDepth = 8
        let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
        try s.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.q)
        try await s.startCapture()
        try? "recording".write(toFile: dir + "/started", atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        try await s.stopCapture()
        rec.q.sync { try? rec.times.joined(separator: "\n").write(toFile: dir + "/times.txt", atomically: true, encoding: .utf8) }
        exit(0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(secs + 20)); exit(1)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-menu") { // diagnostic: draws one of the front app's menus, Chaval-style, into a PNG
    _ = NSApplication.shared
    ChavalMenu.render(CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2])
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--shoot-dash") { // diagnostic: opens the real dashboard for a second and captures just it
    _ = NSApplication.shared
    Dashboard.shared.open()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        Task {
            let content = try await SCShareableContent.current
            let d = content.displays.first!, scr = NSScreen.screens[0], k = scr.backingScaleFactor
            let c = SCStreamConfiguration(); c.width = Int(scr.frame.width * k); c.height = Int(scr.frame.height * k)
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: c)
            let f = Dashboard.shared.panelFrame!.insetBy(dx: -12, dy: -12)
            let crop = CGRect(x: f.minX * k, y: (scr.frame.height - f.maxY) * k, width: f.width * k, height: f.height * k)
            try NSBitmapImageRep(cgImage: img.cropping(to: crop)!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
    }
    NSApplication.shared.run()
}
if CommandLine.arguments.contains("--movetest") { // diagnostic: an invisible window of our own goes to desktop 2 and back
    _ = NSApplication.shared; setvbuf(stdout, nil, _IONBF, 0)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
    w.backgroundColor = .clear; w.isOpaque = false; w.alphaValue = 0.01; w.orderFrontRegardless()
    let id = CGWindowID(w.windowNumber)
    typealias SpacesFor = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    let cid = unsafeBitCast(dlsym(sl, "SLSMainConnectionID")!, to: (@convention(c) () -> Int32).self)()
    let spacesFor = unsafeBitCast(dlsym(sl, "SLSCopySpacesForWindows")!, to: SpacesFor.self)
    func desk() -> Int { let s = (spacesFor(cid, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber])?.first?.uint64Value ?? 0
        return (Desktops.displays.first?.desktops.firstIndex(of: s) ?? -1) + 1 }
    func shown() -> Bool { ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []).contains { $0[kCGWindowNumber as String] as? CGWindowID == id } }
    let current = Desktops.displays.first.map { d in (d.desktops.firstIndex(of: d.current) ?? 0) + 1 } ?? 1
    let other = current == 1 ? 2 : 1
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    print("on screen before:", shown(), "on desktop", desk(), "current desktop", current)
    print("move to \(other):", Desktops.move(id, toDesktop: other))
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    print("on screen after:", shown(), "now on desktop", desk())
    print("move back:", Desktops.move(id, toDesktop: current))
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    print("on screen again:", shown(), "now on desktop", desk())
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    DockView.selfTest(); Icons.selfTest(); MenuBarCapture.selfTest(); Tiler.selfTest(); HotKeys.selfTest(); Desktops.selfTest(); Switcher.selfTest(); Launcher.selfTest(); NewTerminal.selfTest()
    assert(FastFocus.available, "the instant-focus calls are still in SkyLight")
    Widgets.sample(); Widgets.sample()
    for k in WidgetKind.allCases {
        for span in 1...4 {
            let img = Widgets.render(Item(kind: .widget, widget: k), key: "test", px: 64, span: span).0
            assert(img?.width == 64 * span && img?.height == 64, "\(k) renders at span \(span)")
        }
    }
    // Volume can be nil: a Multi-Output Device (cava's) has none.
    assert(!Audio.devices(input: false).isEmpty && Audio.defaultDevice(input: false) != nil, "sound outputs can be read")
    assert(!InputSources.enabled.isEmpty, "keyboard layouts can be listed")
    let mem = Widgets.memory(); assert(mem > 0 && mem < 1, "memory fraction"); print("widgets selftest ok (memory \(Int(mem * 100))%)")
    func kinds(_ ts: [Tile]) -> String { DockController.separated(ts).map { $0.kind == .separator ? "|" : "x" }.joined() }
    func t(_ k: Tile.Kind, _ section: Int = 0) -> Tile { let t = Tile(k, key: UUID().uuidString); t.section = section; return t }
    assert(kinds([t(.app), t(.app), t(.folder), t(.trash), t(.widget)]) == "xx|xxx", "clock after Trash: no divider")
    assert(kinds([t(.widget), t(.app), t(.trash), t(.app)]) == "xx|x|x", "dividers wherever groups change")
    assert(kinds([t(.app), t(.app, 1), t(.trash)]) == "x|x|x", "recents get their own group")
    print("layout selftest ok")
    // One broken entry must cost only itself: the rest of the layout still loads.
    var probe = Settings(); probe.iconSize = 33; probe.taskbar = true
    var obj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(probe)) as! [String: Any]
    obj["keyCommands"] = [["keys": "alt - c"]] // no command: unreadable
    obj["iconTintHex"] = 5                      // wrong type
    let salvaged = Store.salvage(try! JSONSerialization.data(withJSONObject: obj), Settings())
    assert(salvaged.iconSize == 33 && salvaged.taskbar, "a bad setting doesn't reset the others")
    let noID = try! JSONDecoder().decode(KeyCommand.self, from: Data(#"{"keys":"alt - c","command":"x"}"#.utf8))
    assert(noID.keys == "alt - c", "a shortcut without an id still loads")
    // A setting added inside a group (the bar's theme) fills in, and the rest of that group keeps its stored values.
    var oldBar = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(BarConfig())) as! [String: Any]
    var oldTheme = oldBar["theme"] as! [String: Any]; oldTheme["accentHex"] = "112233FF"; oldTheme["borderWidth"] = nil; oldBar["theme"] = oldTheme
    let bar = Store.salvage(try! JSONSerialization.data(withJSONObject: oldBar), BarConfig())
    assert(bar.theme.accentHex == "112233FF" && bar.theme.borderWidth == BarTheme().borderWidth, "a new theme setting doesn't reset the theme")
    print("settings selftest ok")
    assert(Updater.newer("0.2-beta", than: "0.1-beta") && Updater.newer("0.10", than: "0.9") && Updater.newer("0.1", than: "0.1-beta"))
    assert(!Updater.newer("0.1-beta", than: "0.1-beta") && !Updater.newer("0.1-beta", than: "0.1") && !Updater.newer("0.9", than: "0.10"))
    print("updater selftest ok")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--same-signer") { // diagnostic: would the updater accept this app?
    print(Updater.sameSigner(URL(fileURLWithPath: CommandLine.arguments.dropFirst(i + 1).first ?? "")))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
