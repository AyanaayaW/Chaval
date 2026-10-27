import AppKit

// MARK: - Model

enum BarSide: String, Codable, CaseIterable { case left, center, right }

enum BarModule: String, Codable, CaseIterable {
    case dashboard, appMenu, frontApp, appIcons, systemIcons, clock, date, battery, cpu, memory, music, text, script, spacer
    case workspaces, volume, wifi, bluetooth, keyboard, brightness
    var name: String {
        switch self {
        case .workspaces: return "Desktops (with their apps)"
        case .wifi: return "Wi-Fi"
        case .keyboard: return "Keyboard layout"
        case .dashboard: return "Dashboard button"
        case .appMenu: return "App menus"
        case .frontApp: return "Active app"
        case .appIcons: return "Background apps (menu bar icons)"
        case .systemIcons: return "Control Center & system icons"
        case .cpu: return "CPU"
        case .music: return "Now Playing"
        case .script: return "Shell command"
        case .volume: return "Sound"
        default: return rawValue.capitalized
        }
    }
}

struct BarItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var module: BarModule
    var icon = ""        // SF Symbol shown before the text (text and shell items)
    var text = ""        // text: the label · script: the command whose output is shown · clock/date: a format like "EEE d MMM HH:mm"
    var click = ""       // text/script: shell command run on click
    var interval = 10.0  // script: seconds between runs
}

struct BarSection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Section"
    var side: BarSide = .right
    var items: [BarItem] = []
    var pill = true      // background behind the section
    var bgHex: String?   // nil = the theme's section colour
    var fgHex: String?   // nil = the theme's text colour
}

struct BarTheme: Codable, Equatable {
    var material: Material = .clear // floating sections over the wallpaper
    var bgHex = "15161BE6"
    var fgHex = "D8DEE9FF"
    var accentHex = "E0A458FF"
    var pillHex = "FFFFFF12"
    var borderHex = "E0A45866"
    var border = true
    var borderWidth = 1.0
    var borderAccent = true // the theme's accent; off: borderHex
    var accentIcons = true  // every icon in the theme's accent (text stays in the text colour)
    var corner = 0.0      // the bar's own corners
    var pillCorner = 6.0
    var inset = 0.0       // gap around the bar, for a floating look
    var fontName = "System Monospaced"
    var fontSize = 12.0
    var spacing = 12.0
    var colorIcons = true // off: app icons are washed in the text colour
}

struct BarConfig: Codable, Equatable {
    var enabled = true
    var theme = BarTheme()
    var sections = [
        BarSection(name: "Menus", side: .left, items: [BarItem(module: .dashboard), BarItem(module: .appMenu)]),
        BarSection(name: "Menu bar", items: [BarItem(module: .keyboard), BarItem(module: .brightness), BarItem(module: .volume),
                                             BarItem(module: .bluetooth), BarItem(module: .wifi), BarItem(module: .battery),
                                             BarItem(module: .appIcons), BarItem(module: .systemIcons)]),
    ]
    var hidden: [String] = [] // MenuExtra keys

    var modules: Set<BarModule> { Set(sections.flatMap { $0.items.map(\.module) }) }
}

// MARK: - Controller

/// A themeable bar drawn over the real menu bar, so windows already stop below it. The real menu bar stays
/// underneath: app menus and every menu bar icon are mirrored via Accessibility and pressing one opens its real menu.
final class TopBar: NSObject {
    private let panel: NSPanel
    private let root = NSView()
    private var bg = NSView()
    /// The wallpaper's top strip, opaque, so the real menu bar never shows through a translucent theme.
    private let backplate = CALayer()
    fileprivate let view = BarView()
    fileprivate private(set) var extras: [MenuExtra] = []
    fileprivate private(set) var menus: [(title: String, el: AXUIElement)] = []
    fileprivate private(set) var scriptOut: [UUID: String] = [:]
    fileprivate private(set) var glyphs: [String: NSImage] = [:] // real icon shapes, by MenuExtra key
    private var monitors: [Any] = []
    private var scripts: [UUID: (spec: String, timer: Timer)] = [:]
    private var clockTimer: Timer?, statsTimer: Timer?, scanTimer: Timer?, deskTimer: Timer?
    private var desks: [[NSRunningApplication]] = [], desk = 0
    private var btConnected = 0
    private var watching = false
    private var scanning = false
    private var last: BarConfig?

