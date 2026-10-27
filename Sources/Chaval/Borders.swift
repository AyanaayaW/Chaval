import SwiftUI
import AppKit

/// Window borders drawn by the tiler itself. Each moves on the same display frame as its window's glide step, so it
/// never trails the window the way JankyBorders does (that only hears about a move after it has happened).
/// A border is a click-through panel just outside the window, on the window's own desktop.
final class Borders {
    static let shared = Borders()
    private var panels: [CGWindowID: NSPanel] = [:]
    private var active: CGWindowID?
    private var st: Settings { Store.shared.settings }
    private var on: Bool { st.borders && st.tiling }

    private init() {
        // A new theme recolours them.
        NotificationCenter.default.addObserver(forName: .chavalChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for (id, p) in self.panels { self.colour(p, id) }
        }
    }

    /// Shows borders for exactly these windows (top-left global frames, as Accessibility gives them).
    func sync(_ frames: [CGWindowID: CGRect]) {
        guard on else { return clear() }
        for (id, p) in panels where frames[id] == nil { p.orderOut(nil); panels[id] = nil }
        for (id, r) in frames { move(id, r) }
    }

    /// Puts a window's border around `r`. Called every glide frame, so it does nothing it doesn't have to.
    func move(_ id: CGWindowID, _ r: CGRect) {
        guard on, r.width > 0 else { return }
        let p = panels[id] ?? make(id)
        let w = CGFloat(st.borderWidth), top = NSScreen.screens.first?.frame.maxY ?? 0
        let f = NSRect(x: r.minX - w, y: top - r.maxY - w, width: r.width + 2 * w, height: r.height + 2 * w).integral
        if p.frame != f {
            let resized = p.frame.size != f.size
            p.setFrame(f, display: false)
            if resized { shape(p, id) }
        }
        if !p.isVisible { p.order(.above, relativeTo: Int(id)) }
    }

    /// The focused window gets the active colour; borders are re-stacked above their windows (activating an app
    /// brings its windows forward over theirs).
    func focus(_ id: CGWindowID?) {
        active = id
        for (wid, p) in panels {
            colour(p, wid)
            if p.isVisible { p.order(.above, relativeTo: Int(wid)) }
        }
    }

    func clear() { panels.values.forEach { $0.orderOut(nil) }; panels = [:] }

    /// Style changed (width, radius, theme): redraw them all.
    func restyle() { for (id, p) in panels { shape(p, id) } }

    private func make(_ id: CGWindowID) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone] // stays on the window's desktop
        p.animationBehavior = .none
        let v = NSView()
        v.wantsLayer = true
        let s = CAShapeLayer()
        s.fillColor = nil
        s.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()] // follow the window, never ease behind it
        v.layer = s
        p.contentView = v
        panels[id] = p
        return p
    }

    private func shape(_ p: NSPanel, _ id: CGWindowID) {
        guard let s = p.contentView?.layer as? CAShapeLayer else { return }
        let w = CGFloat(st.borderWidth), b = CGRect(origin: .zero, size: p.frame.size).insetBy(dx: w / 2, dy: w / 2)
        let r = min(CGFloat(st.borderRadius) + w / 2, b.width / 2, b.height / 2)
        s.lineWidth = w
        s.path = RoundedRectangle(cornerRadius: r, style: .continuous).path(in: b).cgPath // macOS 26+ windows have squircle corners
        colour(p, id)
    }

    private func colour(_ p: NSPanel, _ id: CGWindowID) {
        (p.contentView?.layer as? CAShapeLayer)?.strokeColor = Borders.colour(focused: id == active).cgColor
    }

    /// A border's colour: the focused window's, or the others' (clear when unfocused windows get none).
    static func colour(focused: Bool) -> NSColor {
        let s = Store.shared.settings, accent = NSColor(hex: Store.shared.bar.theme.accentHex)
        if !focused && !s.borderInactive { return .clear }
        if s.borderThemed { return focused ? accent : accent.withAlphaComponent(0.35) }
        return NSColor(hex: focused ? s.borderActiveHex : s.borderInactiveHex)
    }
}
