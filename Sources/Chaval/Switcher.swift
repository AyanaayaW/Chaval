import SwiftUI
import Carbon.HIToolbox

/// Chaval's ⌘Tab: the open windows on the current desktop (not apps), most recent first, in the bar's theme. Hold ⌘ and press Tab to
/// move along (⇧ or the arrows go back), let go of ⌘ to switch; Esc cancels, Q quits the app, W closes the window.
/// A quick ⌘Tab switches to the previous window without the panel ever showing, like the system's.
final class Switcher {
    static let shared = Switcher()

    struct Entry: Identifiable {
        let id: String
        let app: NSRunningApplication
        let window: AXUIElement? // nil on another desktop: Accessibility only sees this one's windows
        let windowID: CGWindowID
        let title: String
        let desktop: Int?
    }

    private var panel: NSPanel?
    private let model = SwitcherModel()
    private var refs: [EventHotKeyRef] = []
    private var monitors: [Any] = []
    private var showWork: DispatchWorkItem?
    private var active = false
    var isOpen: Bool { active }
    static let tabID: UInt32 = 50, backID: UInt32 = 51

    // The system's own ⌘Tab and ⌘⇧Tab are "symbolic hot keys" 1 and 2; while they're on, nobody else can have them.
    typealias SetSymbolic = @convention(c) (Int32, Bool) -> Int32
    static let setSymbolic: SetSymbolic? = (dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled")
        ?? dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW), "SLSSetSymbolicHotKeyEnabled"))
        .map { unsafeBitCast($0, to: SetSymbolic.self) }

    /// Takes ⌘Tab over from macOS, or hands it back.
    func sync() {
        let on = Store.shared.settings.cmdTab
        _ = Switcher.setSymbolic?(1, !on); _ = Switcher.setSymbolic?(2, !on)
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        guard on else { return }
        if panel == nil { panel = make() } // built now, not on the first ⌘Tab: setting up its view takes ~60 ms
        for (id, mods) in [(Switcher.tabID, cmdKey), (Switcher.backID, cmdKey | shiftKey)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Tab), UInt32(mods), EventHotKeyID(signature: 0x50495252, id: id), GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
    }

    /// Checks without touching anything (turning the system's ⌘Tab off here would turn it off for real).
    static func selfTest() {
        assert(setSymbolic != nil, "the system ⌘Tab switch is still there")
        print("switcher selftest ok (\(entries().count) entries)")
    }

    /// Diagnostic for `--render-switcher FILE`: draws the panel off screen with the real windows.
    static func render(to path: String) {
        let m = SwitcherModel(); m.entries = entries(); m.selected = min(1, max(m.entries.count - 1, 0))
        let v = NSHostingView(rootView: SwitcherView(model: m).environmentObject(Store.shared))
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = v
        v.frame.size = v.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Gives ⌘Tab back to macOS (Chaval quitting).
    func restoreSystem() { _ = Switcher.setSymbolic?(1, true); _ = Switcher.setSymbolic?(2, true); _ = Switcher.setSymbolic?(HotKeys.spotlight, true) }

    /// ⌘Tab (or ⌘⇧Tab) pressed.
    func tab(back: Bool) {
        guard active else { return open(back: back) }
        model.move(back ? -1 : 1)
    }

    private func open(back: Bool) {
        active = true
        model.entries = Switcher.entries()
        guard !model.entries.isEmpty else { active = false; return }
        model.selected = model.entries.count > 1 ? (back ? model.entries.count - 1 : 1) : 0
        // ⌘ let go: switch. Watched both ways: while the panel is key the events come to us, otherwise to the app in front.
        let flags: (NSEvent) -> Void = { [weak self] e in if !e.modifierFlags.contains(.command) { self?.commit() } }
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any,
                    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any,
                    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e } as Any]
        // Released already (a quick tap): no panel at all. Otherwise show it after a beat, as macOS does.
        if !NSEvent.modifierFlags.contains(.command) { return commit() }
        let w = DispatchWorkItem { [weak self] in self?.show() }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func key(_ e: NSEvent) -> NSEvent? {
        switch Int(e.keyCode) {
        case kVK_Escape: close()
        case kVK_LeftArrow, kVK_UpArrow: model.move(-1)
        case kVK_RightArrow, kVK_DownArrow: model.move(1)
        case kVK_Return: commit()
        case kVK_ANSI_Q: if let a = model.current?.app { a.terminate(); model.drop { $0.app == a } }
        case kVK_ANSI_W:
            if let w = model.current?.window, let b: AXUIElement = AX.get(w, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(b, kAXPressAction as CFString); model.drop { $0.id == self.model.current?.id }
            }
        default: return e
        }
        return nil
    }

    func commit() {
        guard active else { return }
        let e = model.current
        close()
        guard let e else { return }
        if let w = e.window { return AX.focus(w, of: e.app) }
        // On another desktop: go there, then find the window (Accessibility can see it once it's on this desktop).
        guard let n = e.desktop, let go = HotKeys.Action(rawValue: "desktop\(n)") else { return bringForward(e.app) }
        go.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if let w = AX.windows(e.app).first(where: { Tiler.id($0) == e.windowID }) { AX.focus(w, of: e.app) } else { bringForward(e.app) }
        }
    }

    func pick(_ i: Int) { model.selected = i; commit() }

    private func close() {
        active = false
        showWork?.cancel(); showWork = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard let p = panel, p.isVisible else { return }
        // Out: a quick fade while it settles back a little.
        pop(p, from: 1, to: 0.94, spring: false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in if self?.active == false { p.orderOut(nil) } })
    }

    /// Scales the panel's contents about their centre (the window itself can't scale).
    private func pop(_ p: NSPanel, from: CGFloat, to: CGFloat, spring: Bool) {
        guard let l = p.contentView?.layer else { return }
        let b = l.bounds
        func t(_ k: CGFloat) -> CATransform3D {
            CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-b.midX, -b.midY, 0), CATransform3DMakeScale(k, k, 1)),
                                CATransform3DMakeTranslation(b.midX, b.midY, 0))
        }
        let a: CABasicAnimation
        if spring { a = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.22) } else { a = CABasicAnimation(); a.duration = 0.12; a.timingFunction = CAMediaTimingFunction(name: .easeIn) }
        a.keyPath = "transform"
        a.fromValue = NSValue(caTransform3D: spring ? t(from) : (l.presentation() ?? l).transform) // in: from small; out: from wherever it is
        a.toValue = NSValue(caTransform3D: t(to))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.transform = t(to)
        CATransaction.commit()
        l.add(a, forKey: "pop")
    }

    private func show() {
        guard active else { return }
        let p = panel ?? make()
        panel = p
        let host = p.contentView!
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let s = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        p.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey() // Esc, the arrows, Q and W come to us while it's up
        // In: it grows into place from a little smaller with a soft spring, fading up.
        host.wantsLayer = true
        pop(p, from: 0.88, to: 1, spring: true)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; p.animator().alphaValue = 1 }
    }

    private func make() -> NSPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: SwitcherView(model: model).environmentObject(Store.shared))
        return p
    }

    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

    /// The open windows on the current desktop, front to back (so most recent first). Other desktops', minimized ones,
    /// hidden apps' and windows an app keeps after "closing" them (Discord, WhatsApp) aren't listed.
    static func entries() -> [Entry] {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.isRegular && $0.processIdentifier != getpid() && !$0.isHidden }
        let byPid = Dictionary(regular.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var ax: [pid_t: [CGWindowID: AXUIElement]] = [:]
        func axWindows(_ app: NSRunningApplication) -> [CGWindowID: AXUIElement] {
            if let m = ax[app.processIdentifier] { return m }
            let m = Dictionary(AX.windows(app).compactMap { w in Tiler.id(w).map { ($0, w) } }, uniquingKeysWith: { a, _ in a })
            ax[app.processIdentifier] = m
            return m
        }
        let desks = Desktops.allDesktops, here = Set(Desktops.displays.map(\.current))
        var out: [(Entry, Bool)] = []
        for w in CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, let app = byPid[pid],
                  let id = w[kCGWindowNumber as String] as? CGWindowID, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), b.width >= 80, b.height >= 80,
                  Desktops.isShown(id), let n = Desktops.desktopNumber(of: id, in: desks) else { continue }
            let onHere = here.contains(desks[n - 1]), el = axWindows(app)[id]
            if let el, AX.isMinimized(el) { continue }
            if onHere && !(w[kCGWindowIsOnscreen as String] as? Bool ?? false) { continue } // on this desktop yet not showing: hidden
            if onHere && el == nil { continue } // not a real window (a helper surface Accessibility doesn't list)
            let title = el.map(AX.title) ?? (w[kCGWindowName as String] as? String ?? "")
            out.append((Entry(id: "w\(id)", app: app, window: onHere ? el : nil, windowID: id, title: title, desktop: n), onHere))
        }
        return out.filter(\.1).map(\.0) // this desktop's windows only
    }
}