    var cfg: BarConfig { Store.shared.bar }
    /// The bar's height on a screen: the menu bar's, or its usual height when the menu bar auto-hides (then macOS reports
    /// none, which is why panels hanging below the bar ask here rather than macOS).
    static func height(_ s: NSScreen) -> CGFloat {
        let h = s.frame.maxY - s.visibleFrame.maxY
        return h >= 1 ? h : max(s.safeAreaInsets.top, NSStatusBar.system.thickness)
    }

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        // Above the menu bar and its icons; the menus those open still appear above this.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // No .fullScreenAuxiliary: full-screen spaces keep the system's own auto-hiding menu bar.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = root
        view.bar = self
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        root.wantsLayer = true
        backplate.contentsGravity = .resize
        root.layer?.addSublayer(backplate)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(frontChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshBackplate), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDesks), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDesks), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshDesks), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshBackplate), name: .chavalWallpaperChanged, object: nil)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(storeChanged), name: .chavalChanged, object: nil)
        nc.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(woke), name: .NSSystemClockDidChange, object: nil)
        // Over a menu bar icon the bar turns click-through, so the real icon gets the user's own click (no AXPress, no pointer tricks).
        let moved: (NSEvent) -> Void = { [weak self] _ in self?.mouseMovedAnywhere() }
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .flagsChanged], handler: moved) as Any,
                    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged]) { moved($0); return $0 } as Any]
        apply()
        _ = fullscreenTimer
    }

    @objc private func storeChanged() { if cfg != last { apply() } }

    private func apply() {
        let old = last
        last = cfg
        guard cfg.enabled else { panel.orderOut(nil); setTimers(); return }
        if old?.theme != cfg.theme || old?.enabled != true { style() }
        reposition()
        setTimers()
        frontChanged()
        if cfg.modules.contains(.appIcons) || cfg.modules.contains(.systemIcons) { MenuBarCapture.requestOnce() }
        scan()
        panel.orderFrontRegardless()
        Desktops.pinAbove(panel)
        redraw()
    }

    func redraw() { view.needsDisplay = true }

    var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    /// The menu bar's strip. When the menu bar auto-hides there is no strip, so use its usual height (windows may then sit under the bar).
    @objc private func reposition() {
        let s = screen, h = TopBar.height(s)
        panel.setFrame(NSRect(x: s.frame.minX, y: s.frame.maxY - h, width: s.frame.width, height: h), display: true)
        root.frame = NSRect(origin: .zero, size: panel.frame.size)
        view.frame = root.bounds
        bg.frame = innerRect
        backplate.frame = root.bounds
        refreshBackplate()
        bg.autoresizingMask = [.width, .height]
        redraw()
    }

    fileprivate var innerRect: NSRect {
        let i = cfg.theme.inset
        return root.bounds.insetBy(dx: i, dy: i > 0 ? min(i / 2, 4) : 0)
    }

    private func style() {
        let t = cfg.theme, tint = NSColor(hex: t.bgHex)
        bg.removeFromSuperview()
        if t.material == .glass, #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.tintColor = tint.alphaComponent > 0 ? tint : nil
            g.cornerRadius = t.corner
            bg = g
        } else if t.material == .blur {
            let v = NSVisualEffectView()
            v.material = .hudWindow; v.blendingMode = .withinWindow // blur the backplate, not the menu bar behind it; v.state = .active
            let over = NSView(frame: v.bounds)
            over.autoresizingMask = [.width, .height]
            over.wantsLayer = true
            over.layer?.backgroundColor = tint.cgColor
            v.addSubview(over)
            bg = v
        } else {
            bg = NSView()
        }
        bg.wantsLayer = true
        if !(bg is GlassLike) {
            if t.material == .solid { bg.layer?.backgroundColor = tint.cgColor }
            bg.layer?.cornerRadius = t.corner
        }
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = t.border && t.material != .clear ? t.borderWidth : 0 // with no bar background the border goes round each section
        bg.layer?.borderColor = NSColor(hex: t.borderAccent ? t.accentHex : t.borderHex).cgColor
        root.addSubview(bg, positioned: .below, relativeTo: view)
        let light = (NSColor(hex: t.fgHex).usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.5
        panel.appearance = NSAppearance(named: light ? .darkAqua : .aqua)
    }

    // MARK: Data

    private func setTimers() {
        let on = cfg.enabled, mods = on ? cfg.modules : []
        let clocks = cfg.sections.flatMap(\.items).filter { $0.module == .clock || $0.module == .date }
        let seconds = clocks.contains { $0.text.contains("s") }
        if !clocks.isEmpty {
            let interval: TimeInterval = seconds ? 1 : 60
            if clockTimer?.timeInterval != interval {
                clockTimer?.invalidate()
                let now = Date().timeIntervalSinceReferenceDate
                let t = Timer(fire: Date(timeIntervalSinceReferenceDate: (now / interval).rounded(.down) * interval + interval),
                              interval: interval, repeats: true) { [weak self] _ in self?.redraw() }
                t.tolerance = seconds ? 0.1 : 1
                RunLoop.main.add(t, forMode: .common)
                clockTimer = t
            }
        } else { clockTimer?.invalidate(); clockTimer = nil }

        if mods.contains(.cpu) || mods.contains(.memory) {
            if statsTimer == nil {
                Widgets.sample()
                statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Widgets.sample(); self?.redraw() }
                statsTimer?.tolerance = 0.5
            }
        } else { statsTimer?.invalidate(); statsTimer = nil }

        if mods.contains(.music) { NowPlaying.shared.start("bar") { [weak self] in self?.redraw() } }
        if !watching && !mods.isDisjoint(with: [.volume, .wifi, .keyboard]) {
            watching = true // event-driven: the volume keys, Wi-Fi changes and layout switches redraw at once
            Audio.watch { [weak self] in self?.redraw() }
            WiFi.shared.onChange = { [weak self] in self?.redraw() }
            InputSources.watch { [weak self] in self?.redraw() }
        }
        // ponytail: desktops' apps and Bluetooth connections are re-read every 2s; neither announces changes we can hear.
        if !mods.isDisjoint(with: [.workspaces, .bluetooth]) {
            if deskTimer == nil {
                refreshDesks()
                deskTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshDesks() }
                deskTimer?.tolerance = 0.5
            }
        } else { deskTimer?.invalidate(); deskTimer = nil }
        if mods.contains(.battery) { Widgets.watchPower("bar") { [weak self] in self?.redraw() } }

        // ponytail: menu bar icons are re-read every 3s; AX sends no notification when an app adds or changes one.
        if mods.contains(.appIcons) || mods.contains(.systemIcons) {
            if scanTimer == nil { scanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() } }
        } else { scanTimer?.invalidate(); scanTimer = nil }

        // Shell items: a timer each, restarted only when its command or interval changes (not on every keystroke elsewhere).
        let items = on ? cfg.sections.flatMap(\.items).filter { $0.module == .script } : []
        for (id, s) in scripts where !items.contains(where: { $0.id == id && "\($0.text)|\($0.interval)" == s.spec }) {
            s.timer.invalidate(); scripts[id] = nil
        }
        for item in items where scripts[item.id] == nil {
            let id = item.id, cmd = item.text
            let run = { [weak self] in
                guard !cmd.isEmpty else { return }
                DispatchQueue.global(qos: .utility).async {
                    let out = Script.shell("/bin/zsh", ["-lc", cmd]).components(separatedBy: .newlines).first ?? ""
                    DispatchQueue.main.async { self?.scriptOut[id] = out; self?.redraw() }
                }
            }
            run()
            scripts[id] = ("\(item.text)|\(item.interval)", Timer.scheduledTimer(withTimeInterval: max(item.interval, 1), repeats: true) { _ in run() })
        }
    }

    /// Re-reads every app's menu bar icons in the background; redraws only if something visible changed.
    private func scan() {
        guard cfg.enabled, !scanning, cfg.modules.contains(.appIcons) || cfg.modules.contains(.systemIcons) else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = MenuExtras.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                let changed = found.map(\.signature) != self.extras.map(\.signature)
                self.extras = found
                if changed { self.redraw() }
                self.capture()
            }
        }
    }

    /// Re-copies the real icons (cheap: one small screenshot of the strip) so the bar can draw them in its colour.
    private func capture() {
        let s = screen, h = panel.frame.height, scale = s.backingScaleFactor
        let shown = extras.filter { $0.onScreen && !$0.identifier.hasSuffix(".clock") }
        guard !shown.isEmpty else { return }
        MenuBarCapture.strip(CGRect(x: s.frame.minX, y: 0, width: s.frame.width, height: h), scale: scale) { [weak self] img in
            guard let img else { return }
            var out: [String: NSImage] = [:]
            for e in shown { out[e.key] = MenuBarCapture.glyph(img, x: e.frame.minX - s.frame.minX, width: e.frame.width, scale: scale) }
            DispatchQueue.main.async { self?.glyphs = out; self?.redraw() }
        }
    }

    private func mouseMovedAnywhere() {
        let p = NSEvent.mouseLocation, f = panel.frame
        // Pushing the pointer to the top centre (the notch) slides the dashboard down.
        if cfg.enabled, p.y >= screen.frame.maxY - 2, abs(p.x - screen.frame.midX) < 160 { Dashboard.shared.hoverOpen() }
        let local = NSPoint(x: p.x - f.minX, y: p.y - f.minY)
        // Hold ⌥ to keep the bar's own menu (right-click → hide) on those icons.
        let over = f.contains(p) && !NSEvent.modifierFlags.contains(.option) ? view.passRects.first { $0.contains(local) } : nil
        if panel.ignoresMouseEvents != (over != nil) { panel.ignoresMouseEvents = over != nil }
        view.passHover(over)
    }

    @objc private func appsChanged() {
        // New apps add their icons a moment after launching.
        for d in [0.5, 2.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.scan() } }
    }

    @objc private func frontChanged() {
        guard cfg.enabled, cfg.modules.contains(.appMenu) || cfg.modules.contains(.frontApp),
              let app = NSWorkspace.shared.frontmostApplication else { return }
        redraw()
        for d in [0.0, 0.6] { // apps fill in their menus late right after launching
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + d) { [weak self] in
                let m = MenuExtras.appMenus(app)
                DispatchQueue.main.async {
                    guard let self, NSWorkspace.shared.frontmostApplication == app else { return }
                    if m.map(\.title) != self.menus.map(\.title) || d == 0 { self.menus = m; self.redraw() }
                }
            }
        }
    }

    /// ponytail: assumes the wallpaper is set to "Fill Screen" and refreshes on space/display changes and wake;
    /// read desktopImageOptions if other scalings matter.
    @objc private func refreshBackplate() {
        let s = screen, strip = panel.frame.size
        guard let url = NSWorkspace.shared.desktopImageURL(for: s) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let img = NSImage(contentsOf: url), img.size.width > 0 else { return }
            let sw = s.frame.width, sh = s.frame.height
            let k = max(sw / img.size.width, sh / img.size.height)
            let w = img.size.width * k, h = img.size.height * k
            let out = NSImage(size: strip, flipped: false) { _ in
                img.draw(in: NSRect(x: (sw - w) / 2, y: (sh - h) / 2 - (sh - strip.height), width: w, height: h))
                return true
            }
            let cg = out.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: s.backingScaleFactor))])
            DispatchQueue.main.async { self?.backplate.contents = cg }
        }
    }

    /// Presses the real icon via Accessibility; never moves the pointer. Re-reads soon after, since the
    /// click usually changes the item's text (Amphetamine's timer) and AX sends no notification for it.
    fileprivate func click(_ e: MenuExtra) {
        MenuExtras.press(e.el)
        for d in [0.4, 1.2, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.scan() } }
    }

    /// Pinned above the desktops, the bar would also cover full-screen apps: step aside for them, as the menu bar does.
    @objc private func spaceChanged() {
        for d in [0.0, 0.5] { // the window list lags the switch
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.checkFullscreen() }
        }
    }

    /// Steps aside while an app covers the whole screen. Also checked every second: games (Minecraft) go full screen a
    /// moment after they're already in front, with no desktop switch to announce it.
    private func checkFullscreen() {
        guard cfg.enabled else { return }
        if Space.isFullscreen(screen) { if panel.isVisible { panel.orderOut(nil) } }
        else if !panel.isVisible { panel.orderFrontRegardless(); Desktops.pinAbove(panel) }
    }
    private lazy var fullscreenTimer: Timer = {
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkFullscreen() }
        t.tolerance = 0.3
        return t
    }()

    @objc private func refreshDesks() {
        let mods = cfg.modules
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = mods.contains(.workspaces) ? Desktops.apps() : [], cur = Desktops.current.index
            let bt = mods.contains(.bluetooth) && Bluetooth.on ? Bluetooth.connectedCount : 0
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = apps.map { $0.map(\.processIdentifier) } != self.desks.map { $0.map(\.processIdentifier) } || cur != self.desk || bt != self.btConnected
                (self.desks, self.desk, self.btConnected) = (apps, cur, bt)
                if changed { self.redraw() }
            }
        }
    }

    @objc private func woke() { refreshBackplate(); clockTimer?.invalidate(); clockTimer = nil; setTimers(); redraw() }

    // MARK: Cells

    fileprivate func cells(_ item: BarItem) -> [Cell] {
        let now = Date()
        switch item.module {
        case .dashboard:
            return [Cell(symbol: "square.grid.2x2.fill", accent: true, tip: "Dashboard", onPress: true) { _ in Dashboard.shared.toggle() }]
        case .appMenu:
            return menus.enumerated().map { i, m in
                var c = Cell(symbol: i == 0 ? "apple.logo" : nil, text: i == 0 ? "" : m.title, bold: i == 1, accent: true, tip: m.title, onPress: true) { r in
                    guard Store.shared.settings.chavalMenus else { return MenuExtras.press(m.el) }
                    if ChavalMenu.shared.openTitle == m.title { ChavalMenu.shared.close() } else { ChavalMenu.shared.open(m.el, title: m.title, anchor: r) }
                }
                c.menu = m.title
                return c
            }
        case .frontApp:
            guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
            return [Cell(image: app.icon, template: false, text: app.localizedName ?? "", bold: true)]
        case .appIcons, .systemIcons:
            let system = item.module == .systemIcons, hidden = Set(cfg.hidden), mods = cfg.modules
            // The bar's own Sound, Wi-Fi, … replace the mirrored macOS ones.
            let own: [(BarModule, [String])] = [(.wifi, ["wifi", "wi-fi"]), (.battery, ["battery"]), (.volume, ["sound"]), (.bluetooth, ["bluetooth"]),
                                                (.keyboard, ["textinput", "keyboard"]), (.brightness, ["display"])]
            let replaced = own.filter { mods.contains($0.0) }.flatMap(\.1)
            return extras.filter { e in
                let id = (e.identifier + " " + e.name).lowercased()
                return e.isSystem == system && !hidden.contains(e.key) && !(system && replaced.contains { id.contains($0) })
            }.map { e in
                var c = Cell(text: e.title, tip: e.name, extra: e, overflows: !e.onScreen) { [weak self] _ in self?.click(e) }
                c.onPress = true
                // Icons on screen sit exactly over the real ones; hovering one lets the click through to it.
                if e.onScreen { c.pin = e.frame }
                // macOS's mic/camera-in-use item: its icon sits on a coloured pill and copies out faint, so it's drawn as a symbol.
                let inUse = e.identifier.hasSuffix(".audiovideo")
                if !inUse, let g = glyphs[e.key] { // its real shape, in the theme colour (includes any text it shows)
                    c.image = g; c.text = ""; c.exact = true
                    return c
                }
                c.accent = !e.identifier.hasSuffix(".clock") // icon text (Amphetamine's "∞", timers) and system symbols in the accent colour
                if e.identifier.hasSuffix(".clock") { return c }
                // AX publishes no usable image for these (Apple's "AXImageData" is a blank strip), so draw symbols.
                if e.identifier.hasSuffix(".battery") { c.symbol = Self.batterySymbol() }
                else if system { c.symbol = MenuExtras.symbol(for: e) }
                else { c.image = NSRunningApplication(processIdentifier: e.pid)?.icon; c.template = false; c.appIcon = true }
                return c
            }
        case .clock, .date:
            let f = DateFormatter()
            if !item.text.isEmpty { f.dateFormat = item.text }
            else { f.setLocalizedDateFormatFromTemplate(item.module == .clock ? "EEEdMMMjmm" : "EEEEdMMMM") }
            return [Cell(text: f.string(from: now), tip: now.formatted(date: .complete, time: .shortened), onPress: true) { _ in Dashboard.shared.toggle() }]
        case .battery:
            let b = Widgets.battery()
            guard b.present else { return [] }
            var c = Cell(symbol: Self.batterySymbol(), text: "\(b.level)%", accent: b.level <= 20 && !b.plugged, tip: "Battery \(b.level)%") { r in
                BarPopout.shared.toggle(.battery, anchor: r)
            }
            c.popout = .battery
            return [c]
        case .workspaces:
            let inUse = Store.shared.settings.desktopsInUse
            return desks.enumerated().filter { !inUse || $0.offset == desk || !$0.element.isEmpty }.map { i, apps in
                let img = workspaceImage(i + 1, apps: apps, current: i == desk)
                var c = Cell(image: img, template: false, tip: apps.isEmpty ? "Desktop \(i + 1)" : "Desktop \(i + 1): " + apps.compactMap(\.localizedName).joined(separator: ", "),
                             onPress: true) { _ in HotKeys.Action(rawValue: "desktop\(i + 1)")?.run() }
                c.size = img.size
                c.scroll = { d in HotKeys.Action(rawValue: d < 0 ? "desktopNext" : "desktopPrevious")?.run() }
                c.steps = true
                return c
            }
        case .volume:
            let v = Audio.volume() ?? 0
            var c = Cell(symbol: Audio.symbol, text: Audio.muted() ? "muted" : "\(Int((v * 100).rounded()))%", tip: "Sound") { _ in Audio.setMuted(!Audio.muted()) }
            c.popout = .volume
            c.scroll = { d in Audio.setVolume((Audio.volume() ?? 0) + d) }
            return [c]
        case .brightness:
            guard let b = System.brightness() else { return [] } // external displays without software brightness
            var c = Cell(symbol: "sun.max.fill", text: "\(Int((b * 100).rounded()))%", tip: "Brightness")
            c.popout = .brightness
            c.scroll = { [weak self] d in System.setBrightness(min(max((System.brightness() ?? 0) + d, 0), 1)); self?.redraw() }
            return [c]
        case .wifi:
            let w = WiFi.shared
            var c = Cell(symbol: w.bar.symbol, tip: w.bar.tip) { r in BarPopout.shared.toggle(.wifi, anchor: r) }
            c.popout = .wifi
            return [c]
        case .bluetooth:
            var c = Cell(symbol: Bluetooth.on ? "dot.radiowaves.left.and.right" : "dot.radiowaves.right", text: btConnected > 0 ? "\(btConnected)" : "",
                         tip: Bluetooth.on ? "Bluetooth" : "Bluetooth off") { r in BarPopout.shared.toggle(.bluetooth, anchor: r) }
            c.popout = .bluetooth
            return [c]
        case .keyboard:
            let all = InputSources.enabled
            guard all.count > 1 else { return [] } // one layout: nothing to show or switch
            let cur = InputSources.current
            var c = Cell(symbol: "keyboard", text: cur.short, tip: cur.name) { _ in
                if let i = all.firstIndex(where: { $0.id == cur.id }) { InputSources.select(all[(i + 1) % all.count]) }
            }
            c.popout = .keyboard
            return [c]
        case .cpu, .memory:
            let kind: WidgetKind = item.module == .cpu ? .cpu : .memory
            let v = Widgets.latest[kind] ?? 0
            return [Cell(symbol: kind == .cpu ? "cpu" : "memorychip", text: "\(Int((v * 100).rounded()))%", accent: v > 0.85, tip: kind.name) { _ in
                Widgets.open(kind)
            }]
        case .music:
            let t = NowPlaying.shared.track
            let title = t.map { $0.artist.isEmpty ? $0.title : "\($0.title) — \($0.artist)" } ?? ""
            return [Cell(symbol: t == nil ? "music.note" : t!.playing ? "pause.fill" : "play.fill",
                         text: title.count > 40 ? String(title.prefix(39)) + "…" : title, tip: title.isEmpty ? "Not Playing" : title) { _ in
                NowPlaying.shared.track == nil ? NowPlaying.shared.openPlayer() : NowPlaying.shared.send("playpause")
            }]
        case .text, .script:
            let shown = item.module == .text ? item.text : scriptOut[item.id] ?? ""
            let cmd = item.click
            return [Cell(symbol: item.icon.isEmpty ? nil : item.icon, text: shown, tip: shown) { _ in
                guard !cmd.isEmpty else { return }
                DispatchQueue.global(qos: .userInitiated).async { Script.shell("/bin/zsh", ["-lc", cmd]) }
            }]
        case .spacer:
            return [Cell(gap: cfg.theme.spacing * 2)]
        }
    }

    func snapshot(to path: String) {
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        if let cg = backplate.contents {
            try? NSBitmapImageRep(cgImage: cg as! CGImage).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".plate.png"))
        }
    }

    /// A desktop's number and the icons of the apps with windows on it; the current one sits on an accent pill.
    private func workspaceImage(_ n: Int, apps: [NSRunningApplication], current: Bool) -> NSImage {
        let t = cfg.theme, h = ceil(t.fontSize + 8), icon = h - 6
        let font = Fonts.font(t.fontSize, .bold, family: t.fontName)
        let fg = NSColor(hex: t.fgHex), accent = NSColor(hex: t.accentHex)
        let label = NSAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: current ? NSColor(hex: t.bgHex).withAlphaComponent(1) : apps.isEmpty ? fg.withAlphaComponent(0.4) : fg])
        let shown = Array(apps.prefix(4))
        let pad: CGFloat = 7, numW = max(label.size().width, 7)
        let w = ceil(pad + numW + (shown.isEmpty ? 0 : 5 + CGFloat(shown.count) * (icon + 2) - 2) + pad)
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
            if current {
                accent.setFill()
                NSBezierPath(roundedRect: r, xRadius: h * CGFloat(Store.shared.settings.deskCorner), yRadius: h * CGFloat(Store.shared.settings.deskCorner)).fill()
            } else if !apps.isEmpty {
                fg.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: r, xRadius: h * CGFloat(Store.shared.settings.deskCorner), yRadius: h * CGFloat(Store.shared.settings.deskCorner)).fill()
            }
            let z = label.size()
            label.draw(at: NSPoint(x: pad + (numW - z.width) / 2, y: (h - z.height) / 2))
            var x = pad + numW + 5
            for a in shown {
                a.icon?.draw(in: NSRect(x: x, y: (h - icon) / 2, width: icon, height: icon))
                x += icon + 2
            }
            return true
        }
    }

    private static func batterySymbol() -> String {
        let b = Widgets.battery()
        if b.plugged { return "battery.100percent.bolt" }
        return "battery.\([0, 25, 50, 75, 100].min { abs($0 - b.level) < abs($1 - b.level) } ?? 100)percent"
    }

    // MARK: Context menu

    fileprivate func menu(for cell: Cell?) -> NSMenu {
        let m = NSMenu()
        if let e = cell?.extra {
            m.addItem(Menu.item("Hide “\(e.name)” from the bar") { Store.shared.bar.hidden.append(e.key) })
            m.addItem(.separator())
        }
        m.addItem(Menu.sub("Theme", Palette.families.map { f in
            Menu.sub(f, Palette.all.filter { $0.family == f }.map { p in Menu.item(p.name, checked: Themes.current == p.name) { Themes.apply(p) } })
        }))
        m.addItem(Menu.item("Top Bar Settings…") { SettingsWindow.show(tab: .topBar) })
        m.addItem(.separator())
        m.addItem(Menu.item("Hide Top Bar") { Store.shared.bar.enabled = false })
        return m
    }

    fileprivate func overflowMenu(_ cells: [Cell]) -> NSMenu {
        let m = NSMenu()
        for c in cells {
            guard let e = c.extra else { continue }
            let mi = Menu.item(e.title.isEmpty || e.title == e.name ? e.name : "\(e.name)  \(e.title)") { [weak self] in self?.click(e) }
            if let img = c.image?.copy() as? NSImage { img.size = NSSize(width: 16, height: 16 * img.size.height / max(img.size.width, 1)); mi.image = img }
            m.addItem(mi)
        }
        return m
    }
}

