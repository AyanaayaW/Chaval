import SwiftUI
import IOKit.pwr_mgt

/// The panel that slides down from the top centre of the screen: a Control Center page (clock, calendar, now playing,
/// volume, brightness, appearance, keep-awake, stats, power) and a Themes page. Styled from the bar's theme.
final class Dashboard {
    static let shared = Dashboard()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var leaveWork: DispatchWorkItem?
    private var entered = false // opened from elsewhere (a menu, a key), it waits for the pointer to come over before leaving counts
    private let model = DashModel()
    static let size = NSSize(width: 880, height: 450)

    var isOpen: Bool { panel?.isVisible == true }
    func owns(_ w: NSWindow?) -> Bool { w != nil && w === panel }

    func toggle() { isOpen ? close() : open() }

    /// Opened by pushing the pointer to the top centre. However it was opened, it closes once the pointer wanders off.
    func hoverOpen() { if !isOpen { open() } }

    private var screen: NSRect { NSScreen.screens.first?.frame ?? .zero }

    func open(page: DashModel.Page) {
        model.page = page
        if !isOpen { open() }
    }

    var panelFrame: NSRect? { panel?.frame }

    func open() {
        let p = panel ?? makePanel()
        panel = p
        model.start()
        entered = false
        // Hangs 8 pt below Chaval's bar (or the menu bar, without it), its rounded top corners clear of both.
        let visibleTop = NSScreen.screens.first?.visibleFrame.maxY ?? screen.maxY
        let size = Dashboard.size, top = min(visibleTop, Store.shared.bar.enabled ? screen.maxY - TopBar.height(NSScreen.screens[0]) : visibleTop)
        let target = NSRect(x: screen.midX - size.width / 2, y: top - size.height - 8, width: size.width, height: size.height)
        // Starts tucked behind the bar (it sits one level below it) and slides down out of it.
        let reduce = Store.shared.reduceMotion
        p.setFrame(reduce ? target : target.offsetBy(dx: 0, dy: size.height + 6), display: false)
        p.alphaValue = reduce ? 0 : 1
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = reduce ? 0.15 : 0.34
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // fast out, gentle settle
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() } as Any,
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53 { self?.close(); return nil }
                return e
            } as Any,
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.pointerMoved() } as Any,
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.pointerMoved(); return e } as Any,
        ]
    }

    private func pointerMoved() {
        guard let p = panel, NSApp.modalWindow == nil else { return } // a file picker or alert from a page keeps it open
        let m = NSEvent.mouseLocation
        let near = p.frame.insetBy(dx: -40, dy: -40).contains(m) || (m.y > p.frame.maxY && abs(m.x - p.frame.midX) < p.frame.width / 2)
            || NSApp.windows.contains { $0 !== p && $0.isVisible && $0.level.rawValue > NSWindow.Level.normal.rawValue && $0.frame.contains(m) && $0.frame.height < 600 } // its menus and popovers
        if near { entered = true; leaveWork?.cancel(); leaveWork = nil; return }
        guard entered, leaveWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.close() }
        leaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func close() {
        guard let p = panel, p.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        leaveWork?.cancel(); leaveWork = nil
        model.stop()
        let reduce = Store.shared.reduceMotion
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = reduce ? 0.12 : 0.24
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0) // accelerate back up under the bar
            if reduce { p.animator().alphaValue = 0 } else { p.animator().setFrame(p.frame.offsetBy(dx: 0, dy: p.frame.height + 6), display: true) }
        }, completionHandler: { p.orderOut(nil) })
    }

    /// Diagnostic for `--render-bar`: draws both pages into PNGs.
    func snapshot(to path: String) {
        open()
        func shot(_ suffix: String) {
            guard let v = panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + suffix))
        }
        for (i, page) in DashModel.Page.allCases.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(i) * 0.7) { [self] in model.page = page }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(i) * 0.7) { shot(".\(i).png") }
        }
    }

    /// Diagnostic for `--render-dash`: draws one page into a PNG without putting anything on screen.
    func render(page: String, tab: String, to path: String) {
        model.page = DashModel.Page(rawValue: page) ?? .settings
        if let t = ["dock": SettingsWindow.Tab.dock, "keys": .keys, "tiling": .tiling, "topbar": .topBar][tab] { SettingsWindow.nav.tab = t }
        let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: -5000), size: Dashboard.size), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: DashView(model: model, close: {}).environmentObject(Store.shared))
        w.contentView!.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let v = w.contentView!
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func makePanel() -> NSPanel {
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: Dashboard.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar // just under the bar (statusBar + 1), so it slides out from behind it
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: DashView(model: model, close: { [weak self] in self?.close() }).environmentObject(Store.shared))
        // Rounded at the window level: a SwiftUI clip alone came out square in the live panel on macOS 27.
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        p.invalidateShadow() // the shadow follows the rounded shape
        return p
    }

    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } } // for Esc
}

