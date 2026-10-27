import AppKit

extension NSScreen {
    var id: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    var menuInset: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
}

private let finderPath = Item.finderPath

final class DockController: NSObject {
    let panel: NSPanel
    private(set) var view: DockView!
    private(set) var screen: NSScreen
    private var triggers: [Trigger] = []

    private var shown = false
    private var expanded = false
    private var hovering = false
    private var inFullscreen = false
    private var menuOpen = false
    private var stackOpen = false
    private var visWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var exitMonitor: Any?

    private let watcher = WindowWatcher()
    private var windows: [(app: NSRunningApplication, window: AXUIElement)] = [] // minimized ones, or all in windows-only mode
    private var windowOrder: [String] = [] // window tiles keep the order they first appeared in
    private var badges: [String: String] = [:]
    private var trashFull = false
    private var bouncing: Set<String> = []
    private var stackIcons: [String: CGImage] = [:]
    private var folderWatch: [String: DispatchSourceFileSystemObject] = [:]
    private var last = Store.shared.settings
    private var lastStyles = Store.shared.iconStyles
    private var rebuildQueued = false

    private var st: Settings { Store.shared.settings }
    private var autohideNow: Bool { st.autohide || inFullscreen }
    private var holding: Bool { menuOpen || stackOpen || view.dragging != nil }
    private var px: Int { Int(ceil(view.M * (screen.backingScaleFactor))) }

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        screen = NSScreen.screens.first!
        super.init()
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        view = DockView(dock: self)
        panel.contentView = view

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didHideApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(willLaunch(_:)), name: NSWorkspace.willLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(storeChanged), name: .chavalChanged, object: nil)
        nc.addObserver(self, selector: #selector(windowsChanged), name: .chavalWindowsChanged, object: nil)
        nc.addObserver(self, selector: #selector(windowFrameChanged(_:)), name: .chavalWindowFrame, object: nil)

        // ponytail: badges are polled from the hidden system Dock every 3s while visible; it exposes no change notification.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshBadges() }
        // A game can go full screen after it's already in front (no desktop switch to tell us): check every second.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkFullscreen() }.tolerance = 0.3
        Widgets.watchPower { [weak self] in self?.refreshWidgets(.battery) }
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(woke), name: .NSSystemClockDidChange, object: nil)

        screen = pickScreen()
        refreshMinimized()
        refreshBadges()
        Trash.isFull { [weak self] in self?.trashFull = $0; self?.rebuild() }
        rebuild()
        reposition()
        inFullscreen = Space.isFullscreen(screen)
        if autohideNow { panel.orderOut(nil) } else { show() }
        updateTriggers()
        // The system Dock restarts when Chaval hides it at launch and registers its strip as it comes up.
        for delay in [1.0, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateReservation() } }
    }

    // MARK: - Tiles

    func rebuild() {
        let store = Store.shared
        let running = NSWorkspace.shared.runningApplications.filter { $0.isRegular && $0.bundleURL != nil }
        watcher.sync(running)
        var used = Set<pid_t>()
        var keys = Set<String>()

        func appTile(_ path: String, _ app: NSRunningApplication?, item: Item? = nil, section: Int = 0) -> Tile? {
            guard !keys.contains(path) else { return nil }
            keys.insert(path)
            let t = Tile(.app, key: path)
            t.url = URL(fileURLWithPath: path)
            t.app = app; t.pinned = item != nil; t.item = item; t.section = section
            t.title = app?.localizedName ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            t.image = Icons.icon(path, px: px)
            t.badge = badges[path] ?? app?.bundleURL.flatMap { badges[$0.standardizedFileURL.path] }
            t.faded = (st.dimHidden && app?.isHidden == true) || !FileManager.default.fileExists(atPath: path)
            if let app { used.insert(app.processIdentifier) }
            return t
        }
        func match(_ item: Item) -> NSRunningApplication? {
            running.first { ($0.bundleIdentifier != nil && $0.bundleIdentifier == item.bundleID) || $0.bundleURL?.path == item.path }
        }
        let finder = running.first { $0.bundleIdentifier == "com.apple.finder" }
        if let finder { used.insert(finder.processIdentifier) } // Finder is only ever shown as its own item

        // Everything the user placed, in their order.
        var tiles: [Tile] = []
        for (i, item) in store.pinned.enumerated() {
            switch item.kind {
            case .widget:
                guard item.widget != nil else { continue }
                let t = Tile(.widget, key: "g:" + item.id.uuidString)
                t.span = st.edge == .bottom || st.edge == .top ? item.widget == .desktops ? Widgets.deskSpan : item.spanCount : 1 // wide tiles only fit horizontal docks
                (t.image, t.title) = Widgets.render(item, key: t.key, px: px, span: t.span)
                if item.widget == .desktops { (t.overlay, t.highlight) = Widgets.desksActive(item, px: px, span: t.span) }
                t.item = item; tiles.append(t)
            case .spacer, .flexSpace:
                let t = Tile(item.kind == .spacer ? .spacer : .flex, key: item.id.uuidString); t.item = item; tiles.append(t)
            case .finder:
                if let t = appTile(Item.finderPath, finder, item: item) { tiles.append(t) }
            case .launcher:
                guard !keys.contains(item.path) else { continue }
                keys.insert(item.path)
                let t = Tile(.launcher, key: item.path)
                t.url = item.url; t.item = item
                t.title = FileManager.default.displayName(atPath: item.path).replacingOccurrences(of: ".app", with: "")
                t.image = Icons.icon(item.path, px: px)
                tiles.append(t)
            case .trash:
                guard !keys.contains("trash") else { continue }
                keys.insert("trash")
                let t = Tile(.trash, key: "trash"); t.item = item; t.title = "Trash"
                t.image = Icons.icon(trashFull ? Icons.trashFull : Icons.trashEmpty, px: px)
                tiles.append(t)
            case .folder, .file:
                let t = Tile(item.kind == .folder ? .folder : .file, key: "o:" + item.id.uuidString)
                t.item = item; t.url = item.url
                t.title = Folder.name(item.url)
                t.faded = !FileManager.default.fileExists(atPath: item.path)
                if item.kind == .folder && item.asStack && store.iconStyles[item.path]?.image == nil {
                    if stackIcons[item.path] == nil { stackIcons[item.path] = Icons.stack(item, px: px) }
                    t.image = stackIcons[item.path]
                } else {
                    t.image = Icons.icon(item.path, px: px)
                }
                tiles.append(t)
            case .app:
                if !FileManager.default.fileExists(atPath: item.path), let bid = item.bundleID,
                   let moved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    DispatchQueue.main.async { if store.pinned.indices.contains(i) { store.pinned[i].path = moved.path } }
                }
                if let t = appTile(item.path, match(item), item: item) { tiles.append(t) }
            }
        }
        tiles.forEach { $0.pinned = true }

        // Transient tiles slot in around the user's layout: running and recent apps after the last
        // app, minimized windows before the Trash.
        var transient = st.windowsOnly ? [] : running.filter { !used.contains($0.processIdentifier) }.compactMap { appTile($0.bundleURL!.path, $0) }
        if st.showRecents {
            transient += store.recents.filter { !keys.contains($0) && FileManager.default.fileExists(atPath: $0) }
                .prefix(st.recentCount).compactMap { appTile($0, nil, section: 1) }
        }
        let lastApp = tiles.lastIndex { [.app, .launcher].contains($0.kind) }.map { $0 + 1 } ?? 0
        tiles.insert(contentsOf: transient, at: lastApp)
        let windowTiles: [Tile] = (st.windowsOnly && !st.dockWindows ? [] : windows).map { app, w in
            let t = Tile(st.windowsOnly ? .window : .minimized, key: "w:\(app.processIdentifier):\(CFHash(w))")
            t.app = app; t.window = w; t.section = st.windowsOnly ? 0 : 2
            t.title = AX.title(w).isEmpty ? app.localizedName ?? "" : AX.title(w)
            t.image = app.bundleURL.flatMap { Icons.icon($0.path, px: px) }
            t.faded = st.windowsOnly && AX.isMinimized(w)
            return t
        }
        if st.windowsOnly {
            let keys = Set(windowTiles.map(\.key))
            windowOrder = windowOrder.filter(keys.contains) + windowTiles.map(\.key).filter { !windowOrder.contains($0) }
            // Between two flexible spaces they sit centred (after whatever's already there, e.g. the Desktops widget).
            let flexes = tiles.indices.filter { tiles[$0].kind == .flex }
            tiles.insert(contentsOf: windowTiles.sorted { windowOrder.firstIndex(of: $0.key)! < windowOrder.firstIndex(of: $1.key)! },
                         at: flexes.count >= 2 ? flexes[1] : lastApp + transient.count)
        } else {
            tiles.insert(contentsOf: windowTiles, at: tiles.firstIndex { $0.kind == .trash } ?? tiles.count)
        }

        view.set(DockController.separated(tiles))
        scheduleWidgets()
        for k in bouncing { view.bounce(k, on: true) }
        watchFolders()
        resize()
        updateReservation() // app launches/quits make the hidden Dock re-register its strip
    }

    /// Dividers go where apps meet documents (and around recents). Spacers and widgets take on their
    /// neighbours' side, so e.g. a clock after the Trash doesn't get a divider.
    static func separated(_ tiles: [Tile]) -> [Tile] {
        func side(_ t: Tile) -> Int? {
            switch t.kind {
            case .spacer, .flex, .widget, .placeholder, .separator: return nil
            case .app: return t.section == 1 ? 1 : 0
            case .launcher: return 0
            default: return 2
            }
        }
        var out: [Tile] = [], last: Int?, n = 0
        for t in tiles {
            if let s = side(t) {
                if let l = last, l != s {
                    out.append(Tile(.separator, key: "sep\(n)")); n += 1
                }
                last = s
            }
            out.append(t)
        }
        return out
    }

    // MARK: - Keeping windows out of the dock's space

    private var fitWork: [CFHashCode: DispatchWorkItem] = [:]
    private var fitAttempts: [CFHashCode: [Date]] = [:]
    private var mouseUpMonitor: Any?
    private var waitingForMouse: [AXUIElement] = []

    /// Zoom/Fill/tiling animate through many frames, so act once the window has settled, not on the first frame.
    @objc private func windowFrameChanged(_ n: Notification) {
        guard st.reserveSpace, !autohideNow, let obj = n.object, CFGetTypeID(obj as CFTypeRef) == AXUIElementGetTypeID() else { return }
        let w = obj as! AXUIElement, id = CFHash(w)
        fitWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fitWork[id] = nil
            if NSEvent.pressedMouseButtons != 0 { return self.fitAfterMouseUp(w) } // mid-drag: don't fight the user
            self.fit(w)
        }
        fitWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func fitAfterMouseUp(_ w: AXUIElement) {
        waitingForMouse.append(w)
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self else { return }
            if let m = self.mouseUpMonitor { NSEvent.removeMonitor(m); self.mouseUpMonitor = nil }
            let ws = self.waitingForMouse; self.waitingForMouse = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { ws.forEach(self.fit) }
        }
    }

    /// The strip the dock occupies, in global top-left coordinates, spanning the whole edge like the system Dock's.
    private var reservedStrip: CGRect {
        let f = screen.frame, h = NSScreen.screens.first?.frame.height ?? f.height
        let cg = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height), t = view.thickness
        switch st.edge {
        case .bottom: return CGRect(x: cg.minX, y: cg.maxY - t, width: cg.width, height: t)
        case .top: return CGRect(x: cg.minX, y: cg.minY + screen.menuInset, width: cg.width, height: t)
        case .left: return CGRect(x: cg.minX, y: cg.minY, width: t, height: cg.height)
        case .right: return CGRect(x: cg.maxX - t, y: cg.minY, width: t, height: cg.height)
        }
    }

    /// Trims a window that was resized or opened under the dock so it ends at the dock's edge.
    private func fit(_ w: AXUIElement) {
        guard st.reserveSpace, !autohideNow, !reserved, AX.get(w, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole,
              AX.get(w, "AXFullScreen") as Bool? != true, let r = AX.frame(w) else { return }
        let strip = reservedStrip
        guard r.intersection(strip).width > 1, r.intersection(strip).height > 1 else { return }
        // An app that keeps restoring its size gets three tries, then is left alone.
        let id = CFHash(w), now = Date()
        let tries = (fitAttempts[id] ?? []).filter { now.timeIntervalSince($0) < 3 }
        guard tries.count < 3 else { return }
        fitAttempts = fitAttempts.filter { $0.value.contains { now.timeIntervalSince($0) < 3 } }
        fitAttempts[id] = tries + [now]
        var n = r
        switch st.edge {
        case .bottom: n.size.height = strip.minY - r.minY; if n.height < 100 { n = r.offsetBy(dx: 0, dy: strip.minY - r.maxY) }
        case .top: n.origin.y = strip.maxY; n.size.height = r.maxY - strip.maxY; if n.height < 100 { n = r.offsetBy(dx: 0, dy: strip.maxY - r.minY) }
        case .left: n.origin.x = strip.maxX; n.size.width = r.maxX - strip.maxX; if n.width < 100 { n = r.offsetBy(dx: strip.maxX - r.minX, dy: 0) }
        case .right: n.size.width = strip.minX - r.minX; if n.width < 100 { n = r.offsetBy(dx: strip.minX - r.maxX, dy: 0) }
        }
        AX.setFrame(w, n)
    }

    // MARK: - Widgets

    /// Small: play/pause. Wide: the art opens the player; the text column's thirds are previous/play/next.
    private func musicClick(_ item: Item, span: Int, at x: CGFloat) {
        let np = NowPlaying.shared
        guard span > 1 else { return np.track == nil ? np.openPlayer() : np.send("playpause") }
        let px = x * CGFloat(span)
        guard px > 1, item.opt("controls"), np.track != nil else { return np.openPlayer() }
        let third = Int(min(max((px - 1) / (CGFloat(span) - 1) * 3, 0), 2.999))
        np.send(["previous track", "playpause", "next track"][third])
    }

    private var clockTimer: Timer?
    private var deskTimer: Timer?
    private var statsTimer: Timer?

    /// Clock/date tick once a minute on the minute; CPU/memory every 2s. Timers exist only while such widgets do.
    /// Re-reads which apps are on which desktop, off the main thread; rebuilds when that (or `force`) changed.
    private func refreshDesks(force: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = Desktops.apps()
            DispatchQueue.main.async {
                let changed = apps.map { $0.map(\.processIdentifier) } != Widgets.desks.map { $0.map(\.processIdentifier) }
                Widgets.desks = apps
                if changed || force { self?.rebuild() }
            }
        }
    }

    private func scheduleWidgets() {
        let widgets = Store.shared.pinned.filter { $0.kind == .widget }
        let kinds = Set(widgets.compactMap(\.widget))
        // ponytail: which apps are on which desktop is re-read every 2s; macOS announces no such change.
        if kinds.contains(.desktops) {
            if deskTimer == nil {
                refreshDesks(force: true)
                deskTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshDesks() }
                deskTimer?.tolerance = 0.5
            }
        } else { deskTimer?.invalidate(); deskTimer = nil }
        if kinds.contains(.music) { NowPlaying.shared.start { [weak self] in self?.refreshWidgets(.music) } }
        // Clocks showing seconds tick every second; otherwise once a minute, on the minute.
        let interval: TimeInterval = widgets.contains { $0.widget == .clock && $0.opt("seconds") } ? 1 : 60
        if clockTimer?.timeInterval != interval { clockTimer?.invalidate(); clockTimer = nil }
        if kinds.contains(.clock) || kinds.contains(.date) {
            if clockTimer == nil {
                let next = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / interval).rounded(.down) * interval + interval)
                let t = Timer(fire: next, interval: interval, repeats: true) { [weak self] _ in self?.refreshWidgets(.clock, .date) }
                t.tolerance = interval == 1 ? 0.05 : 0.5
                RunLoop.main.add(t, forMode: .common)
                clockTimer = t
            }
        } else { clockTimer?.invalidate(); clockTimer = nil }
        if kinds.contains(.cpu) || kinds.contains(.memory) {
            if statsTimer == nil {
                // ponytail: CPU/memory have no change notification, so they poll, and only while the dock is visible.
                statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Widgets.sample() // keep the history graph continuous even while hidden
                    if self?.shown == true { self?.refreshWidgets(.cpu, .memory) }
                }
                statsTimer?.tolerance = 0.5
            }
        } else { statsTimer?.invalidate(); statsTimer = nil }
    }

    private func refreshWidgets(_ kinds: WidgetKind...) {
        for t in view.tiles where t.kind == .widget {
            guard let k = t.item?.widget, kinds.isEmpty || kinds.contains(k) else { continue }
            (t.image, t.title) = Widgets.render(t.item!, key: t.key, px: px, span: t.span)
            view.setImage(t.key, t.image)
        }
        if view.hover != nil { view.layout(animated: false) } // refresh the label text
    }

    @objc private func woke() {
        clockTimer?.invalidate(); clockTimer = nil // re-align to the minute
        scheduleWidgets()
        refreshWidgets()
    }

    private func rebuildSoon() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in self?.rebuildQueued = false; self?.rebuild() }
    }

    private func watchFolders() {
        let stacks = Set(Store.shared.pinned.filter { $0.kind == .folder && $0.asStack }.map(\.path))
        for (p, src) in folderWatch where !stacks.contains(p) { src.cancel(); folderWatch[p] = nil }
        for p in stacks where folderWatch[p] == nil {
            let fd = Darwin.open(p, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.stackIcons[p] = nil; self?.rebuildSoon() }
            src.setCancelHandler { close(fd) }
            src.resume()
            folderWatch[p] = src
        }
    }

    // MARK: - Events

    @objc private func appsChanged(_ n: Notification) {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let path = app?.bundleURL?.path {
            if n.name == NSWorkspace.didLaunchApplicationNotification {
                bouncing.remove(path); view.bounce(path, on: false)
                Icons.forget(path)
            }
            if n.name == NSWorkspace.didTerminateApplicationNotification, app?.isRegular == true,
               !Store.shared.pinned.contains(where: { $0.path == path || $0.bundleID == app?.bundleIdentifier }), path != Item.finderPath {
                Store.shared.recents = Array(([path] + Store.shared.recents.filter { $0 != path }).prefix(10))
            }
        }
        if n.name == NSWorkspace.didTerminateApplicationNotification { refreshMinimized() }
        rebuildSoon()
        if bouncing.isEmpty { scheduleCollapse() }
    }

    @objc private func willLaunch(_ n: Notification) {
        guard st.launchAnim != .none, let path = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path else { return }
        startBounce(path)
    }

    private func startBounce(_ key: String) {
        guard st.launchAnim != .none else { return }
        bouncing.insert(key)
        rebuildSoon()
        DispatchQueue.main.async { [weak self] in self?.expand(); self?.view.bounce(key, on: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.bouncing.remove(key) != nil else { return }
            self.view.bounce(key, on: false); self.scheduleCollapse()
        }
    }

    @objc private func spaceChanged() {
        checkFullscreen()
        if Store.shared.pinned.contains(where: { $0.widget == .desktops }) { refreshDesks(force: true) } // its count and highlight
        updateReservation() // the hidden system Dock can re-register its own strip; put ours back
        // The window list lags the space-switch animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkFullscreen()
            if self?.st.windowsOnly == true { self?.windowsChanged() } // each desktop has its own windows
        }
    }

    private func checkFullscreen() {
        let fs = Space.isFullscreen(screen)
        guard fs != inFullscreen else { return }
        inFullscreen = fs
        applyVisibility()
    }

    @objc private func screensChanged() {
        screen = pickScreen()
        Icons.clear(); stackIcons = [:]
        rebuild()
        reposition()
    }

    @objc private func storeChanged() {
        let s = st
        if s != last {
            if s.windowsOnly != last.windowsOnly || s.minimizeIntoApp != last.minimizeIntoApp { refreshMinimized() }
            if s.iconSize != last.iconSize || s.magnifiedSize != last.magnifiedSize || s.magnify != last.magnify
                || s.iconTint != last.iconTint || s.iconTintHex != last.iconTintHex
                || s.iconTintStrength != last.iconTintStrength || s.iconTintMode != last.iconTintMode { Icons.clear(); stackIcons = [:] }
            view.applyStyle()
            last = s
            screen = pickScreen()
            stackIcons = [:]
            rebuild()
            reposition()
            applyVisibility()
        } else {
            let styles = Store.shared.iconStyles
            for k in Set(styles.keys).union(lastStyles.keys) where styles[k] != lastStyles[k] { Icons.forget(k); stackIcons[k] = nil }
            lastStyles = styles
            rebuildSoon()
        }
    }

    @objc private func windowsChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshMinimizedNow), object: nil)
        perform(#selector(refreshMinimizedNow), with: nil, afterDelay: 0.15)
    }
    @objc private func refreshMinimizedNow() { refreshMinimized(); rebuild() }

    private func refreshMinimized() {
        let all = st.windowsOnly
        guard all || !st.minimizeIntoApp else { windows = []; return }
        // Apps like Discord only hide a window when it's closed; it stays listed but is on no desktop, so it would show on all of them.
        let shown = all ? Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }) : []
        windows = NSWorkspace.shared.runningApplications.filter { $0.isRegular }
            .flatMap { app in AX.windows(app).filter { AX.isMinimized($0) || all && Tiler.id($0).map(shown.contains) == true }.map { (app, $0) } }
    }

    private func refreshBadges() {
        guard shown else { return }
        let b = SystemDock.badges()
        if b != badges { badges = b; rebuild() }
    }

    private func refreshTrash() {
        Trash.isFull { [weak self] full in
            guard let self, full != self.trashFull else { return }
            self.trashFull = full
            self.view.setImage("trash", Icons.icon(full ? Icons.trashFull : Icons.trashEmpty, px: self.px))
        }
    }

    func trashShowsEject(_ on: Bool) {
        view.setImage("trash", Icons.icon(on ? Icons.eject : trashFull ? Icons.trashFull : Icons.trashEmpty, px: px))
    }

    // MARK: - Geometry & visibility

    private func pickScreen() -> NSScreen {
        let screens = NSScreen.screens
        switch st.displayMode {
        case .main: return screens.first!
        case .fixed: return screens.first { $0.localizedName == st.fixedDisplay } ?? screens.first!
        case .followCursor: return screens.first { $0.id == screen.id } ?? screens.first!
        }
    }

    private func maxAlong(_ s: NSScreen) -> CGFloat {
        st.edge == .bottom || st.edge == .top ? s.frame.width : s.frame.height - s.menuInset
    }

    private func frame(expanded e: Bool, hidden: Bool = false, on s: NSScreen? = nil) -> NSRect {
        let s = s ?? screen, sf = s.frame, top = s.menuInset
        let along = e ? min(view.baseLength + 2 * view.magnifyExtra, maxAlong(s)) : min(view.baseLength, maxAlong(s))
        let across = e ? view.thickness + view.headroom : view.thickness
        let hide = hidden ? across : 0
        let cy = (sf.minY + sf.maxY - top) / 2
        switch st.edge {
        case .bottom: return NSRect(x: sf.midX - along / 2, y: sf.minY - hide, width: along, height: across)
        case .top: return NSRect(x: sf.midX - along / 2, y: sf.maxY - top - across + (hidden ? across + top : 0), width: along, height: across)
        case .left: return NSRect(x: sf.minX - hide, y: cy - along / 2, width: across, height: along)
        case .right: return NSRect(x: sf.maxX - across + hide, y: cy - along / 2, width: across, height: along)
        }
    }

    private func resize() {
        guard shown else { return }
        panel.setFrame(frame(expanded: expanded), display: true)
        rebuildTriggers()
    }

    private func reposition() {
        view.maxLength = maxAlong(screen) - (st.taskbar ? 2 * CGFloat(st.edgeGap) : 16)
        view.layout(animated: false)
        panel.setFrame(frame(expanded: expanded, hidden: !shown), display: true)
        rebuildTriggers()
    }

    /// True while the window server is reserving the dock's strip for us.
    private var reserved = false

    /// Reserve the strip whenever the dock is set to stay visible; release it (a zero-height strip, like the
    /// hidden system Dock's) only for auto-hide. Running apps cache the visible frame and aren't told when it
    /// changes, so it deliberately stays put through full-screen spaces (which ignore it anyway). No-op when unchanged.
    private func updateReservation() {
        let want = st.reserveSpace && !st.autohide
        var strip = reservedStrip
        if !want {
            switch st.edge {
            case .bottom: strip.origin.y = strip.maxY; strip.size.height = 0
            case .top: strip.size.height = 0
            case .left: strip.size.width = 0
            case .right: strip.origin.x = strip.maxX; strip.size.width = 0
            }
        }
        reserved = WindowServer.setDockRect(strip) && want
        let mine: CGRect? = want && !autohideNow ? reservedStrip : nil
        if mine != DockController.strip { DockController.strip = mine; NotificationCenter.default.post(name: .chavalDockStrip, object: nil) }
    }

    /// The strip the dock keeps windows out of (global top-left coordinates), straight from the dock: macOS's own
    /// usable area lags behind it (right after Chaval launches it briefly covers the whole screen).
    private(set) static var strip: CGRect?

    private func applyVisibility() {
        if !autohideNow { show() } else if !hovering && !holding { hide() }
        updateTriggers()
    }

    func show() {
        visWork?.cancel()
        guard !shown else { return }
        if inFullscreen && !st.showInFullscreen { return }
        shown = true
        let target = frame(expanded: expanded)
        switch reveal {
        case .slide:
            if !panel.isVisible {
                panel.setFrame(frame(expanded: expanded, hidden: true), display: false)
                panel.orderFrontRegardless()
                Desktops.pinAbove(panel)
            }
            animate(to: target) {}
        case .fade, .zoom:
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            Desktops.pinAbove(panel)
            NSAnimationContext.runAnimationGroup { $0.duration = st.animationSpeed; panel.animator().alphaValue = 1 }
            if reveal == .zoom { view.zoom(from: 0.6, to: 1, duration: st.animationSpeed) }
        case .none:
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            Desktops.pinAbove(panel)
        }
        if autohideNow && exitMonitor == nil {
            // Tracking areas don't fire for a window that slides in under a still cursor; catch the exit globally.
            exitMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                if self.hovering { self.hoverEnded() } else if !self.holding { self.scheduleHide() }
            }
        }
        refreshBadges()
        updateTriggers()
    }

    func hide() {
        guard shown, !hovering, !holding, bouncing.isEmpty else { return }
        shown = false
        if let m = exitMonitor { NSEvent.removeMonitor(m); exitMonitor = nil }
        expanded = false
        let away = frame(expanded: false, hidden: true)
        let finish = { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.setFrame(away, display: false)
            self.view.resetZoom()
        }
        switch reveal {
        case .slide: animate(to: away, done: finish)
        case .fade, .zoom:
            NSAnimationContext.runAnimationGroup({ $0.duration = st.animationSpeed; panel.animator().alphaValue = 0 }, completionHandler: finish)
            if reveal == .zoom { view.zoom(from: 1, to: 0.6, duration: st.animationSpeed) }
        case .none: finish()
        }
        updateTriggers()
    }

    private var reveal: RevealAnim { Store.shared.reduceMotion ? .none : st.revealAnim }

    private func animate(to r: NSRect, done: @escaping () -> Void) {
        let speed = Store.shared.reduceMotion ? 0 : st.animationSpeed
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = speed
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(r, display: true)
        }, completionHandler: done)
    }

    private func scheduleHide() {
        guard autohideNow, visWork == nil || visWork!.isCancelled else { return }
        let w = DispatchWorkItem { [weak self] in self?.visWork = nil; self?.hide() }
        visWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func expand() {
        collapseWork?.cancel()
        guard shown, !expanded else { return }
        expanded = true
        panel.setFrame(frame(expanded: true), display: true)
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.expanded, !self.hovering, !self.holding, self.bouncing.isEmpty, self.shown else { return }
            self.expanded = false
            self.panel.setFrame(self.frame(expanded: false), display: true)
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func hoverBegan() {
        visWork?.cancel(); visWork = nil
        guard !hovering else { return }
        hovering = true
        refreshTrash()
        expand()
    }

    func hoverEnded() {
        guard hovering, !holding else { return }
        hovering = false
        view.hover = nil
        view.layout(animated: true)
        scheduleCollapse()
        scheduleHide()
    }

    private func afterHold() {
        if panel.frame.contains(NSEvent.mouseLocation) { return }
        hovering = true // force the exit path
        hoverEnded()
    }

    // MARK: - Edge triggers (1px strips: zero cost until the cursor touches them)

    private func rebuildTriggers() {
        let screens = st.displayMode == .followCursor ? NSScreen.screens : [screen]
        if triggers.map(\.screenID) == screens.map(\.id) {
            zip(triggers, screens).forEach { $0.setFrame(strip($1), display: false) }
            return updateTriggers()
        }
        triggers.forEach { $0.close() }
        triggers = screens.map { s in
            let t = Trigger(strip(s), screenID: s.id)
            t.onEnter = { [weak self] in self?.edgeHit(s) }
            t.onExit = { [weak self] in if self?.shown == false { self?.visWork?.cancel() } }
            return t
        }
        updateTriggers()
    }

    private func strip(_ s: NSScreen) -> NSRect {
        // On a screen the dock isn't on, the whole edge calls it over (like macOS); the dock-wide strip was too small to find.
        let sf = s.frame, r = s.id == screen.id ? frame(expanded: false, on: s) : sf
        switch st.edge {
        case .bottom: return NSRect(x: r.minX, y: sf.minY, width: r.width, height: 2)
        case .top: return NSRect(x: r.minX, y: sf.maxY - s.menuInset - 2, width: r.width, height: 2)
        case .left: return NSRect(x: sf.minX, y: r.minY, width: 2, height: r.height)
        case .right: return NSRect(x: sf.maxX - 2, y: r.minY, width: 2, height: r.height)
        }
    }

    private func updateTriggers() {
        for t in triggers {
            let other = t.screenID != screen.id
            let active = other || (!shown && (!inFullscreen || st.showInFullscreen))
            t.ignoresMouseEvents = !active
            if active { t.orderFrontRegardless() } else { t.orderOut(nil) }
        }
        updateReservation()
    }

    private func edgeHit(_ s: NSScreen) {
        visWork?.cancel()
        let moving = s.id != screen.id
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.visWork = nil
            if moving {
                self.shown = false
                self.panel.orderOut(nil)
                self.screen = s
                self.inFullscreen = Space.isFullscreen(s)
                self.reposition()
            }
            self.show()
            if self.panel.frame.contains(NSEvent.mouseLocation) || self.autohideNow { self.hoverBegan() }
        }
        visWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (moving ? max(st.autohideDelay, 0.3) : st.autohideDelay), execute: w)
    }

    // MARK: - Actions

    func click(_ t: Tile, _ mods: NSEvent.ModifierFlags, at x: CGFloat = 0.5) {
        guard let url = t.url ?? t.app?.bundleURL else {
            if t.kind == .trash { NSWorkspace.shared.open(Trash.url) }
            if t.kind == .widget, let item = t.item, let k = item.widget {
                if k == .music { musicClick(item, span: t.span, at: x) }
                else if k == .desktops, let i = Widgets.deskSlots(1).firstIndex(where: { $0.maxX >= x }), Widgets.shown.indices.contains(i) { HotKeys.Action(rawValue: "desktop\(Widgets.shown[i] + 1)")?.run() }
                else { Widgets.open(k) }
            }
            if t.kind == .minimized || t.kind == .window, let w = t.window, let app = t.app { AX.focus(w, of: app) }
            return
        }
        if mods.contains(.command) && t.kind != .minimized { return NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if !FileManager.default.fileExists(atPath: url.path) { return missing(t) }
        switch t.kind {
        case .app:
            if let app = t.app {
                if st.clickHides && app.isActive && !mods.contains(.option) { app.hide(); return }
                bringForward(app)
                if mods.contains(.option) { hideOthers(app) }
            } else {
                startBounce(t.key)
                launch(url) { [weak self] app in if mods.contains(.option), let app { self?.hideOthers(app) } }
            }
        case .launcher: launch(url)
        case .file: NSWorkspace.shared.open(url)
        case .folder: openStack(t)
        case .minimized: if let w = t.window, let app = t.app { AX.focus(w, of: app) }
        default: break
        }
    }

    private func hideOthers(_ keep: NSRunningApplication) {
        NSWorkspace.shared.runningApplications.filter { $0 != keep && $0.isRegular }.forEach { $0.hide() }
    }

    private func missing(_ t: Tile) {
        let a = NSAlert()
        a.messageText = "The item “\(t.title)” can’t be opened because it can’t be found."
        a.addButton(withTitle: "OK")
        if t.pinned, t.item != nil { a.addButton(withTitle: "Remove from Dock") }
        NSApp.activate()
        if a.runModal() == .alertSecondButtonReturn { remove(t) }
    }

    private func remove(_ t: Tile) {
        guard let id = t.item?.id else { return }
        Store.shared.pinned.removeAll { $0.id == id }
    }

    private func screenRect(_ r: NSRect) -> NSRect { panel.convertToScreen(view.convert(r, to: nil)) }

    private func openStack(_ t: Tile) {
        guard let item = t.item else { return }
        if item.view == .list {
            let r = view.frame(of: t)
            hold { FolderMenu(item.url, sort: item.sort).popUp(positioning: nil, at: NSPoint(x: r.midX, y: r.maxY), in: self.view) }
            return
        }
        stackOpen = true
        StackPanel.show(item, view: item.view, anchor: screenRect(view.frame(of: t)), bar: screenRect(view.barRect), edge: st.edge) { [weak self] in
            self?.stackOpen = false
            self?.afterHold()
        }
    }

    /// Runs a modal menu while keeping the dock open.
    private func hold(_ f: () -> Void) {
        menuOpen = true
        f()
        menuOpen = false
        afterHold()
    }

    func cycleWindows(_ t: Tile, forward: Bool) {
        guard let app = t.app else { return }
        let wins = AX.windows(app).filter { !AX.isMinimized($0) }
        guard wins.count > 0 else { return bringForward(app) }
        // AX lists windows front to back: raise the back one, or send the front one to the back.
        let w = forward ? wins.last! : wins.count > 1 ? wins[1] : wins[0]
        AX.focus(w, of: app)
    }

    /// The dock's order after a drag is simply the on-screen order of the user's items. Dragging a running
    /// app that wasn't kept in the Dock pins it where it was dropped.
    func commitDrag(_ t: Tile, removed: Bool) {
        Store.shared.pinned = view.tiles.compactMap { x in
            if x === t { return removed ? nil : x.item ?? Item(kind: .app, path: x.url!.path, bundleID: x.app?.bundleIdentifier) }
            return x.pinned ? x.item : nil
        }
        rebuild()
    }

    func pin(_ urls: [URL], at index: Int) {
        let store = Store.shared
        let dup = { (p: Item) in urls.contains { $0.path == p.path } }
        let at = store.pinned.prefix(index).filter { !dup($0) }.count
        var pinned = store.pinned.filter { !dup($0) }
        let items = urls.map { u -> Item in
            if u.path == finderPath { return Item(kind: .finder, path: finderPath) }
            if u.pathExtension == "app" { return Item(kind: .app, path: u.path, bundleID: Bundle(url: u)?.bundleIdentifier) }
            return Item(kind: Folder.isDir(u) ? .folder : .file, path: u.path)
        }
        if items.contains(where: { $0.kind == .finder }) { pinned.removeAll { $0.kind == .finder } }
        pinned.insert(contentsOf: items, at: min(at, pinned.count))
        store.pinned = pinned
    }

    func drop(_ urls: [URL], onto t: Tile?, copy: Bool) {
        let fm = FileManager.default
        switch t?.kind {
        case .trash:
            if urls.allSatisfy(Volumes.isEjectable) {
                urls.forEach { try? NSWorkspace.shared.unmountAndEjectDevice(at: $0) }
            } else {
                NSWorkspace.shared.recycle(urls) { [weak self] _, _ in self?.refreshTrash() }
            }
        case .app:
            guard let app = t?.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .folder:
            guard let dir = t?.url else { return }
            for u in urls {
                let dest = dir.appendingPathComponent(u.lastPathComponent)
                let sameVolume = (try? u.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject)
                    == (try? dir.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject)
                do {
                    if copy || !sameVolume { try fm.copyItem(at: u, to: dest) } else { try fm.moveItem(at: u, to: dest) }
                } catch {
                    NSApp.activate(); NSAlert(error: error).runModal()
                }
            }
        default:
            pin(urls, at: Store.shared.pinned.count)
        }
    }

    // MARK: - Menus

    func showMenu(for t: Tile?, at p: NSPoint) {
        let m = t.map(menu) ?? dockMenu()
        hold { m.popUp(positioning: nil, at: p, in: view) }
    }

    private func menu(for t: Tile) -> NSMenu {
        let m = NSMenu()
        let store = Store.shared
        func add(_ i: NSMenuItem) { m.addItem(i) }
        let removeItem = Menu.item("Remove from Dock") { [weak self] in self?.remove(t) }

        switch t.kind {
        case .app:
            let url = t.url!
            if let app = t.app {
                let wins = AX.windows(app)
                for w in wins {
                    let mi = Menu.item(AX.title(w).isEmpty ? app.localizedName ?? "Window" : AX.title(w)) { AX.focus(w, of: app) }
                    if AX.isMinimized(w) { mi.state = .mixed }
                    add(mi)
                }
                if !wins.isEmpty { add(.separator()) }
            }
            var options: [NSMenuItem] = []
            if url.path == finderPath {
                options.append(Menu.item("Keep in Dock", checked: true) { [weak self] in self?.remove(t) })
                options.append(.separator())
            } else {
                options.append(Menu.item("Keep in Dock", checked: t.pinned) {
                    if t.pinned { store.pinned.removeAll { $0.path == url.path || ($0.bundleID != nil && $0.bundleID == t.app?.bundleIdentifier) } }
                    else { store.pinned.append(Item(kind: .app, path: url.path, bundleID: Bundle(url: url)?.bundleIdentifier)) }
                })
                let login = Menu.item("Open at Login") { LoginItems.set(url, !LoginItems.contains(url)) }
                options.append(login)
                options.append(.separator())
            }
            options.append(Menu.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            options.append(iconMenu(url.path))
            let opts = Menu.sub("Options", options)
            opts.submenu?.delegate = LoginState.shared
            LoginState.shared.url = url
            add(opts)
            add(.separator())
            if let app = t.app {
                if url.path == finderPath { add(Menu.item("New Finder Window") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) }) }
                add(Menu.item(app.isHidden ? "Show" : "Hide") { if app.isHidden { app.unhide() } else { app.hide() } })
                // ⌥ held when the menu opens: Force Quit outright (alternate items don't swap reliably in a
                // menu opened from a non-activating panel); otherwise Quit, with Force Quit as the ⌥ alternate.
                let option = NSEvent.modifierFlags.contains(.option)
                if url.path == finderPath {
                    if option { add(Menu.item("Relaunch") { app.forceTerminate(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { launch(url) } }) }
                } else if option {
                    add(Menu.item("Force Quit") { app.forceTerminate() })
                } else {
                    add(Menu.item("Quit") { app.terminate() })
                    let fq = Menu.item("Force Quit") { app.forceTerminate() }
                    fq.isAlternate = true
                    fq.keyEquivalentModifierMask = .option
                    add(fq)
                }
            } else {
                add(Menu.item("Open") { [weak self] in self?.click(t, []) })
            }
        case .folder:
            let item = t.item!
            func update(_ f: @escaping (inout Item) -> Void) -> () -> Void {
                { if let i = store.pinned.firstIndex(where: { $0.id == item.id }) { f(&store.pinned[i]) } }
            }
            add(Menu.sub("Sort by", [("Name", StackSort.name), ("Date Added", .dateAdded), ("Date Modified", .dateModified),
                                      ("Date Created", .dateCreated), ("Kind", .kind)].map { name, s in
                Menu.item(name, checked: item.sort == s, update { $0.sort = s })
            }))
            add(Menu.sub("Display as", [Menu.item("Folder", checked: !item.asStack, update { $0.asStack = false }),
                                         Menu.item("Stack", checked: item.asStack, update { $0.asStack = true })]))
            add(Menu.sub("View content as", [("Fan", StackView.fan), ("Grid", .grid), ("List", .list), ("Automatic", .auto)].map { name, v in
                Menu.item(name, checked: item.view == v, update { $0.view = v })
            }))
            add(.separator())
            add(Menu.item("Open “\(t.title)”") { NSWorkspace.shared.open(item.url) })
            add(iconMenu(item.path))
            add(.separator())
            add(removeItem)
        case .file:
            add(Menu.item("Open") { NSWorkspace.shared.open(t.url!) })
            add(Menu.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([t.url!]) })
            add(iconMenu(t.url!.path))
            add(.separator())
            add(removeItem)
        case .trash:
            add(Menu.item("Open") { NSWorkspace.shared.open(Trash.url) })
            add(.separator())
            add(Menu.item("Empty Trash") { [weak self] in Trash.empty(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refreshTrash() } })
            add(iconMenu(Icons.trashEmpty, image: false))
            add(.separator())
            add(removeItem)
        case .window:
            add(Menu.item("Show") { [weak self] in self?.click(t, []) })
            add(Menu.item("Minimize") { if let w = t.window { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) } })
            add(Menu.item("Close") { if let b: AXUIElement = t.window.flatMap({ AX.get($0, kAXCloseButtonAttribute) }) { AXUIElementPerformAction(b, kAXPressAction as CFString) } })
        case .minimized:
            add(Menu.item("Restore") { [weak self] in self?.click(t, []) })
        case .launcher:
            add(iconMenu(t.key))
            add(.separator())
            add(removeItem)
        case .widget:
            let item = t.item!, kind = item.widget!
            func update(_ f: @escaping (inout Item) -> Void) -> () -> Void {
                { if let i = store.pinned.firstIndex(where: { $0.id == item.id }) { f(&store.pinned[i]) } }
            }
            if kind == .music {
                let np = NowPlaying.shared
                add(Menu.item(np.track?.playing == true ? "Pause" : "Play") { np.send("playpause") })
                add(Menu.item("Next Track") { np.send("next track") })
                add(Menu.item("Previous Track") { np.send("previous track") })
                add(Menu.item("Open \(np.track?.player ?? "Player")") { np.openPlayer() })
            } else {
                add(Menu.item("Open \(kind == .battery ? "Battery Settings" : kind == .cpu || kind == .memory ? "Activity Monitor" : "Calendar")") { Widgets.open(kind) })
            }
            add(.separator())
            add(Menu.sub("Size", [("Small", 1), ("Wide", 2), ("Extra Wide", 3), ("Huge", 4)].map { name, n in
                Menu.item(name, checked: item.spanCount == n, update { $0.spanCount = n })
            }))
            add(Menu.sub("Text Size", [("Small", 0.85), ("Medium", 1.0), ("Large", 1.2), ("Extra Large", 1.4)].map { name, v in
                Menu.item(name, checked: (item.textScale ?? 1) == v, update { $0.textScale = v == 1 ? nil : v })
            }))
            for (key, label) in kind.options {
                add(Menu.item(label, checked: item.opt(key), update { $0.setOpt(key, !item.opt(key)) }))
            }
            add(Menu.item("Widget Options…") { SettingsWindow.show(tab: .widgets) })
            add(iconMenu(t.key, image: false))
            add(.separator())
            add(removeItem)
        case .spacer:
            add(removeItem)
        case .flex:
            let dm = dockMenu()
            dm.insertItem(.separator(), at: 0)
            dm.insertItem(Menu.item("Remove Flexible Space") { [weak self] in self?.remove(t) }, at: 0)
            return dm
        default:
            return dockMenu()
        }
        return m
    }

    /// "Icon ▸" submenu: custom image and per-icon tint, for any item with a path.
    private func iconMenu(_ path: String, image: Bool = true) -> NSMenuItem {
        let store = Store.shared
        let style = store.iconStyles[path]
        var items = image ? [Menu.item("Change Icon…") { IconPicker.chooseImage(for: path) }] : []
        if image && style?.image != nil { items.append(Menu.item("Reset Icon") { store.setIcon(path, from: nil) }) }
        items.append(.separator())
        items.append(Menu.item("Tint: Dock Default", checked: style?.tintHex == nil) { store.setTint(path, nil) })
        items.append(Menu.item("Tint: None", checked: style?.tintHex == "") { store.setTint(path, "") })
        items.append(Menu.item("Tint: Custom Color…", checked: !(style?.tintHex ?? "").isEmpty) { IconPicker.chooseTint(for: path) })
        return Menu.sub("Icon", items)
    }

    private func dockMenu() -> NSMenu {
        let m = NSMenu()
        let store = Store.shared
        m.addItem(Menu.item("Turn Hiding \(st.autohide ? "Off" : "On")") { store.settings.autohide.toggle() })
        m.addItem(Menu.item("Turn Magnification \(st.magnify ? "Off" : "On")") { store.settings.magnify.toggle() })
        m.addItem(Menu.sub("Position on Screen", Edge.allCases.map { e in
            Menu.item(e.rawValue.capitalized, checked: st.edge == e) { store.settings.edge = e }
        }))
        m.addItem(Menu.item("Taskbar Mode", checked: st.taskbar) { store.setTaskbar(!store.settings.taskbar) })
        m.addItem(Menu.item("Show Windows Instead of Apps", checked: st.windowsOnly) { store.settings.windowsOnly.toggle() })
        m.addItem(Menu.item("Always Show Names", checked: st.labels == .always) { store.settings.labels = store.settings.labels == .always ? .hover : .always })
        m.addItem(Menu.item("Add Spacer") { store.pinned.append(Item(kind: .spacer)) })
        m.addItem(Menu.item("Add Flexible Space") { store.pinned.append(Item(kind: .flexSpace)) })
        m.addItem(Menu.sub("Add Widget", WidgetKind.allCases.map { k in Menu.item(k.name) { store.pinned.append(Item(kind: .widget, widget: k)) } }))
        m.addItem(.separator())
        m.addItem(Menu.item("Chaval Settings…") { SettingsWindow.show() })
        m.addItem(Menu.item("Quit Chaval (restores system Dock)") { NSApp.terminate(nil) })
        return m
    }
}