// MARK: - View

fileprivate struct Cell {
    var image: NSImage?
    var symbol: String?
    var template = true      // draw the image in the text colour
    var appIcon = false
    var text = ""
    var bold = false
    var accent = false
    var tip = ""
    var extra: MenuExtra?
    var overflows = false    // may move into the » menu when the bar runs out of room
    var gap: CGFloat = 0     // spacer
    var onPress = false      // act on mouse-down, like the real menu bar
    var pin: CGRect?         // menu bar icon: drawn at its real spot (global, top-left origin) instead of flowing
    var exact = false        // image is a copy of the real icon: draw it at its real size over the whole strip
    var size: NSSize?        // draw the image at exactly this size
    var menu: String?        // an app menu's title: with one of Chaval's menus open, hovering here switches to it
    var popout: BarPopout.Kind? // hovering opens this popout
    var scroll: ((Double) -> Void)? // scrolled over: called with a step, positive for up
    var steps = false        // scroll fires once per notch/flick (desktops) instead of continuously (volume)
    var action: ((NSRect) -> Void)?

    init(image: NSImage? = nil, symbol: String? = nil, template: Bool = true, text: String = "", bold: Bool = false, accent: Bool = false,
         tip: String = "", extra: MenuExtra? = nil, overflows: Bool = false, gap: CGFloat = 0, onPress: Bool = false, action: ((NSRect) -> Void)? = nil) {
        (self.image, self.symbol, self.template, self.text, self.bold, self.accent, self.tip, self.extra, self.overflows, self.gap, self.onPress, self.action) =
            (image, symbol, template, text, bold, accent, tip, extra, overflows, gap, onPress, action)
    }
}