final class SwitcherModel: ObservableObject {
    @Published var entries: [Switcher.Entry] = []
    @Published var selected = 0
    var current: Switcher.Entry? { entries.indices.contains(selected) ? entries[selected] : nil }
    func move(_ d: Int) { guard !entries.isEmpty else { return }; selected = (selected + d + entries.count) % entries.count }
    func drop(_ f: (Switcher.Entry) -> Bool) {
        entries.removeAll(where: f)
        selected = min(selected, max(entries.count - 1, 0))
        if entries.isEmpty { Switcher.shared.commit() }
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @EnvironmentObject var store: Store
    private var s: DashStyle { DashStyle(t: store.bar.theme) }
    private let columns = 8, side: CGFloat = 104

    var body: some View {
        let t = store.bar.theme
        // As wide as its windows (up to a row of 8), then wrapping.
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 6), count: min(columns, max(model.entries.count, 1))), spacing: 6) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { i, e in tile(e, on: i == model.selected).onTapGesture { Switcher.shared.pick(i) }
                .onHover { if $0 { model.selected = i } }
            }
        }
        .padding(10)
        .foregroundStyle(s.fg)
        .background(RoundedRectangle(cornerRadius: max(t.pillCorner, 12)).fill(Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(max(NSColor(hex: t.bgHex).alphaComponent, 0.96)))))
        .overlay(RoundedRectangle(cornerRadius: max(t.pillCorner, 12)).stroke(Color(nsColor: NSColor(hex: t.borderHex)), lineWidth: t.border ? 1 : 0))
        .fixedSize()
    }

    private func tile(_ e: Switcher.Entry, on: Bool) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: e.app.icon ?? NSImage()).resizable().frame(width: 54, height: 54)
            Text(e.title.isEmpty ? e.app.localizedName ?? "" : e.title).font(s.font(10, on ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: side - 12)
        }
        .frame(width: side, height: side) // square
        .background(RoundedRectangle(cornerRadius: 10).fill(on ? s.accent.opacity(0.22) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? s.accent : .clear, lineWidth: 1.5))
        .foregroundStyle(on ? s.accent : s.fg)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: on)
    }
}