// MARK: - Model

final class DashModel: ObservableObject {
    @Published var now = Date()
    @Published var volume: Double = 0
    @Published var brightness: Double?
    @Published var dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    @Published var awake = KeepAwake.on
    @Published var track: NowPlaying.Track?
    @Published var page = Page.control
    @Published var palette = Themes.current
    enum Page: String, CaseIterable {
        case control = "Control Center", music = "Now Playing", system = "System", wallpapers = "Wallpapers"
        case launcher = "Quick Launch", notes = "Notes", custom = "Custom Manager", themes = "Themes", shortcuts = "Shortcuts", settings = "Settings"
        var symbol: String {
            ["switch.2", "music.note", "cpu", "photo.on.rectangle.angled", "square.grid.3x3.fill", "note.text",
             "wrench.and.screwdriver.fill", "paintpalette.fill", "keyboard", "gearshape.fill"][Self.allCases.firstIndex(of: self)!]
        }
    }
    private var timer: Timer?

    func start() {
        _ = awakeWatch
        awake = KeepAwake.on
        now = Date()
        volume = System.volume() ?? volume
        brightness = System.brightness()
        dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        track = NowPlaying.shared.track
        NowPlaying.shared.start("dash") { [weak self] in self?.track = NowPlaying.shared.track }
        Widgets.sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            self?.now = Date()
            if Int(Date().timeIntervalSince1970) % 2 == 0 { Widgets.sample() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func setVolume(_ v: Double) { volume = v; System.setVolume(v) }
    func setBrightness(_ v: Double) { brightness = v; System.setBrightness(v) }

    func setDark(_ on: Bool) {
        dark = on
        DispatchQueue.global(qos: .userInitiated).async {
            Script.run("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
        }
    }

    func setAwake(_ on: Bool, minutes: Int? = nil) { KeepAwake.set(on, minutes: minutes); awake = KeepAwake.on }
    private lazy var awakeWatch: Any = NotificationCenter.default.addObserver(forName: KeepAwake.changed, object: nil, queue: .main) { [weak self] _ in
        self?.awake = KeepAwake.on // a timed session ending, the battery floor
    }
}

/// Volume, brightness and power. Brightness goes through the private DisplayServices call the brightness keys use.
enum System {
    static func volume() -> Double? { Script.run("output volume of (get volume settings)").map { Double($0.int32Value) / 100 } }
    static func setVolume(_ v: Double) {
        DispatchQueue.global(qos: .userInitiated).async { Script.run("set volume output volume \(Int(v * 100))") }
    }

    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private typealias GetB = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetB = @convention(c) (UInt32, Float) -> Int32
    private static let getB = dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetB.self) }
    private static let setB = dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetB.self) }

    /// nil when the main display has no software brightness (most external monitors).
    static func brightness() -> Double? {
        var b: Float = 0
        guard let getB, getB(CGMainDisplayID(), &b) == 0 else { return nil }
        return Double(b)
    }
    static func setBrightness(_ v: Double) { _ = setB?(CGMainDisplayID(), Float(v)) }

    static func lock() {
        let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
        if let f = dlsym(login, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            _ = unsafeBitCast(f, to: Lock.self)()
        } else {
            Script.shell("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    static func sleep() { DispatchQueue.global().async { Script.shell("/usr/bin/pmset", ["sleepnow"]) } }

    /// Restart, shut down and log out ask first: they close every app.
    static func confirm(_ what: String, _ verb: String) {
        let a = NSAlert()
        a.messageText = "\(what) now?"
        a.informativeText = "Apps with unsaved changes may ask you to save first."
        a.addButton(withTitle: what); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async { Script.run("tell application \"System Events\" to \(verb)") }
    }
}

// MARK: - View

private struct DashView: View {
    @ObservedObject var model: DashModel
    @EnvironmentObject var store: Store
    let close: () -> Void
    @Namespace private var pill
    @State private var forward = true // moving down the list: the new page rises from below

    private var t: BarTheme { store.bar.theme }
    private var fg: Color { Color(nsColor: NSColor(hex: t.fgHex)) }
    private var accent: Color { Color(nsColor: NSColor(hex: t.accentHex)) }
    private var tile: Color { Color(nsColor: NSColor(hex: t.pillHex)) }
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font { Font(Fonts.font(size, weight, family: t.fontName)) }
    private var style: DashStyle { DashStyle(t: t) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack(alignment: .topLeading) {
                Group {
                    switch model.page {
                    case .control: control
                    case .music: MusicPage(s: style, dash: model)
                    case .system: SystemPage(s: style)
                    case .wallpapers: WallpaperPage(s: style)
                    case .launcher: LauncherPage(s: style, close: close)
                    case .notes: NotesPage(s: style)
                    case .custom: CustomPage(s: style)
                    case .themes: themes
                    case .shortcuts: ShortcutsPage(s: style)
                    case .settings: SettingsView().environmentObject(SettingsWindow.nav)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(model.page)
                .transition(.asymmetric(insertion: .move(edge: forward ? .bottom : .top).combined(with: .opacity),
                                        removal: .move(edge: forward ? .top : .bottom).combined(with: .opacity)))
            }
            .clipped()
        }
        .foregroundStyle(fg)
        // Solid (a see-through panel let the window behind show through every card), with a faint neutral edge.
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(1))))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(fg.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CHAVAL").font(font(10, .bold)).opacity(0.45).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(DashModel.Page.allCases, id: \.self) { page in
                let on = model.page == page
                Button { go(page) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.symbol).frame(width: 16)
                        Text(page.rawValue).font(font(12, on ? .semibold : .regular)).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background {
                        if on { RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.9)).matchedGeometryEffect(id: "pill", in: pill) }
                    }
                    .foregroundStyle(on ? Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(1)) : fg)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            power
        }
        .padding(12).frame(width: 196).frame(maxHeight: .infinity)
        .background(tile.opacity(0.6))
    }

    /// The highlight slides to the new item and the pages slide vertically, in the list's direction.
    private func go(_ page: DashModel.Page) {
        guard page != model.page else { return }
        let all = DashModel.Page.allCases
        forward = all.firstIndex(of: page)! > all.firstIndex(of: model.page)!
        if Store.shared.reduceMotion { model.page = page; return }
        // Next turn, so the outgoing page has re-rendered with the new direction before it leaves.
        DispatchQueue.main.async { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { model.page = page } }
    }

    /// A big centred clock across the top; under it weather, the month, and the player with sound and the two toggles.
    /// What has a page of its own (system stats, settings) isn't repeated here; music is.
    private var control: some View {
        VStack(spacing: 10) {
            clock
            HStack(alignment: .top, spacing: 10) {
                WeatherCard(s: style).frame(maxHeight: .infinity)
                calendar
                VStack(spacing: 10) { music; sliders; toggles }.frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Themes

    private var themes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Applies to the top bar, this panel, the dock, window borders, Ghostty and tmux.").font(font(11)).opacity(0.6)
                ForEach(Palette.families, id: \.self) { family in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(family.uppercased()).font(font(10, .bold)).opacity(0.5)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(Palette.all.filter { $0.family == family }) { themeCard($0) }
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func themeCard(_ p: Palette) -> some View {
        let on = model.palette == p.name
        return Button { model.palette = p.name; Themes.apply(p) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p.name.replacingOccurrences(of: p.family + " ", with: "")).font(font(11, .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)) }
                }
                .foregroundStyle(Color(nsColor: NSColor(hex: p.fg)))
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: NSColor(hex: p.accent))).frame(width: 22, height: 8)
                    ForEach(Array(p.swatches.enumerated()), id: \.offset) { Circle().fill(Color(nsColor: NSColor(hex: $0.element))).frame(width: 8, height: 8) }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: NSColor(hex: p.bg))))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? accent : fg.opacity(0.12), lineWidth: on ? 2 : 1))
        }.buttonStyle(.plain)
    }

    private func card<C: View>(fill: Bool = false, @ViewBuilder _ c: () -> C) -> some View {
        c().padding(10).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(tile))
    }

    private var clock: some View {
        card {
            VStack(spacing: 2) {
                Text(model.now.formatted(.dateTime.hour().minute())).font(font(64, .bold)).foregroundStyle(accent).monospacedDigit()
                HStack(spacing: 10) {
                    Text(model.now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).font(font(13, .medium))
                    Text("·").opacity(0.4)
                    Text("up " + Duration.seconds(ProcessInfo.processInfo.systemUptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)))
                        .font(font(11)).opacity(0.6)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var calendar: some View {
        let cal = Calendar.current, now = model.now
        let month = cal.dateInterval(of: .month, for: now)!
        let offset = (cal.component(.weekday, from: month.start) - cal.firstWeekday + 7) % 7
        let days = cal.range(of: .day, in: .month, for: now)!.count
        let today = cal.component(.day, from: now)
        let symbols = Array(cal.veryShortWeekdaySymbols[(cal.firstWeekday - 1)...] + cal.veryShortWeekdaySymbols[..<(cal.firstWeekday - 1)])
        // Weeks as rows with flexible space between, so the month fills the card instead of leaving a gap under it.
        let cells = Array(repeating: 0, count: offset) + Array(1...days)
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return card(fill: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text(now.formatted(.dateTime.month(.wide).year())).font(font(11, .semibold)).opacity(0.8)
                Spacer(minLength: 4)
                HStack(spacing: 0) { ForEach(Array(symbols.enumerated()), id: \.offset) { Text($0.element).font(font(9, .semibold)).opacity(0.5).frame(maxWidth: .infinity) } }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    Spacer(minLength: 2)
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            let d = i < week.count ? week[i] : 0
                            Group {
                                if d == 0 { Color.clear }
                                else {
                                    Text("\(d)").font(font(10, d == today ? .bold : .regular))
                                        .frame(width: 22, height: 18)
                                        .background(Circle().fill(d == today ? accent.opacity(0.9) : .clear))
                                        .foregroundStyle(d == today ? Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(1)) : fg)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Fills the rest of its column: cover, title, artist, controls, centred.
    private var music: some View {
        card(fill: true) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Group {
                    if let art = model.track?.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: "music.note").font(.system(size: 26)).opacity(0.5) }
                }
                .frame(width: 70, height: 70).background(tile).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(spacing: 2) {
                    Text(model.track?.title ?? "Not Playing").font(font(12, .bold)).lineLimit(1)
                    Text(model.track.map { $0.artist.isEmpty ? $0.player : $0.artist } ?? "Spotify or Music").font(font(10)).opacity(0.65).lineLimit(1)
                }
                HStack(spacing: 22) {
                    button("backward.fill") { NowPlaying.shared.send("previous track") }
                    button(model.track?.playing == true ? "pause.fill" : "play.fill", size: 16) { NowPlaying.shared.send("playpause") }
                    button("forward.fill") { NowPlaying.shared.send("next track") }
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func button(_ symbol: String, size: CGFloat = 12, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 18, height: 18) }.buttonStyle(.plain)
    }

    private var sliders: some View {
        card {
            VStack(spacing: 8) {
                row("speaker.wave.2.fill", Binding(get: { model.volume }, set: model.setVolume))
                if model.brightness != nil {
                    row("sun.max.fill", Binding(get: { model.brightness ?? 0 }, set: model.setBrightness))
                }
            }
        }
    }

    private func row(_ symbol: String, _ v: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 16)
            Slider(value: v, in: 0...1).tint(accent).controlSize(.small)
        }
    }

    private var toggles: some View {
        HStack(spacing: 8) {
            toggle(model.dark ? "moon.fill" : "sun.max.fill", model.dark ? "Dark" : "Light", on: model.dark) { model.setDark(!model.dark) }
            toggle(model.awake ? "cup.and.saucer.fill" : "cup.and.saucer", model.awake && !KeepAwake.remaining.isEmpty ? "Awake · \(KeepAwake.remaining)" : "Awake",
                   on: model.awake) { model.setAwake(!model.awake) }
                .contextMenu { awakeMenu }
                .help("Click: on / off. Right-click: how long, display, lid closed.")
        }
    }

    /// Amphetamine's choices: how long, whether the display may sleep, and lid-closed (set up once with the password).
    @ViewBuilder private var awakeMenu: some View {
        Button("Until turned off") { model.setAwake(true) }
        Button("For 15 minutes") { model.setAwake(true, minutes: 15) }
        Button("For 30 minutes") { model.setAwake(true, minutes: 30) }
        Button("For 1 hour") { model.setAwake(true, minutes: 60) }
        Button("For 2 hours") { model.setAwake(true, minutes: 120) }
        Divider()
        Toggle("Let the display sleep", isOn: Binding(get: { KeepAwake.displaySleep }, set: { KeepAwake.displaySleep = $0 }))
        if KeepAwake.lidReady {
            Toggle("Keep awake with the lid closed", isOn: Binding(get: { KeepAwake.lidClosed }, set: { KeepAwake.lidClosed = $0 }))
        } else {
            Button("Keep awake with the lid closed… (asks for your password once)") {
                KeepAwake.setUpLid { ok in if ok { KeepAwake.lidClosed = true } }
            }
        }
        if model.awake { Divider(); Button("Turn off") { model.setAwake(false) } }
    }

    private func toggle(_ symbol: String, _ label: String, on: Bool, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(label).font(font(10, .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? accent.opacity(0.85) : tile))
            .foregroundStyle(on ? Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(1)) : fg)
        }.buttonStyle(.plain)
    }

    private var power: some View {
        HStack(spacing: 6) {
            power("lock.fill", "Lock") { close(); System.lock() }
            power("moon.zzz.fill", "Sleep") { close(); System.sleep() }
            power("arrow.clockwise", "Restart") { close(); System.confirm("Restart", "restart") }
            power("power", "Shut Down") { close(); System.confirm("Shut Down", "shut down") }
        }
    }

    private func power(_ symbol: String, _ help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 30)
                .background(Circle().fill(tile))
        }.buttonStyle(.plain).help(help)
    }
}