fileprivate final class BarView: NSView {
    weak var bar: TopBar?
    private var hits: [(rect: NSRect, cell: Cell)] = []
    private var hover: NSRect?
    private(set) var passRects: [NSRect] = [] // pinned menu bar icons: the real ones take clicks there

    func passHover(_ r: NSRect?) {
        guard r != nil || passRects.contains(where: { $0 == hover }) else { return }
        if r != hover { hover = r; needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private var popWork: DispatchWorkItem?

    override func mouseMoved(with e: NSEvent) {
        let h = hit(e), r = h?.rect
        // A menu is open: sliding along the bar moves it to the menu under the pointer, as the real menu bar does.
        if let h, let title = h.cell.menu, ChavalMenu.shared.isOpen, ChavalMenu.shared.openTitle != title { fire(h) }
        if r != hover {
            hover = r; needsDisplay = true
            // Hovering a status item opens its popout after a beat (at once when another is already open), so sweeping across the bar doesn't.
            popWork?.cancel(); popWork = nil
            if let h, let k = h.cell.popout {
                let screen = window?.convertToScreen(convert(h.rect, to: nil)) ?? h.rect
                let w = DispatchWorkItem { BarPopout.shared.show(k, anchor: screen) }
                popWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + (BarPopout.shared.isOpen ? 0 : 0.18), execute: w)
            }
        }
        toolTip = h?.cell.popout == nil ? h?.cell.tip : nil
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true; popWork?.cancel(); popWork = nil }

    private var scrollAccum: CGFloat = 0, scrollQuietUntil = Date.distantPast

    /// Over a desktop: one switch per flick. Over Sound or brightness: changes as you scroll. Elsewhere on the bar:
    /// brightness on the left half, volume on the right (as Caelestia does).
    override func scrollWheel(with e: NSEvent) {
        let raw = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        let d = e.isDirectionInvertedFromDevice ? -raw : raw // up means up, whatever the scroll direction setting
        guard d != 0 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let c = hit(e)?.cell
        if let c, c.steps, let f = c.scroll {
            if e.phase == .began || e.momentumPhase == .began { scrollAccum = 0 }
            guard Date() > scrollQuietUntil else { return }
            scrollAccum += d
            if abs(scrollAccum) >= 12 {
                f(Double(scrollAccum))
                scrollAccum = 0
                scrollQuietUntil = Date().addingTimeInterval(0.35) // the rest of this flick (and its momentum) is spent
            }
            return
        }
        let step = Double(d) * 0.004
        if let f = c?.scroll { f(step) }
        else if p.x < bounds.midX { if let b = System.brightness() { System.setBrightness(min(max(b + step, 0), 1)) } }
        else { Audio.setVolume((Audio.volume() ?? 0) + step) }
        needsDisplay = true
    }

    private func hit(_ e: NSEvent) -> (rect: NSRect, cell: Cell)? {
        let p = convert(e.locationInWindow, from: nil)
        return hits.first { $0.rect.contains(p) }
    }

    override func mouseDown(with e: NSEvent) { popWork?.cancel(); if let h = hit(e), h.cell.onPress { fire(h) } }
    override func mouseUp(with e: NSEvent) { if let h = hit(e), !h.cell.onPress { fire(h) } }

    private func fire(_ h: (rect: NSRect, cell: Cell)) {
        h.cell.action?(window?.convertToScreen(convert(h.rect, to: nil)) ?? h.rect)
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let bar else { return }
        bar.menu(for: hit(e)?.cell).popUp(positioning: nil, at: convert(e.locationInWindow, from: nil), in: self)
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        hits = []
        guard let bar else { return }
        let cfg = bar.cfg, t = cfg.theme, inner = bar.innerRect
        let fg = NSColor(hex: t.fgHex), accent = NSColor(hex: t.accentHex)
        let regular = Fonts.font(t.fontSize, .regular, family: t.fontName), bold = Fonts.font(t.fontSize, .bold, family: t.fontName)
        let iconH = min(inner.height - 10, t.fontSize + 6)
        // No bar background ("None"): the sections are the bar, so they get its full height, colour and border.
        let floating = t.material == .clear
        let pillH = floating ? inner.height - 6 : min(inner.height - 6, t.fontSize + 14)
        func background(_ r: NSRect, _ s: BarSection) {
            let path = NSBezierPath(roundedRect: r, xRadius: t.pillCorner, yRadius: t.pillCorner)
            NSColor(hex: s.bgHex ?? (floating ? t.bgHex : t.pillHex)).setFill(); path.fill()
            if floating && t.border {
                NSColor(hex: t.borderAccent ? t.accentHex : t.borderHex).setStroke()
                let inner = NSBezierPath(roundedRect: r.insetBy(dx: t.borderWidth / 2, dy: t.borderWidth / 2), xRadius: max(0, t.pillCorner - t.borderWidth / 2), yRadius: max(0, t.pillCorner - t.borderWidth / 2))
                inner.lineWidth = t.borderWidth; inner.stroke() // inside the section, so a thick border isn't clipped
            }
        }

        func icon(_ c: Cell) -> NSImage? {
            if let s = c.symbol {
                return NSImage(systemSymbolName: s, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: t.fontSize + 1, weight: .medium))
            }
            return c.image
        }
        func iconSize(_ c: Cell, _ img: NSImage) -> NSSize {
            if let s = c.size { return s }
            if c.symbol != nil { return img.size }
            let h = c.appIcon ? iconH + 2 : iconH * 0.85
            return NSSize(width: h * img.size.width / max(img.size.height, 1), height: h)
        }
        func label(_ c: Cell, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: c.text, attributes: [.font: c.bold ? bold : regular, .foregroundColor: c.accent ? accent : color])
        }
        func width(_ c: Cell) -> CGFloat {
            if c.gap > 0 { return c.gap }
            var w: CGFloat = 0
            if let img = icon(c) { w += iconSize(c, img).width }
            if !c.text.isEmpty { w += (w > 0 ? 5 : 0) + label(c, fg).size().width }
            return ceil(w)
        }

        // Each section's cells, measured.
        struct Group { var section: BarSection; var cells: [Cell]; var widths: [CGFloat]
            func total(_ spacing: CGFloat) -> CGFloat {
                widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0)) + (section.pill ? 20 : 0)
            }
        }
        func group(_ s: BarSection) -> Group {
            let cells = s.items.flatMap { bar.cells($0) }
            return Group(section: s, cells: cells, widths: cells.map(width))
        }
        let left = cfg.sections.filter { $0.side == .left }.map(group).filter { !$0.cells.isEmpty }
        var center = cfg.sections.filter { $0.side == .center }.map(group).filter { !$0.cells.isEmpty }
        var right = cfg.sections.filter { $0.side == .right }.map(group).filter { !$0.cells.isEmpty }
        let gapBetween: CGFloat = 8, edge: CGFloat = 10

        // Room on each side of the notch, if there is one.
        let s = bar.screen, ox = window?.frame.minX ?? s.frame.minX
        let notchL = s.auxiliaryTopLeftArea.map { $0.maxX - ox }, notchR = s.auxiliaryTopRightArea.map { $0.minX - ox }
        let leftEnd = (notchL ?? inner.maxX) - edge
        if notchR != nil { right = center + right; center = [] } // no middle on a notched screen: centre sections sit just right of it
        let rightStart = (notchR ?? inner.minX) + edge

        func span(_ gs: [Group]) -> CGFloat { gs.map { $0.total(t.spacing) }.reduce(0, +) + gapBetween * CGFloat(max(gs.count - 1, 0)) }
        let centerW = span(center)

        // Menu bar icons are pinned to their real spots (global top-left → view coordinates).
        let H = window?.frame.height ?? bounds.height
        func local(_ g: CGRect) -> NSRect { NSRect(x: g.minX - ox, y: H - g.maxY, width: g.width, height: g.height) }
        var pass: [NSRect] = []

        // Icons the notch hides have no real spot: they go in a » menu at the front of their section.
        for g in right.indices where right[g].cells.contains(where: { $0.overflows }) {
            let items = right[g].cells.filter { $0.overflows }
            right[g].cells.removeAll { $0.overflows }
            var more = Cell(symbol: "chevron.left.2", tip: "More menu bar icons", onPress: true)
            more.action = { [weak self, weak bar] r in
                guard let self, let bar else { return }
                let p = self.convert(self.window!.convertFromScreen(r), from: nil)
                bar.overflowMenu(items).popUp(positioning: nil, at: NSPoint(x: p.minX, y: p.minY - 4), in: self)
            }
            right[g].cells.insert(more, at: 0)
        }
        right = right.map { Group(section: $0.section, cells: $0.cells, widths: $0.cells.map(width)) }.filter { !$0.cells.isEmpty }

        /// A section holding pinned icons: its other items line up just left of them; the background spans both.
        func drawPinned(_ g: Group) -> CGFloat {
            let color = g.section.fgHex.map(NSColor.init(hex:)) ?? fg
            let pins = g.cells.compactMap { $0.pin.map(local) }
            let flow = zip(g.cells, g.widths).filter { $0.0.pin == nil }
            let flowW = flow.map { $0.1 + t.spacing }.reduce(0, +)
            let pad: CGFloat = g.section.pill ? 6 : 0
            let minX = pins.map(\.minX).min()! - flowW - pad, maxX = pins.map(\.maxX).max()! + pad
            let pill = NSRect(x: minX, y: inner.midY - pillH / 2, width: maxX - minX, height: pillH)
            if g.section.pill { background(pill, g.section) }
            var cx = minX + pad + t.spacing / 2
            for (c, w) in flow { cell(c, in: NSRect(x: cx - t.spacing / 2, y: pill.minY, width: w + t.spacing, height: pill.height), color); cx += w + t.spacing }
            for c in g.cells { if let p = c.pin.map(local) {
                let r = NSRect(x: p.minX, y: pill.minY, width: p.width, height: pill.height)
                pass.append(NSRect(x: p.minX, y: bounds.minY, width: p.width, height: bounds.height))
                cell(c, in: r, color)
            } }
            return minX
        }

        /// One item: hover highlight, hit area, icon then text, centred in `r`.
        func cell(_ c: Cell, in r: NSRect, _ color: NSColor) {
            if c.action != nil || c.pin != nil || c.popout != nil || c.scroll != nil {
                if let hover, abs(hover.midX - r.midX) < 0.5 {
                    color.withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: t.pillCorner, yRadius: t.pillCorner).fill()
                }
                if c.action != nil || c.popout != nil || c.scroll != nil { hits.append((r, c)) }
            }
            if c.exact, let img = c.image {
                paint(img, in: NSRect(x: r.minX, y: bounds.minY, width: r.width, height: bounds.height), tint: c.accent || t.accentIcons ? accent : color, wash: nil)
                return
            }
            var ix = r.midX - width(c) / 2
            if let img = icon(c) {
                let z = iconSize(c, img)
                paint(img, in: NSRect(x: ix.rounded(), y: (inner.midY - z.height / 2).rounded(), width: z.width, height: z.height),
                      tint: c.template || img.isTemplate ? (c.accent || t.accentIcons ? accent : color) : nil, wash: c.appIcon && !t.colorIcons ? color : nil)
                ix += z.width + 5
            }
            if !c.text.isEmpty {
                let a = label(c, color), z = a.size()
                a.draw(at: NSPoint(x: ix.rounded(), y: (inner.midY - z.height / 2).rounded()))
            }
        }

        func draw(_ g: Group, at x: CGFloat, limit: CGFloat) {
            let total = g.total(t.spacing)
            let color = g.section.fgHex.map(NSColor.init(hex:)) ?? fg
            let pill = NSRect(x: x, y: inner.midY - pillH / 2, width: min(total, max(limit - x, 0)), height: pillH)
            if g.section.pill { background(pill, g.section) }
            var cx = x + (g.section.pill ? 10 : 0)
            for (c, w) in zip(g.cells, g.widths) {
                guard cx + w <= limit else { break } // out of room (the notch): clip, as the real menu bar does
                cell(c, in: NSRect(x: cx - t.spacing / 2, y: pill.minY, width: w + t.spacing, height: pill.height), color)
                cx += w + t.spacing
            }
        }

        var x = inner.minX + edge
        for g in left { draw(g, at: x, limit: leftEnd); x += g.total(t.spacing) + gapBetween }
        if !center.isEmpty {
            x = inner.midX - centerW / 2
            for g in center { draw(g, at: x, limit: inner.maxX); x += g.total(t.spacing) + gapBetween }
        }
        // Right side: sections with pinned icons where macOS has them; the rest line up to their left.
        let pinned = right.filter { $0.cells.contains { $0.pin != nil } }, free = right.filter { !$0.cells.contains { $0.pin != nil } }
        let freeEnd = pinned.map(drawPinned).min() ?? inner.maxX - edge + gapBetween
        x = freeEnd - gapBetween - span(free)
        for g in free { draw(g, at: x, limit: freeEnd); x += g.total(t.spacing) + gapBetween }
        passRects = pass
    }

    /// Template images take the text colour; app icons optionally get washed in it (keeping their shading).
    private func paint(_ img: NSImage, in r: NSRect, tint: NSColor?, wash: NSColor?) {
        guard tint != nil || wash != nil else { img.draw(in: r); return }
        NSImage(size: r.size, flipped: false) { b in
            img.draw(in: b)
            if let tint { tint.set(); b.fill(using: .sourceAtop) }
            if let wash {
                wash.set(); b.fill(using: .color)
                img.draw(in: b, from: .zero, operation: .destinationIn, fraction: 1)
            }
            return true
        }.draw(in: r)
    }
}
