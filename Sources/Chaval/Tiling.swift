import AppKit
import Carbon.HIToolbox

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Built-in tiling: master + stack per display, animated.
/// The real windows glide: a fast spring per window, stepped on every display frame and written through Accessibility
/// on a queue per app where the newest frame wins, so a slow app drops frames instead of falling behind. A step that
/// doesn't change a window's size only moves it (cheap; resizing makes the app lay itself out again). Once there, one
/// exact write with a read-back and one retry. Approach after dinky (MIT, github.com/mikker/Dinky).
final class Tiler: NSObject {
    static let shared = Tiler()

    private struct Win { let el: AXUIElement; let pid: pid_t }
    /// One window gliding: x, y, width, height on the same spring, so neighbours' shared edges move together.
    private struct Anim { var value: [Double]; var velocity: [Double] = [0, 0, 0, 0]; var target: CGRect; var age = 0.0; let win: Win; var size = CGSize.zero }

    private var on = false
    private var wins: [CGWindowID: Win] = [:]      // windows Chaval manages on the current Space
    private var order: [CGWindowID] = []           // tiling order; survives Space switches
    private var floating: Set<CGWindowID> = []
    private var zoomed: CGWindowID?
    private var leaving: [CGWindowID: (from: CGDirectDisplayID, to: CGDirectDisplayID)] = [:] // sent across this pass: slides over
    private var homes: [CGWindowID: CGDirectDisplayID] = [:] // windows sent to a screen (a drop there, or ⌥⇧. / ⌥⇧,)
    private var heights: [CGWindowID: CGFloat] = [:] // share of its column's height (1 = even); taller/shorter and edge drags set it
    private var targets: [CGWindowID: CGRect] = [:]
    private var anims: [CGWindowID: Anim] = [:]
    /// Where a window came to rest when last asked for a frame: apps with a minimum size or a grid (Terminal) never
    /// reach their tile exactly and mustn't be sent gliding at it on every pass.
    private var landed: [CGWindowID: (asked: CGRect, got: CGRect)] = [:]
    private var frames: [CGWindowID: CGRect] = [:]   // as of the last scan
    private var writers: [pid_t: Writer] = [:]
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var hzNow = 60.0
    private var scanning = false, rescan = false
    private var instantUntil: CFTimeInterval = 0
    private var snapBack: Set<CGWindowID> = []        // resized by its own app: put back without a show
    private var closed: Set<CGWindowID> = []          // destroyed but possibly still fading out
    private var closing: [CGWindowID: CGRect] = [:]    // just destroyed, for the next glide to fade out
    private var lastWrite: [CGWindowID: TimeInterval] = [:]
    private var userTouched: Set<CGWindowID> = []  // moved or resized by the user since the last mouse-up
    private var observers: [pid_t: AXObserver] = [:]
    private var watchingDestroy: Set<CGWindowID> = []
    private var pending: DispatchWorkItem?
    private var tokens: [NSObjectProtocol] = []
    private var mouseUp: Any?, mouseMove: Any?
    private var hoverWork: DispatchWorkItem?
    private var dragTap: CFMachPort?
    private var dragging: (id: CGWindowID, el: AXUIElement, offset: CGPoint)?
    private var dragTo: CGPoint?, dragBusy = false
    private var watch: Timer?
    private var last = Store.shared.settings

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .chavalChanged, object: nil, queue: .main) { [weak self] _ in self?.settingsChanged() }
    }

    func sync() { Store.shared.settings.tiling ? start() : stop() }

    private func settingsChanged() {
        let s = Store.shared.settings
        defer { last = s }
        if s.tiling != last.tiling { return sync() }
        if s.borders != last.borders || s.borderWidth != last.borderWidth || s.borderRadius != last.borderRadius {
            if s.borders { Borders.shared.clear(); visibleBorders() } else { Borders.shared.clear() } // new width: re-place them all
        }
        if on && (s.tileGap != last.tileGap || s.tileOuterGap != last.tileOuterGap || s.tileRatio != last.tileRatio || s.tileFloat != last.tileFloat
                  || s.tileLayout != last.tileLayout || s.tileMasters != last.tileMasters || s.tileAccordionPeek != last.tileAccordionPeek) { schedule() }
    }

    // MARK: Lifecycle

    private func start() {
        guard !on, AXIsProcessTrusted() else { return }
        on = true
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                  NSWorkspace.didActivateApplicationNotification] {
            tokens.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                // A launching app is listened to at once, so its first window gets the instant path too (not a scan later).
                if n == NSWorkspace.didLaunchApplicationNotification, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.isRegular {
                    self?.listen(app.processIdentifier)
                }
                self?.settle()
            })
        }
        // While macOS slides between desktops a snapshot catches windows half-drawn, so a new desktop is laid out instantly.
        tokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.instantUntil = CACurrentMediaTime() + 1.2; self?.schedule(0.15)
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.schedule(0.3) })
        tokens.append(NotificationCenter.default.addObserver(forName: .chavalDockStrip, object: nil, queue: .main) { [weak self] _ in self?.schedule() })
        mouseUp = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.userDropped() }
        mouseMove = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.pointerMoved() }
        startOptionDrag()
        // Some apps (WhatsApp, Slack) only hide a window on close and stay frontmost: no Accessibility event, no app
        // switch. So also check what's on screen; one window-list call, about a millisecond.
        watch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.checkGone() }
        Compositor.shared.prepare()
        Compositor.shared.keepSettled()
        retile()
    }

    private func stop() {
        guard on else { return }
        on = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        tokens = []
        if let mouseUp { NSEvent.removeMonitor(mouseUp) }
        if let mouseMove { NSEvent.removeMonitor(mouseMove) }; mouseMove = nil
        watch?.invalidate(); watch = nil
        mouseUp = nil
        if let t = dragTap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }; dragTap = nil; dragging = nil
        for (_, obs) in observers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode) }
        observers = [:]; watchingDestroy = []
        anims = [:]; link?.invalidate(); link = nil
        Borders.shared.clear()
    }

    private func schedule(_ delay: TimeInterval = 0.02) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.retile() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: Windows

    static func focusedWindow() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (AX.get(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) as AXUIElement?).flatMap(id)
    }

    static func id(_ w: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w, &id) == .success && id != 0 ? id : nil
    }

    private struct Scan { var wins: [CGWindowID: Win] = [:], frames: [CGWindowID: CGRect] = [:], exists: Set<CGWindowID> = [] }

    /// Finds the tileable windows on the current Space. Runs off the main thread: Accessibility calls are IPC to every
    /// app, and doing them on main is what made animations hitch.
    private static func scan(_ apps: [pid_t]) -> Scan {
        let list = { (o: CGWindowListOption) in
            Set((CGWindowListCopyWindowInfo(o, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        }
        var out = Scan()
        let visible = list([.optionOnScreenOnly, .excludeDesktopElements])
        out.exists = list(.optionAll)
        var wins: [CGWindowID: Win] = [:], frames: [CGWindowID: CGRect] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in // each app answers on its own; ask them all at once
            let pid = apps[i]
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            for w in AX.windows(app) {
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
                guard let id = Tiler.id(w), visible.contains(id), settable.boolValue, !AX.isMinimized(w),
                      !(AX.get(w, "AXFullScreen") as Bool? ?? false), let f = AX.frame(w) else { continue }
                lock.lock(); wins[id] = Win(el: w, pid: pid); frames[id] = f; lock.unlock()
            }
        }
        out.wins = wins; out.frames = frames
        return out
    }

    private func apply(_ r: Scan) {
        closed.formIntersection(r.exists)
        wins = r.wins.filter { !closed.contains($0.key) }; frames = r.frames
        for (id, w) in wins { observe(w.pid); watchDestroy(w.el, id, w.pid) }
        order = order.filter(r.exists.contains) + wins.keys.filter { !order.contains($0) }.sorted()
        floating.formIntersection(r.exists); watchingDestroy.formIntersection(r.exists)
        if let z = zoomed, wins[z] == nil { zoomed = nil }
        heights = heights.filter { wins[$0.key] != nil }
        homes = homes.filter { h in wins[h.key] != nil && NSScreen.screens.contains { $0.displayID == h.value } }
        for id in anims.keys where wins[id] == nil { anims[id] = nil }
        for id in landed.keys where !r.exists.contains(id) { landed[id] = nil } // ids get reused
        visibleBorders()
        Borders.shared.focus(focused())
    }

    /// Borders for every managed window, where it is now (or where it's gliding).
    private func visibleBorders() {
        Borders.shared.sync(Dictionary(uniqueKeysWithValues: wins.keys.compactMap { id in
            (anims[id].map { a in CGRect(x: a.value[0], y: a.value[1], width: a.size.width, height: a.size.height) } ?? frames[id]).map { (id, $0) }
        }))
    }

    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, el, name, _ in Tiler.shared.axEvent(name as String, el) }, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        for n in [kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification,
                  kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    /// Listens to an app that's just launching; its accessibility may not be up for a moment, so it retries briefly.
    private func listen(_ pid: pid_t, tries: Int = 8) {
        observe(pid)
        if observers[pid] == nil && tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.listen(pid, tries: tries - 1) } }
    }

    private func watchDestroy(_ w: AXUIElement, _ id: CGWindowID, _ pid: pid_t) {
        guard !watchingDestroy.contains(id), let obs = observers[pid] else { return }
        if AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, nil) == .success { watchingDestroy.insert(id) }
    }

    private func axEvent(_ name: String, _ el: AXUIElement) {
        guard on else { return }
        switch name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // A drag or the app itself: the border follows (during a glide the glide moves it).
            if let id = Tiler.id(el), wins[id] != nil, anims[id] == nil, let f = AX.frame(el) { frames[id] = f; Borders.shared.move(id, f) }
            // Our own writes echo back as these; only a change nobody asked for is the user's.
            guard let id = Tiler.id(el), wins[id] != nil, !floating.contains(id), anims[id] == nil,
                  CACurrentMediaTime() - (lastWrite[id] ?? 0) > 0.5 else { return }
            userTouched.insert(id)
            if NSEvent.pressedMouseButtons == 0 { userTouched.remove(id); snapBack.insert(id); schedule(0.4) } // the app resized itself: put it back
        case kAXWindowCreatedNotification:
            // Straight away, not after a full scan: the sooner it's laid out, the less it shows where the app put it.
            adopt(el)
            settle()
        case kAXUIElementDestroyedNotification:
            // A closing window still shows up while it fades out, so a rescan alone would keep its tile; drop it now.
            if let id = wins.first(where: { CFEqual($0.value.el, el) })?.key {
                closed.insert(id); wins[id] = nil
                if let f = frames[id] { closing[id] = f } // the glide shows it shrinking away
                // Straight away, not after a scan: the others start filling the gap ~1 frame later instead of ~4.
                let s = Store.shared.settings
                if s.tileStyle == .smooth && s.tileAnimate && !Store.shared.reduceMotion { Compositor.shared.prefetch() }
                layout()
            }
            settle()
        case kAXFocusedWindowChangedNotification:
            Borders.shared.focus(focused())
            settle()
        default: settle() // also catches apps that only hide a window on close, which sends no destroyed event
        }
    }

    /// A window that just opened: takes it into the layout at once and lays out (the glide pops it in on its tile).
    /// A window just appeared. Its questions (role, size, state) go to the app off the main thread: an app busy opening
    /// several windows answers slowly, and asking on main froze everything for ~400 ms when windows were opened rapidly.
    private func adopt(_ el: AXUIElement) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
            let id = Tiler.id(el), standard = AX.get(el, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole
            let usable = standard && settable.boolValue && !AX.isMinimized(el) && !(AX.get(el, "AXFullScreen") as Bool? ?? false)
            let f = usable ? AX.frame(el) : nil
            DispatchQueue.main.async { self?.adopted(el, pid: pid, id: id, frame: f) }
        }
    }

    private func adopted(_ el: AXUIElement, pid: pid_t, id: CGWindowID?, frame: CGRect?) {
        let skip = Set(Store.shared.settings.tileFloat.map { $0.lowercased() })
        guard on, let id, let f = frame, wins[id] == nil, let app = NSRunningApplication(processIdentifier: pid), app.isRegular, !app.isHidden,
              !skip.contains((app.localizedName ?? "").lowercased()), !skip.contains((app.bundleIdentifier ?? "").lowercased()) else { return }
        let s = Store.shared.settings
        // Born on its tile (⌘Return): it's already where it goes, so its border shows at once and nothing hides it.
        let scr = NSScreen.screens.first { Tiler.topLeftFrame($0).contains(CGPoint(x: f.midX, y: f.midY)) } ?? NSScreen.screens[0]
        // (Its own tile is the one it was given: counted without itself and the ones still coming after it.)
        if coming.contains(where: { $0.display == scr.displayID }) || nextTile(on: scr).map({ Tiler.bornOnTile(f, $0) }) == true { Borders.shared.move(id, f) }
        else if s.tileStyle == .smooth && s.tileAnimate && !Store.shared.reduceMotion { Compositor.shared.cover(f); Compositor.shared.opening(id) }
        wins[id] = Win(el: el, pid: pid); frames[id] = f
        if !order.contains(id) { order.append(id) }
        watchDestroy(el, id, pid)
        if let i = coming.firstIndex(where: { $0.display == scr.displayID }) { coming.remove(at: i) } // one of ⌘Return's has arrived
        layoutSoon()
    }

    /// Windows opened in a burst share one layout (one glide), instead of each restarting the glide and its capture.
    private var burst: DispatchWorkItem?
    private func layoutSoon() {
        burst?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.layout() }
        burst = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: w)
    }

    /// Windows asked for (⌘Return) but not here yet, so each new one gets its own tile, not the same one twice.
    private var coming: [(display: CGDirectDisplayID, at: CFTimeInterval)] = []
    func expectWindow(on scr: NSScreen) {
        coming.append((scr.displayID, CACurrentMediaTime()))
        layoutSoon() // the others make room now
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in self?.layoutSoon() } // if it never comes, close the gap
    }

    /// Retiles now and once more after window open/close animations have finished.
    private func checkGone() {
        guard !scanning, !wins.isEmpty else { return }
        let shown = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        if wins.keys.contains(where: { !shown.contains($0) && !floating.contains($0) }) { schedule() }
    }

    /// Retiles now and again once open/close animations are done: a closing window is still listed while it fades,
    /// and when focus moves to another app nothing else announces that it's gone.
    private func settle() {
        schedule()
        for t in [0.4, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.schedule() } }
    }

    // MARK: Layout

    /// Global top-left coordinates, like Accessibility uses.
    static func topLeftFrame(_ s: NSScreen) -> CGRect { topLeft(s.frame) }

    private static func topLeft(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.maxY ?? r.maxY
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private func area(_ s: NSScreen) -> CGRect {
        let g = Store.shared.settings.tileOuterGap
        var v = Tiler.topLeft(s.visibleFrame)
        // Keep clear of Chaval's dock whatever macOS currently reports (its area lags: see DockController.strip).
        if let d = DockController.strip, d.intersects(v) {
            if d.width >= d.height { if d.midY > v.midY { v.size.height = d.minY - v.minY } else { v.size.height = v.maxY - d.maxY; v.origin.y = d.maxY } }
            else { if d.midX > v.midX { v.size.width = d.minX - v.minX } else { v.size.width = v.maxX - d.maxX; v.origin.x = d.maxX } }
        }
        return v.insetBy(dx: g, dy: g)
    }

    private func screen(of id: CGWindowID) -> NSScreen {
        if let d = homes[id], let s = NSScreen.screens.first(where: { $0.displayID == d }) { return s }
        let r = targets[id] ?? frames[id] ?? .zero
        let c = CGPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { Tiler.topLeft($0.frame).contains(c) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// `masters` windows stacked in the left column (the main area), the rest stacked on the right.
    /// `weights` (one per window, default even) share each column's height out.
    static func masterStack(_ n: Int, in a: CGRect, ratio: CGFloat, gap: CGFloat, masters: Int = 1, weights: [CGFloat] = []) -> [CGRect] {
        guard n > 1 else { return n == 1 ? [a] : [] }
        let m = min(max(masters, 1), n - 1) // always one window left for the stack, so two windows sit side by side
        func column(_ r: Range<Int>, x: CGFloat, width: CGFloat) -> [CGRect] {
            let w = r.map { weights.indices.contains($0) ? weights[$0] : 1 }, total = w.reduce(0, +)
            let free = a.height - gap * CGFloat(r.count - 1)
            var y = a.minY
            return w.map { wi in
                let h = (free * wi / total).rounded()
                defer { y += h + gap }
                return CGRect(x: x, y: y.rounded(), width: width, height: h)
            }
        }
        let mw = ((a.width - gap) * ratio).rounded()
        return column(0..<m, x: a.minX, width: mw) + column(m..<n, x: a.minX + mw + gap, width: a.width - mw - gap)
    }

    /// Hyprland's dwindle: each window takes half of what's left, splitting side by side then top and bottom in turn,
    /// so the newest windows spiral into the bottom right. The first split follows the main ratio (⌥⌃H / ⌥⌃L).
    static func dwindle(_ n: Int, in a: CGRect, ratio: CGFloat, gap: CGFloat) -> [CGRect] {
        var rest = a, out: [CGRect] = []
        for i in 0..<max(n - 1, 0) {
            let k = i == 0 ? ratio : 0.5
            if i % 2 == 0 {
                let w = ((rest.width - gap) * k).rounded()
                out.append(CGRect(x: rest.minX, y: rest.minY, width: w, height: rest.height))
                rest = CGRect(x: rest.minX + w + gap, y: rest.minY, width: rest.width - w - gap, height: rest.height)
            } else {
                let h = ((rest.height - gap) * k).rounded()
                out.append(CGRect(x: rest.minX, y: rest.minY, width: rest.width, height: h))
                rest = CGRect(x: rest.minX, y: rest.minY + h + gap, width: rest.width, height: rest.height - h - gap)
            }
        }
        return n > 0 ? out + [rest] : []
    }

    /// An even grid: as many columns as the square root rounds up to; a short last row stretches to fill.
    static func grid(_ n: Int, in a: CGRect, gap: CGFloat) -> [CGRect] {
        guard n > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(n)))), rows = Int(ceil(Double(n) / Double(cols)))
        let h = (a.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<n).map { i in
            let row = i / cols, inRow = row == rows - 1 ? n - row * cols : cols, col = i - row * cols
            let w = (a.width - gap * CGFloat(inRow - 1)) / CGFloat(inRow)
            return CGRect(x: (a.minX + CGFloat(col) * (w + gap)).rounded(), y: (a.minY + CGFloat(row) * (h + gap)).rounded(),
                          width: w.rounded(), height: h.rounded())
        }
    }

    /// AeroSpace's accordion: every window the full area less a peek each side; the focused one centred on top, the
    /// ones before it showing a strip on the left, the ones after it on the right.
    static func accordion(_ n: Int, focused f: Int, in a: CGRect, peek: CGFloat) -> [CGRect] {
        guard n > 1 else { return n == 1 ? [a] : [] }
        let base = a.insetBy(dx: peek, dy: 0)
        return (0..<n).map { i in i == f ? base : base.offsetBy(dx: i < f ? -peek : peek, dy: 0) }
    }

    /// Where a window opened now on `scr` would land: new windows join the end of the order, so the layout's last tile.
    func nextTile(on scr: NSScreen) -> CGRect? {
        guard on else { return nil }
        coming.removeAll { CACurrentMediaTime() - $0.at > 2 } // never came
        let n = tiled().filter { screen(of: $0) == scr }.count + coming.filter { $0.display == scr.displayID }.count + 1
        let s = Store.shared.settings, a = area(scr)
        switch s.tileLayout {
        case .main: return Tiler.masterStack(n, in: a, ratio: s.tileRatio, gap: s.tileGap, masters: s.tileMasters).last
        case .dwindle: return Tiler.dwindle(n, in: a, ratio: s.tileRatio, gap: s.tileGap).last
        case .grid: return Tiler.grid(n, in: a, gap: s.tileGap).last
        case .accordion: return Tiler.accordion(n, focused: n - 1, in: a, peek: CGFloat(s.tileAccordionPeek)).last
        }
    }

    /// Within a character cell or so of its tile (Ghostty sizes new windows in cells, so it can't be exact).
    static func bornOnTile(_ f: CGRect, _ t: CGRect) -> Bool {
        abs(f.minX - t.minX) < 24 && abs(f.minY - t.minY) < 24 && abs(f.width - t.width) < 24 && abs(f.height - t.height) < 32
    }

    private func tiled() -> [CGWindowID] { order.filter { wins[$0] != nil && !floating.contains($0) } }

    func retile() {
        guard on else { return }
        let skip = Set(Store.shared.settings.tileFloat.map { $0.lowercased() })
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.isRegular && !$0.isHidden
                && !skip.contains(($0.localizedName ?? "").lowercased()) && !skip.contains(($0.bundleIdentifier ?? "").lowercased())
        }.map(\.processIdentifier)
        apps.forEach(observe) // new windows announce themselves from now on (even while a scan is still running)
        if scanning { rescan = true; return }
        scanning = true
        let s = Store.shared.settings
        if s.tileStyle == .smooth && s.tileAnimate && CACurrentMediaTime() >= instantUntil { Compositor.shared.prefetch() } // the picture, in parallel with the scan
        DispatchQueue.global(qos: .userInteractive).async {
            let r = Tiler.scan(apps)
            DispatchQueue.main.async {
                self.scanning = false
                guard self.on else { return }
                self.apply(r)
                self.layout()
                if self.rescan { self.rescan = false; self.retile() }
            }
        }
    }

    private func layout() {
        let s = Store.shared.settings
        var groups = Dictionary(grouping: tiled()) { screen(of: $0) }
        // A screen a window just left glides too, even with nothing left on it: the window slides off its edge.
        for l in leaving.values { if let s = NSScreen.screens.first(where: { $0.displayID == l.from }), groups[s] == nil { groups[s] = [] } }
        defer { leaving = [:] }
        coming.removeAll { CACurrentMediaTime() - $0.at > 2 } // never came
        for (scr, ids) in groups {
            let a = area(scr)
            // Tiles kept free for ⌘Return windows still on their way (new windows go last): the rest make room now,
            // and each new one is born where it stays.
            let n = ids.count + (s.tileLayout == .accordion ? 0 : coming.filter { $0.display == scr.displayID }.count)
            let frames: [CGRect]
            switch s.tileLayout {
            case .main: frames = Tiler.masterStack(n, in: a, ratio: s.tileRatio, gap: s.tileGap, masters: s.tileMasters, weights: ids.map { heights[$0] ?? 1 })
            case .dwindle: frames = Tiler.dwindle(n, in: a, ratio: s.tileRatio, gap: s.tileGap)
            case .grid: frames = Tiler.grid(n, in: a, gap: s.tileGap)
            case .accordion:
                let f = focused().flatMap { ids.firstIndex(of: $0) } ?? 0
                frames = Tiler.accordion(ids.count, focused: f, in: a, peek: CGFloat(s.tileAccordionPeek))
            }
            let rects = zip(ids, frames).map { ($0, $0 == zoomed ? a : $1) }
            if s.tileStyle == .smooth && s.tileAnimate && !Store.shared.reduceMotion && CACurrentMediaTime() >= instantUntil {
                glide(rects, on: scr)
            } else {
                for (id, r) in rects { animate(id, to: r) }
            }
        }
    }

    /// Smooth style: the whole screen's tiles in one GPU-animated pass (see Compositor); the real windows are written
    /// once, under the overlay.
    private func glide(_ rects: [(CGWindowID, CGRect)], on scr: NSScreen) {
        var all: [Compositor.Win] = [], moving: [(CGWindowID, CGRect)] = [], fresh: [(CGWindowID, CGRect)] = []
        for (id, r) in rects {
            var prev = targets[id] // nil: a window just opened: it appears on its tile, it doesn't fly there
            guard let f = frames[id] else { targets[id] = r; continue }
            // From another screen: this screen's picture doesn't have it, so it's captured on its own. Sent over (⌥⇧. or a
            // drop), it slides in from the edge facing the screen it left; otherwise it pops in on its tile.
            if !Tiler.topLeftFrame(scr).contains(CGPoint(x: f.midX, y: f.midY)) {
                Compositor.shared.opening(id)
                targets[id] = r
                if let l = leaving[id], let src = NSScreen.screens.first(where: { $0.displayID == l.from }) {
                    let dir: CGFloat = scr.frame.midX > src.frame.midX ? 1 : -1
                    all.append(.init(id: id, from: r.offsetBy(dx: -dir * scr.frame.width, dy: 0), to: r, crop: f, appear: true))
                } else {
                    all.append(.init(id: id, from: r, to: r, crop: f, appear: true))
                }
                fresh.append((id, r)); continue
            }
            let new = prev == nil
            targets[id] = r
            if new && Tiler.bornOnTile(f, r) { place(id, wins[id]!, r); continue } // already there: just the last pixel or two
            if new { fresh.append((id, r)); all.append(.init(id: id, from: r, to: r, crop: f, appear: true)); continue }
            let justPlaced = r == prev && CACurrentMediaTime() < (lastWrite[id] ?? 0) + 0.1 // place() stamps now + 0.5
            if justPlaced {
                // On its way to r already (its app may not have moved it yet, so a scan can still see the old spot): shown
                // on its tile, never steered back to where it was. Its picture is cut from wherever it really is now.
                all.append(.init(id: id, from: r, to: r, crop: f)); continue
            }
            let resting = isResting(id, at: f, for: r)
            all.append(.init(id: id, from: f, to: resting ? f : r))
            if !resting { moving.append((id, r)) }
        }
        // New windows are written with the others once the overlay covers the screen, where they pop in on their tiles.
        moving += fresh
        // Windows that left this screen: they slide off its edge towards the screen they went to.
        var left = false
        for (id, l) in leaving where l.from == scr.displayID {
            guard let f = frames[id], let dest = NSScreen.screens.first(where: { $0.displayID == l.to }) else { continue }
            let dir: CGFloat = dest.frame.midX > scr.frame.midX ? 1 : -1
            all.append(.init(id: id, from: f, to: f.offsetBy(dx: dir * scr.frame.width, dy: 0)))
            left = true
        }
        guard !moving.isEmpty || left else { return }
        // Windows their app resized itself (Ghostty snapping to its grid) glide back with the rest: the overlay starts
        // each from where it really is, and the write waits until the overlay covers the screen (putting them straight
        // back made the real windows jump, with a gap, before it was up).
        snapBack.subtract(moving.map(\.0))
        guard !moving.isEmpty || left else { closing = [:]; return }
        // Windows that just closed on this screen: shown where they were, shrinking away.
        for (id, f) in closing where Tiler.topLeftFrame(scr).intersects(f) { all.append(.init(id: id, from: f, to: f, vanish: true)) }
        closing = [:]
        let hz = Double(scr.maximumFramesPerSecond)
        let response = max(0.15, 13 / max(hz, 60)) / max(Store.shared.settings.tileSpeed, 0.1)
        Compositor.shared.glide(all, on: scr, hide: closed, active: focused(), duration: response) { [weak self] in
            // Only tiles that are still the plan: a glide that waited its turn mustn't write an older layout over a newer one.
            for (id, r) in moving { if let self, let w = self.wins[id], self.targets[id] == r { self.frames[id] = r; self.place(id, w, r) } }
        }
    }

    // MARK: Animation

    private func animate(_ id: CGWindowID, to r: CGRect) {
        let new = targets[id] == nil
        targets[id] = r
        guard let w = wins[id] else { return }
        if new { return place(id, w, r) } // a window just opened: straight onto its tile
        if anims[id] != nil { // retarget mid-flight, keeping position and speed so the motion stays continuous
            if anims[id]!.target != r { anims[id]!.target = r; anims[id]!.age = 0 }
            return
        }
        guard let start = frames[id], !isResting(id, at: start, for: r) else { return }
        let s = Store.shared.settings
        if snapBack.remove(id) != nil || CACurrentMediaTime() < instantUntil || !s.tileAnimate || Store.shared.reduceMotion {
            return place(id, w, r)
        }
        anims[id] = Anim(value: [start.minX, start.minY, start.width, start.height].map(Double.init), target: r, win: w, size: start.size)
        startLink()
    }

    private func isResting(_ id: CGWindowID, at f: CGRect, for r: CGRect) -> Bool {
        if f.isClose(to: r, within: 1) { return true }
        guard let l = landed[id], l.asked == r else { return false }
        return f.isClose(to: l.got, within: 1)
    }

    private func startLink() {
        if link == nil, let scr = NSScreen.main ?? NSScreen.screens.first {
            link = scr.displayLink(target: self, selector: #selector(tick))
            let hz = Float(scr.maximumFramesPerSecond) // every frame the display can show (144 Hz and up too)
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, hz), maximum: hz, preferred: hz)
            hzNow = Double(hz)
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        // A stalled clock (sleep, a busy main thread) resumes where it was rather than leaping ahead.
        let dt = min(lastTick.map { l.timestamp - $0 } ?? l.duration, 1.0 / 30)
        lastTick = l.timestamp
        // About 0.15 s on a 120 Hz screen, as dinky; a 60 Hz one gets a little longer, so a glide still has ~15–20 frames.
        let response = max(0.15, 13 / hzNow) / max(Store.shared.settings.tileSpeed, 0.1) // 60 Hz: ~0.22 s
        var steps: [pid_t: [Step]] = [:]
        let now = CACurrentMediaTime()
        for (id, var a) in anims {
            let done = Tiler.glide(&a, dt: dt, response: response)
            lastWrite[id] = now
            if done { anims[id] = nil; place(id, a.win, a.target); continue }
            // Whole points, so a pure move doesn't jitter the size. An app too slow to lay itself out every frame
            // keeps its size and only moves; it gets its new size when it lands.
            let size = writer(a.win.pid).slow ? a.size : CGSize(width: a.value[2].rounded(), height: a.value[3].rounded())
            let frame = CGRect(origin: CGPoint(x: a.value[0].rounded(), y: a.value[1].rounded()), size: size)
            steps[a.win.pid, default: []].append(Step(el: a.win.el, frame: frame, resize: size != a.size))
            Borders.shared.move(id, frame) // same frame as the window, same display frame
            a.size = size
            anims[id] = a
        }
        for (pid, jobs) in steps { writer(pid).step(jobs) }
        if anims.isEmpty {
            link?.isPaused = true; lastTick = nil
        }
    }

    /// A damped spring, SwiftUI style: `response` is about the time to arrive; damping 0.9 barely overshoots.
    /// True once at rest on the target (or after a timeout, for one that never settles).
    private static func glide(_ a: inout Anim, dt: Double, response: Double) -> Bool {
        let omega = 2 * Double.pi / response, k = omega * omega, c = 2 * 0.9 * omega
        let n = max(1, Int((dt / (0.5 / max(omega, c))).rounded(.up))), h = dt / Double(n) // substeps keep it stable
        a.age += dt
        let goal = [a.target.minX, a.target.minY, a.target.width, a.target.height].map(Double.init)
        for i in 0..<4 { for _ in 0..<n { a.velocity[i] += (k * (goal[i] - a.value[i]) - c * a.velocity[i]) * h; a.value[i] += a.velocity[i] * h } }
        return (0..<4).allSatisfy { abs(a.value[$0] - goal[$0]) < 0.5 && abs(a.velocity[$0]) < 10 } || a.age > max(1, 4 * response)
    }

    /// The exact frame, read back, once more if it landed elsewhere; where it ends up is remembered.
    private func place(_ id: CGWindowID, _ w: Win, _ r: CGRect) {
        lastWrite[id] = CACurrentMediaTime() + 0.5
        Borders.shared.move(id, r)
        writer(w.pid).place(w.el, r) { [weak self] got in
            // Remembered only when it's near its tile (a grid or a minimum size): a reading taken mid-change, half
            // the height, say, would otherwise be taken as "as close as it gets" and never corrected.
            self?.landed[id] = got.flatMap { abs($0.width - r.width) < 40 && abs($0.height - r.height) < 40 ? (r, $0) : nil }
            if let got { self?.frames[id] = got; Borders.shared.move(id, got) } // an app with a minimum size stops short of its tile
        }
    }

    private func writer(_ pid: pid_t) -> Writer {
        if let w = writers[pid] { return w }
        let w = Writer(pid)
        writers[pid] = w
        return w
    }

    /// One frame of a glide. Only a step that changes the size resizes; the rest just move, which is cheap.
    private struct Step { let el: AXUIElement; var frame: CGRect; var resize: Bool }

    /// One app's frame writes, on its own queue so a slow or hung app only stalls itself.
    private final class Writer {
        private let pid: pid_t, queue: DispatchQueue, lock = NSLock()
        private var steps: [Step] = [], scheduled = false, prepared = false
        private var resizeMs = 0.0                      // running average cost of one resize write
        /// Resizing costs this app more than a frame, so its glides only move it.
        var slow: Bool { lock.withLock { resizeMs > 12 } }

        private let bundle: String?

        init(_ pid: pid_t) {
            self.pid = pid
            queue = DispatchQueue(label: "chaval.tile.\(pid)", qos: .userInteractive)
            let app = NSRunningApplication(processIdentifier: pid)
            bundle = app?.bundleIdentifier
            // Known slow from the start, so even its first glide runs every frame: Electron apps (Spotify, Discord,
            // Claude…) always are, and any app seen to be slow before is remembered across launches.
            let electron = app?.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
            if electron || bundle.map(Writer.knownSlow.contains) == true { resizeMs = 50 }
        }

        private static let slowKey = "tile.slowApps"
        static var knownSlow: Set<String> { Set(UserDefaults.standard.stringArray(forKey: slowKey) ?? []) }

        /// Folds one resize's cost into the running average; an app that turns out slow is remembered.
        private func noteResize(_ ms: Double) {
            let slowNow = lock.withLock { () -> Bool in
                let was = resizeMs > 25
                resizeMs = resizeMs == 0 ? ms : resizeMs * 0.7 + ms * 0.3
                return !was && resizeMs > 25 // remembered only when clearly slow (over 1.5 frames), not after one busy moment
            }
            if slowNow, let bundle, !Writer.knownSlow.contains(bundle) {
                UserDefaults.standard.set(Array(Writer.knownSlow.union([bundle])), forKey: Writer.slowKey)
            }
        }

        /// Animation steps: the newest frame per window replaces any not written yet; no read-back.
        func step(_ jobs: [Step]) {
            lock.withLock {
                for var j in jobs { // a newer frame replaces one not written yet, but keeps its resize
                    if let i = steps.firstIndex(where: { CFEqual($0.el, j.el) }) { j.resize = j.resize || steps[i].resize; steps[i] = j } else { steps.append(j) }
                }
                guard !scheduled else { return }
                scheduled = true
                queue.async { self.drain() }
            }
        }

        private func drain() {
            let jobs = lock.withLock { defer { steps = []; scheduled = false }; return steps }
            prepare()
            for j in jobs {
                let t0 = CACurrentMediaTime(), resize = j.resize
                if resize { Writer.glide(j.el, j.frame) } else { Writer.move(j.el, j.frame.origin) }
                if resize { noteResize((CACurrentMediaTime() - t0) * 1000) }
            }
        }

        func place(_ el: AXUIElement, _ r: CGRect, _ done: @escaping (CGRect?) -> Void) {
            // Read back after letting it settle (some apps, Firefox, apply sizes late), without holding the queue
            // meanwhile: a glide starting right after must not wait on this one's check.
            queue.async {
                self.prepare()
                let t0 = CACurrentMediaTime()
                Writer.write(el, r)
                self.noteResize((CACurrentMediaTime() - t0) * 1000) // landing writes count too: an app's first glide teaches its next
                self.queue.asyncAfter(deadline: .now() + 0.1) {
                    guard let g = AX.frame(el), !g.isClose(to: r, within: 2) else { return DispatchQueue.main.async { done(AX.frame(el)) } }
                    Writer.write(el, r)
                    self.queue.asyncAfter(deadline: .now() + 0.1) { let got = AX.frame(el); DispatchQueue.main.async { done(got) } }
                }
            }
        }

        /// AXEnhancedUserInterface (set by VoiceOver and some utilities) makes apps animate frame writes themselves
        /// and fight ours, at 5–8 ms a write.
        private func prepare() {
            guard !prepared else { return }
            prepared = true
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }

        /// Size, position, size: the first lets a window near an edge move, the second fixes a size the move clamped.
        static func write(_ el: AXUIElement, _ r: CGRect) {
            var size = r.size, origin = r.origin
            let s = AXValueCreate(.cgSize, &size)!, o = AXValueCreate(.cgPoint, &origin)!
            for (attr, v) in [(kAXSizeAttribute, s), (kAXPositionAttribute, o), (kAXSizeAttribute, s)] {
                if AXUIElementSetAttributeValue(el, attr as CFString, v) == .invalidUIElement { return }
            }
        }

        /// One frame of a glide that resizes: one write each (the exact `write` sets the size twice, for landing).
        /// Position first, so a window growing towards an edge isn't clamped by where it still is.
        static func glide(_ el: AXUIElement, _ r: CGRect) {
            var size = r.size, origin = r.origin
            if AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!) == .invalidUIElement { return }
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        }

        static func move(_ el: AXUIElement, _ p: CGPoint) {
            var p = p
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
        }
    }

    // MARK: User actions

    /// After a drag: a moved window dropped on another tile swaps with it; a resized one sets the split.
    private func userDropped() {
        guard on, !userTouched.isEmpty else { return }
        let touched = userTouched
        userTouched = []
        for id in touched {
            guard let w = wins[id], let f = AX.frame(w.el), let t = targets[id] else { continue }
            if abs(f.width - t.width) > 2 {
                let scr = screen(of: id), ids = tiled().filter { screen(of: $0) == scr }, a = area(scr)
                let span = a.width - Store.shared.settings.tileGap
                if ids.count > 1 { Store.shared.settings.tileRatio = min(0.85, max(0.15, ids.first == id ? f.width / span : 1 - f.width / span)) }
            } else if abs(f.height - t.height) > 2 {
                heights[id] = min(4, max(0.25, (heights[id] ?? 1) * f.height / max(t.height, 1)))
            } else if abs(f.minX - t.minX) > 2 || abs(f.minY - t.minY) > 2 {
                let m = NSEvent.mouseLocation, h = NSScreen.screens.first?.frame.maxY ?? 0
                dropped(id, at: CGPoint(x: m.x, y: h - m.y))
            }
        }
        schedule()
    }

    // MARK: ⌥-drag

    /// ⌥ + drag anywhere in a tiled window picks it up (the app never sees the click); dropped on another tile, the two
    /// swap; dropped anywhere else, it glides home.
    private func startOptionDrag() {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseDragged.rawValue | 1 << CGEventType.leftMouseUp.rawValue)
        dragTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                    callback: { _, type, e, _ in Tiler.shared.optionDrag(type, e) ? nil : Unmanaged.passUnretained(e) }, userInfo: nil)
        guard let t = dragTap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    }

    /// Whether the event was ours (and so swallowed).
    private func optionDrag(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = dragTap { CGEvent.tapEnable(tap: t, enable: true) }; return false }
        let p = e.location
        switch type {
        case .leftMouseDown:
            let mods = e.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
            guard mods == .maskAlternate, let id = tiled().first(where: { targets[$0]?.contains(p) == true }),
                  let w = wins[id], let f = frames[id] ?? targets[id] else { return false }
            dragging = (id, w.el, CGPoint(x: p.x - f.minX, y: p.y - f.minY))
            return true
        case .leftMouseDragged:
            guard let d = dragging else { return false }
            dragTo = CGPoint(x: p.x - d.offset.x, y: p.y - d.offset.y)
            lastWrite[d.id] = CACurrentMediaTime() // our own moves, not the user's drag
            if !dragBusy { dragBusy = true; pumpDrag() }
            return true
        case .leftMouseUp:
            guard let d = dragging else { return false }
            dragging = nil; dragTo = nil
            dropped(d.id, at: p)
            lastWrite[d.id] = CACurrentMediaTime()
            retile()
            return true
        default: return false
        }
    }

    /// One AX move at a time, off main, always to the newest point: a slow app drops frames instead of lagging behind.
    private func pumpDrag() {
        guard let d = dragging, let to = dragTo else { dragBusy = false; return }
        dragTo = nil
        DispatchQueue.global(qos: .userInteractive).async {
            Writer.move(d.el, to)
            DispatchQueue.main.async { self.pumpDrag() }
        }
    }

    private func swap(_ a: CGWindowID, _ b: CGWindowID) {
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return }
        let sa = screen(of: a), sb = screen(of: b)
        if sa != sb { homes[a] = sb.displayID; homes[b] = sa.displayID } // across screens: they trade screens too
        order.swapAt(i, j)
    }

    /// Dropped where no tile is: on another screen, it joins that screen's tiles (glides across); else it glides home.
    private func dropped(_ id: CGWindowID, at p: CGPoint) {
        if let other = tiled().first(where: { $0 != id && targets[$0]?.contains(p) == true }) { return swap(id, other) }
        if let s = NSScreen.screens.first(where: { Tiler.topLeft($0.frame).contains(p) }), s != screen(of: id) { move(id, to: s) }
    }

    private func move(_ id: CGWindowID, to s: NSScreen) {
        leaving[id] = (screen(of: id).displayID, s.displayID)
        homes[id] = s.displayID
        order.removeAll { $0 == id }; order.append(id) // the newest tile there
    }

    private func focused() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        return (AX.get(el, kAXFocusedWindowAttribute) as AXUIElement?).flatMap(Tiler.id)
    }

    // MARK: Focus follows the mouse

    /// The pointer settled: after a short rest, the window under it takes focus (never mid-drag, never through a menu).
    private func pointerMoved() {
        hoverWork?.cancel()
        guard Store.shared.settings.focusFollowsMouse, NSEvent.pressedMouseButtons == 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.focusUnderPointer() }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: w)
    }

    private func focusUnderPointer() {
        guard on, NSEvent.pressedMouseButtons == 0, !Switcher.shared.isOpen, !ChavalMenu.shared.isOpen else { return }
        let m = NSEvent.mouseLocation, top = NSScreen.screens.first?.frame.maxY ?? 0
        let p = CGPoint(x: m.x, y: top - m.y)
        // The topmost window at the point, of any kind: only an ordinary app window (layer 0) of ours to tile counts,
        // so a menu, a pop-up, the bar, the dock or one of Chaval's panels over it leaves focus alone.
        for info in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), b.contains(p),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            // Chaval's window borders sit just above their windows and cover them (clear in the middle, click-through):
            // look past them to the window itself.
            if (info[kCGWindowOwnerPID as String] as? pid_t) == getpid(), (info[kCGWindowLayer as String] as? Int) == 0 { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0, let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let w = wins[id], id != focused(), let app = NSRunningApplication(processIdentifier: w.pid) else { return }
            if !FastFocus.focus(w.el, id: id, pid: w.pid) { AX.focus(w.el, of: app) }
            Borders.shared.focus(id) // recolour now, not when the app reports the change
            return
        }
    }

    enum Dir: Equatable { case west, south, north, east }

    /// The nearest tile in a direction, preferring ones lined up with the current one.
    private func neighbor(_ id: CGWindowID, _ d: Dir) -> CGWindowID? {
        guard let r = targets[id] else { return nil }
        return tiled().filter { $0 != id }.compactMap { c -> (CGWindowID, CGFloat)? in
            guard let o = targets[c] else { return nil }
            let gap: CGFloat
            switch d {
            case .west: gap = r.minX - o.maxX
            case .east: gap = o.minX - r.maxX
            case .north: gap = r.minY - o.maxY
            case .south: gap = o.minY - r.maxY
            }
            guard gap > -2 else { return nil }
            let off = d == .west || d == .east ? abs(o.midY - r.midY) : abs(o.midX - r.midX)
            return (c, gap + off * 0.5)
        }.min { $0.1 < $1.1 }?.0
    }

    private func focus(_ id: CGWindowID) {
        guard let w = wins[id], let app = NSRunningApplication(processIdentifier: w.pid) else { return }
        AX.focus(w.el, of: app)
    }

    enum Command: Equatable { case focus(Dir), swap(Dir), next, previous, promote, narrower, wider, taller, shorter, resetSplit, zoom, float, close, fullscreen, moreMain, fewerMain, nextLayout, toScreen(Int) }

    /// What the window hotkeys do. Closing and full screen work on any window; the rest need tiling on.
    func run(_ c: Command) {
        let front = NSWorkspace.shared.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
        let el = front.flatMap { AX.get($0, kAXFocusedWindowAttribute) as AXUIElement? }
        switch c {
        case .close:
            if let el, let b = AX.get(el, kAXCloseButtonAttribute) as AXUIElement? { AXUIElementPerformAction(b, kAXPressAction as CFString) }
            return
        case .fullscreen:
            if let el { AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, (!(AX.get(el, "AXFullScreen") as Bool? ?? false)) as CFBoolean) }
            return
        default: break
        }
        guard on, let id = el.flatMap(Tiler.id), wins[id] != nil else { return }
        // Accordion windows overlap, so there's no window "beside" another: left and right step through them instead.
        if Store.shared.settings.tileLayout == .accordion, case .focus(let d) = c, d == .west || d == .east { return run(d == .west ? .previous : .next) }
        let peers = tiled().filter { screen(of: $0) == screen(of: id) }
        switch c {
        case .focus(let d): neighbor(id, d).map(focus)
        case .swap(let d): if let o = neighbor(id, d) { swap(id, o); retile() }
        case .next, .previous:
            guard let i = peers.firstIndex(of: id), peers.count > 1 else { return }
            focus(peers[(i + (c == .next ? 1 : peers.count - 1)) % peers.count])
        case .promote: if let m = peers.first, m != id { swap(id, m); retile() }
        case .narrower, .wider: Store.shared.settings.tileRatio = min(0.85, max(0.15, Store.shared.settings.tileRatio + (c == .narrower ? -0.05 : 0.05)))
        case .taller, .shorter: heights[id] = min(4, max(0.25, (heights[id] ?? 1) * (c == .taller ? 1.25 : 0.8))); retile()
        case .resetSplit: Store.shared.settings.tileRatio = 0.55; heights = [:]; retile()
        case .moreMain: Store.shared.settings.tileMasters = min(Store.shared.settings.tileMasters + 1, max(peers.count, 1)); retile()
        case .fewerMain: Store.shared.settings.tileMasters = max(Store.shared.settings.tileMasters - 1, 1); retile()
        case .nextLayout:
            let all = TileLayout.allCases, cur = Store.shared.settings.tileLayout
            Store.shared.settings.tileLayout = all[(all.firstIndex(of: cur)! + 1) % all.count]
            retile()
        case .toScreen(let step):
            let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
            guard screens.count > 1, let i = screens.firstIndex(of: screen(of: id)) else { return }
            move(id, to: screens[(i + step + screens.count) % screens.count]); retile()
        case .zoom: zoomed = zoomed == id ? nil : id; retile()
        case .float:
            if floating.remove(id) == nil {
                floating.insert(id)
                let a = area(screen(of: id))
                animate(id, to: a.insetBy(dx: a.width / 4, dy: a.height / 4))
            }
            retile()
        case .close, .fullscreen: break
        }
    }

    static func selfTest() {
        var g = Anim(value: [0, 0, 400, 300], target: CGRect(x: 600, y: 200, width: 800, height: 500),
                     win: Win(el: AXUIElementCreateSystemWide(), pid: 0))
        var frames = 0
        while !glide(&g, dt: 1.0 / 120, response: 0.15) { frames += 1 }
        assert(frames < 60 && g.age < 1, "a glide settles well inside the timeout")
        let a = CGRect(x: 0, y: 0, width: 1008, height: 600)
        let two = masterStack(4, in: a, ratio: 0.5, gap: 8, masters: 2)
        assert(two[0].width == 500 && two[1].width == 500 && two[2].minX == 508 && two[3].minX == 508 && two[1].minY == two[3].minY, "2 + 2: a perfect grid")
        let gr = grid(5, in: a, gap: 8)
        assert(gr.count == 5 && gr[0].width == gr[1].width && gr[3].width > gr[0].width && gr[4].maxX == a.maxX, "grid: short last row stretches")
        let dw = dwindle(4, in: a, ratio: 0.5, gap: 8)
        assert(dw[0].maxX + 8 == dw[1].minX && dw[1].maxY + 8 == dw[2].minY && dw[2].maxX + 8 == dw[3].minX && dw[3].maxX == a.maxX && dw[3].maxY == a.maxY,
               "dwindle: right, below, right of that")
        assert(dwindle(1, in: a, ratio: 0.5, gap: 8) == [a], "dwindle: one window fills")
        let acc = accordion(3, focused: 1, in: a, peek: 30)
        assert(acc[1] == a.insetBy(dx: 30, dy: 0) && acc[0].minX == 0 && acc[2].maxX == a.maxX, "accordion: focused centred, others peek")
        let r = masterStack(3, in: a, ratio: 0.5, gap: 8)
        assert(r[0] == CGRect(x: 0, y: 0, width: 500, height: 600), "master takes its share")
        assert(r[1].minX == 508 && r[1].width == 500 && r[2].maxY == 600 && r[2].minY - r[1].maxY == 8, "stack splits with gaps")
        assert(masterStack(1, in: a, ratio: 0.5, gap: 8) == [a], "one window fills the area")
        let pair = masterStack(2, in: a, ratio: 0.5, gap: 8, masters: 2)
        assert(pair[0].maxX < pair[1].minX && pair[0].height == a.height, "two main windows still sit side by side")
        let tall = masterStack(3, in: a, ratio: 0.5, gap: 8, weights: [1, 3, 1])
        assert(tall[1].height == 444 && tall[2].height == 148 && tall[2].maxY == 600, "weights share the stack's height")
        print("tiling selftest ok (glide settles in \(frames * 1000 / 120) ms)")
    }
}

extension CGRect {
    func isClose(to o: CGRect, within t: CGFloat) -> Bool {
        abs(minX - o.minX) <= t && abs(minY - o.minY) <= t && abs(maxX - o.maxX) <= t && abs(maxY - o.maxY) <= t
    }
}