/// Fills in the "Open at Login" checkmark only when the Options submenu opens (it costs an Apple Event).
private final class LoginState: NSObject, NSMenuDelegate {
    static let shared = LoginState()
    var url: URL?
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let url, let mi = menu.items.first(where: { $0.title == "Open at Login" }) else { return }
        mi.state = LoginItems.contains(url) ? .on : .off
    }
}

// MARK: - Icon customisation pickers

enum IconPicker {
    static func chooseImage(for path: String) {
        let p = NSOpenPanel()
        p.title = "Choose an icon for “\(FileManager.default.displayName(atPath: path))”"
        p.message = "Pick an image, an .icns file, or an app to borrow its icon."
        p.allowedContentTypes = [.image, .icns, .applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        if p.runModal() == .OK, let u = p.url { Store.shared.setIcon(path, from: u) }
    }

    static func chooseTint(for path: String) {
        Tint.shared.path = path
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = Icons.tint(for: path) ?? NSColor(hex: Store.shared.settings.iconTintHex)
        panel.setTarget(Tint.shared)
        panel.setAction(#selector(Tint.changed(_:)))
        NSApp.activate()
        panel.orderFront(nil)
    }

    private final class Tint: NSObject {
        static let shared = Tint()
        var path = ""
        @objc func changed(_ p: NSColorPanel) { Store.shared.setTint(path, p.color.hex) }
    }
}

// MARK: - Fullscreen detection

enum Space {
    /// True when a visible window covers the whole screen: a native full-screen space or a borderless full-screen app.
    /// A native full-screen app (its own Space), or a window covering the whole screen (games that skip native full screen).
    static func isFullscreen(_ s: NSScreen) -> Bool {
        if Desktops.inFullscreenSpace(s) { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let h = NSScreen.screens.first?.frame.height else { return false }
        let f = s.frame
        let target = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
        let me = getpid()
        return list.contains { w in
            guard w[kCGWindowLayer as String] as? Int == 0, w[kCGWindowOwnerPID as String] as? pid_t != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: b as! CFDictionary) else { return false }
            return r == target
        }
    }
}

// MARK: - Edge trigger

final class Trigger: NSPanel {
    let screenID: CGDirectDisplayID
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}

    init(_ frame: NSRect, screenID: CGDirectDisplayID) {
        self.screenID = screenID
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = NSColor(white: 0, alpha: 0.004) // fully clear windows don't receive mouse events
        isOpaque = false; hasShadow = false; isReleasedWhenClosed = false
        contentView = TriggerView(self)
    }
}

private final class TriggerView: NSView {
    unowned let t: Trigger
    init(_ t: Trigger) { self.t = t; super.init(frame: .zero); registerForDraggedTypes([.fileURL, .URL, .string]) }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { t.onEnter() }
    override func mouseExited(with e: NSEvent) { t.onExit() }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { t.onEnter(); return [] }
}
