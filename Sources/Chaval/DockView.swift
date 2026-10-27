import AppKit

final class Tile {
    enum Kind { case app, folder, file, spacer, flex, separator, trash, launcher, minimized, window, placeholder, widget }
    let kind: Kind
    let key: String
    var url: URL?
    var item: Item?
    var app: NSRunningApplication?
    var window: AXUIElement?
    var title = ""
    var pinned = false
    var section = 0 // 0 the user's items and running apps, 1 recents, 2 minimized windows
    var badge: String?
    var image: CGImage?
    var span = 1 // wide widgets take 2–3 slots
    var faded = false
    var overlay: CGImage?   // shown through a mask at `highlight` (0…1 across): the Desktops widget's sliding pill
    var highlight: CGRect?
    var nameWidth: CGFloat = 0 // room for the name beside the icon, when labels are always shown
    // layout, along the dock's axis, relative to its centre
    var base: CGFloat = 0, center: CGFloat = 0, width: CGFloat = 0, size: CGFloat = 0
    var ratio: CGFloat = 1 // width over icon size: a widget's span, or icon plus name

    init(_ kind: Kind, key: String) { self.kind = kind; self.key = key }

    var draggable: Bool {
        switch kind {
        case .app: return section == 0 && (pinned || app != nil)
        case .separator, .minimized, .window, .placeholder: return false
        default: return pinned
        }
    }
    var across: CGFloat { size / ratio }
    var iconic: Bool { kind != .separator && kind != .spacer && kind != .flex && kind != .placeholder }
}

final class TileLayer: CALayer {
    let icon = CALayer(), dot = CALayer(), badgeBG = CALayer(), badge = CATextLayer(), title = CATextLayer()
    let overlay = CALayer(), pill = CALayer()

    override init() {
        super.init()
        icon.contentsGravity = .resizeAspect
        badgeBG.backgroundColor = NSColor.systemRed.cgColor
        badge.alignmentMode = .center
        badgeBG.addSublayer(badge)
        title.truncationMode = .end
        overlay.contentsGravity = .resize
        pill.backgroundColor = NSColor.black.cgColor
        overlay.mask = pill
        overlay.isHidden = true
        [icon, overlay, title, dot, badgeBG].forEach(addSublayer)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

final class DockView: NSView {
    unowned let dock: DockController
    private(set) var tiles: [Tile] = []
    private var layers: [String: TileLayer] = [:]
    private let hostView = NSView()
    private let host = CALayer()
    private var bg = NSView()
    private let shadowView = NSView()
    private let label = CATextLayer(), labelBG = CALayer()

    var hover: CGFloat?
    var maxLength: CGFloat = 10_000
    private var fit: CGFloat = 1
    private(set) var barRect = NSRect.zero
    private var down: (tile: Tile?, point: NSPoint)?
    private(set) var dragging: Tile?
    private var dragPos = CGPoint.zero
    private var removing = false
    private var dropKey: String?
    private var scrollAccum: CGFloat = 0
    private var liftedKey: String?
    private var labelLift: CGFloat = 0

    private var st: Settings { Store.shared.settings }
    private var edge: Edge { st.edge }
    var S: CGFloat { CGFloat(st.iconSize) * fit }
    var M: CGFloat { st.magnify ? max(CGFloat(st.magnifiedSize), S) : S }
    var pad: CGFloat { CGFloat(st.padding) }
    var gap: CGFloat { CGFloat(st.edgeGap) }
    private var spacing: CGFloat { CGFloat(st.spacing) * fit }
    var thickness: CGFloat { gap + S + 2 * pad }
    var headroom: CGFloat { max(M - S + (hoverLabels ? 34 : 0), S * 0.6) }
    private var horizontal: Bool { edge == .bottom || edge == .top }
    /// Names beside icons only fit a horizontal dock; a side dock shows them on hover instead.
    private var hoverLabels: Bool { st.labels == .hover || st.labels == .always && !horizontal }
    var magnifyExtra: CGFloat { st.magnify ? (M - S) * CGFloat(st.magnifySpread + 1) : 0 }
    var baseLength: CGFloat {
        let sum = tiles.reduce(0) { $0 + width($1) } + spacing * CGFloat(max(tiles.count - 1, 0)) + 2 * pad
        return st.taskbar ? max(sum, maxLength) : sum
    }
    private var flexWidths: [String: CGFloat] = [:]

    init(dock: DockController) {
        self.dock = dock
        super.init(frame: .zero)
        wantsLayer = true
        hostView.layer = host
        hostView.wantsLayer = true
        hostView.autoresizingMask = [.width, .height]
        host.masksToBounds = false
        labelBG.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        labelBG.addSublayer(label)
        label.alignmentMode = .center
        shadowView.wantsLayer = true
        addSubview(shadowView)
        addSubview(bg)
        addSubview(hostView)
        host.addSublayer(labelBG)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Dock")
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ p: NSPoint) -> NSView? { frame.contains(p) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Style

    func applyStyle() {
        bg.removeFromSuperview()
        let tint = NSColor(hex: st.tintHex)
        if st.material == .glass, #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.tintColor = tint.alphaComponent > 0 ? tint : nil
            bg = g
        } else if st.material == .blur {
            let v = NSVisualEffectView()
            v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
            bg = v
        } else {
            bg = NSView()
        }
        bg.wantsLayer = true
        if !(bg is GlassLike) {
            // Solid is fully opaque (the tint's own alpha, e.g. a theme's, is ignored); Opacity alone makes it see-through.
            let color = st.material != .solid ? tint : tint.alphaComponent == 0 ? NSColor(white: 0.12, alpha: 1) : tint.withAlphaComponent(1)
            bg.layer?.backgroundColor = color.cgColor
        }
        bg.alphaValue = st.opacity
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = st.border ? st.dockBorderWidth : 0
        bg.layer?.borderColor = (st.dockBorderAccent ? NSColor(hex: Store.shared.bar.theme.accentHex) : NSColor(white: 1, alpha: 0.22)).cgColor
        addSubview(bg, positioned: .above, relativeTo: shadowView)
        shadowView.layer?.shadowOpacity = st.shadow && st.material != .clear ? 0.35 : 0
        shadowView.layer?.shadowRadius = 10
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        appearance = st.look == .system ? nil : NSAppearance(named: st.look == .dark ? .darkAqua : .aqua)
        host.contentsScale = window?.backingScaleFactor ?? 2
        layout()
    }

    // MARK: Model

    func set(_ new: [Tile]) {
        let keep = Set(new.map(\.key))
        for (k, l) in layers where !keep.contains(k) { l.removeFromSuperlayer(); layers[k] = nil }
        if let d = dragging, let fresh = new.first(where: { $0.key == d.key }) { dragging = fresh }
        tiles = new
        let named = st.labels == .always && horizontal
        let font = Fonts.font(CGFloat(st.labelSize), .medium)
        for t in tiles where named && t.iconic && t.kind != .widget && t.kind != .window && !t.title.isEmpty { // windows: icons only
            t.nameWidth = min(NSAttributedString(string: t.title, attributes: [.font: font]).size().width, 110) + CGFloat(st.iconSize) * 0.15 + 8
        }
        for t in tiles {
            let l = layers[t.key] ?? {
                let l = TileLayer()
                host.insertSublayer(l, below: labelBG)
                layers[t.key] = l
                return l
            }()
            configure(l, t)
        }
        layout(animated: true)
    }

    private func configure(_ l: TileLayer, _ t: Tile) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        l.icon.contents = t.image
        l.overlay.contents = t.overlay
        l.overlay.isHidden = t.overlay == nil
        l.icon.opacity = t.faded ? 0.45 : 1
        l.backgroundColor = t.kind == .separator ? NSColor(white: 1, alpha: 0.25).cgColor : nil
        l.icon.cornerRadius = 0
        l.icon.backgroundColor = t.kind == .minimized ? NSColor(white: 1, alpha: 0.12).cgColor : nil
        let color = NSColor(hex: st.indicatorHex).cgColor
        l.dot.backgroundColor = color
        l.dot.isHidden = t.app == nil || st.indicator == .none || t.kind == .minimized || t.kind == .window
        l.dot.shadowColor = color
        l.dot.shadowOpacity = st.indicator == .glow ? 1 : 0
        l.dot.shadowRadius = 4
        l.dot.shadowOffset = .zero
        l.badgeBG.isHidden = t.badge == nil
        l.badge.contentsScale = scale
        CATransaction.commit()
    }

    func setImage(_ key: String, _ image: CGImage?) { layers[key]?.icon.contents = image }

    // MARK: Geometry

    private func width(_ t: Tile) -> CGFloat {
        if t === dragging && removing { return 0 }
        switch t.kind {
        case .separator: return max(9, S * 0.22)
        case .spacer: return S * 0.6
        case .flex: return st.taskbar ? flexWidths[t.key] ?? S * 0.3 : S * 0.6
        case .widget: return S * CGFloat(t.span)
        default: return S + t.nameWidth * fit
        }
    }

    /// Rect for something centred at `a` along the dock, starting `c` from the screen edge.
    private func rect(_ a: CGFloat, _ c: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        switch edge {
        case .bottom: return CGRect(x: bounds.midX + a - w / 2, y: c, width: w, height: h)
        case .top: return CGRect(x: bounds.midX + a - w / 2, y: bounds.maxY - c - h, width: w, height: h)
        case .left: return CGRect(x: c, y: bounds.midY - a - w / 2, width: h, height: w)
        case .right: return CGRect(x: bounds.maxX - c - h, y: bounds.midY - a - w / 2, width: h, height: w)
        }
    }

    private func axes(_ p: NSPoint) -> (along: CGFloat, across: CGFloat) {
        switch edge {
        case .bottom: return (p.x - bounds.midX, p.y)
        case .top: return (p.x - bounds.midX, bounds.maxY - p.y)
        case .left: return (bounds.midY - p.y, p.x)
        case .right: return (bounds.midY - p.y, bounds.maxX - p.x)
        }
    }

    override func layout() { super.layout(); layout(animated: false) }

    func layout(animated: Bool) {
        let fixedTiles = tiles.filter { $0.kind != .flex }
        let raw = fixedTiles.reduce(0) { $0 + width($1) / fit } + CGFloat(st.spacing) * CGFloat(max(tiles.count - 1, 0))
        fit = min(1, max(0.2, (maxLength - 2 * pad) / max(raw, 1)))
        // Taskbar: flexible spaces share whatever length the rest of the items leave over.
        let flexes = tiles.count - fixedTiles.count
        if st.taskbar && flexes > 0 {
            let used = fixedTiles.reduce(0) { $0 + width($1) } + spacing * CGFloat(max(tiles.count - 1, 0)) + 2 * pad
            let free = maxLength - used, flexKeys = tiles.filter { $0.kind == .flex }.map(\.key)
            flexWidths = Dictionary(uniqueKeysWithValues: flexKeys.map { ($0, max(S * 0.3, free / CGFloat(flexes))) })
            // Exactly two: whatever sits between them goes in the middle of the bar (e.g. the desktops widget).
            if flexes == 2, let f1 = tiles.firstIndex(where: { $0.kind == .flex }), let f2 = tiles.lastIndex(where: { $0.kind == .flex }) {
                let before = tiles[..<f1].reduce(0) { $0 + width($1) + spacing }
                let middle = tiles[(f1 + 1)..<f2].reduce(0) { $0 + width($1) } + spacing * CGFloat(max(f2 - f1 - 2, 0))
                let first = maxLength / 2 - pad - before - spacing - middle / 2
                if first >= S * 0.3, free - first >= S * 0.3 { flexWidths = [tiles[f1].key: first, tiles[f2].key: free - first] }
            }
        }

        var a = -baseLength / 2 + pad
        for t in tiles {
            t.width = width(t); t.base = a + t.width / 2; a += t.width + spacing
            if t.width > 0 { t.ratio = t.width / S }
        }

        let R = (S + spacing) * CGFloat(st.magnifySpread) / 2 + S / 2
        let placed = DockView.magnify(tiles.map { ($0.base, $0.width, $0.iconic && $0.kind != .widget) }, // widgets stay put
                                      hover: st.magnify && dragging == nil ? hover : nil, S: S, M: M, R: R, curve: st.magnifyCurve)
        for (t, p) in zip(tiles, placed) { (t.center, t.size) = p }
        var start = (tiles.first.map { $0.center - $0.size / 2 } ?? 0) - pad
        var end = (tiles.last.map { $0.center + $0.size / 2 } ?? 0) + pad
        if st.taskbar, let first = tiles.first, let last = tiles.last {
            // Magnified icons grow into the flexible space instead of off the screen: the run before the
            // first flex stays pinned to the start, the run after the last flex to the end.
            let firstFlex = tiles.firstIndex { $0.kind == .flex } ?? tiles.count
            let lastFlex = tiles.lastIndex { $0.kind == .flex } ?? tiles.count
            let dl = (first.base - first.width / 2) - (first.center - first.size / 2)
            tiles[..<firstFlex].forEach { $0.center += dl }
            if lastFlex < tiles.count - 1 {
                let dr = (last.base + last.width / 2) - (last.center + last.size / 2)
                tiles[(lastFlex + 1)...].forEach { $0.center += dr }
            }
            (start, end) = (-baseLength / 2, baseLength / 2)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        barRect = rect((start + end) / 2, gap, end - start, S + 2 * pad)
        let radius = min(CGFloat(st.cornerRadius), barRect.height / 2, barRect.width / 2)
        if let g = bg as? GlassLike { g.radius = radius } else { bg.layer?.cornerRadius = radius }
        bg.frame = barRect
        shadowView.frame = barRect
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let hovered = hover.flatMap { x in tiles.first { $0.iconic && $0 !== dragging && abs(x - $0.center) <= $0.size / 2 + spacing / 2 } }
        let lift = st.hoverLift ? S * 0.18 : 0
        for t in tiles {
            guard let l = layers[t.key] else { continue }
            if t.kind == .separator {
                l.frame = rect(t.center, gap + pad + S * 0.1, 1, S * 0.8)
                continue
            }
            if t === dragging {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                l.frame = rect(dragPos.x, max(gap + pad, dragPos.y - S / 2), S * t.ratio, S)
                l.opacity = removing ? 0.5 : 1
                place(l, t, S)
                CATransaction.commit()
                continue
            }
            l.opacity = 1
            let lifted = t === hovered || t.key == liftedKey
            if lifted && liftedKey != hovered?.key { CATransaction.begin(); CATransaction.setDisableActions(false); CATransaction.setAnimationDuration(0.15) }
            l.frame = rect(t.center, gap + pad + (t === hovered && t.kind != .widget ? lift : 0), t.size, t.across)
            if lifted && liftedKey != hovered?.key { CATransaction.commit() }
            place(l, t, t.across)
        }
        liftedKey = hovered?.key
        labelLift = hovered != nil ? lift : 0
        let showLabel = hoverLabels && dragging == nil
        placeLabel(showLabel ? (hovered?.kind == .widget ? nil : hovered) ?? dropTile : nil) // widgets show their own info
        CATransaction.commit()
    }

    /// Grows icons near the cursor and pushes neighbours outward so the icon under the cursor stays put
    /// (each icon's growth splits around the cursor, like the system Dock). Returns (center, size) per tile.
    static func magnify(_ tiles: [(base: CGFloat, width: CGFloat, iconic: Bool)], hover: CGFloat?,
                        S: CGFloat, M: CGFloat, R: CGFloat, curve: Curve = .smooth) -> [(CGFloat, CGFloat)] {
        var growth = [CGFloat](repeating: 0, count: tiles.count), frac = growth
        if let x = hover {
            for (i, t) in tiles.enumerated() where t.iconic && t.width > 0 {
                let d = abs(x - t.base) / R
                if d < 1 { growth[i] = (M - S) * falloff(curve, d) * (t.width / S) }
                frac[i] = min(max((x - (t.base - t.width / 2)) / t.width, 0), 1)
            }
        }
        var left = growth.indices.reduce(CGFloat(0)) { $0 + growth[$1] * frac[$1] }, right: CGFloat = 0
        return tiles.indices.map { i in
            left -= growth[i] * frac[i]
            let size = tiles[i].width + growth[i]
            let center = tiles[i].base - tiles[i].width / 2 - left - growth[i] * frac[i] + right + size / 2
            right += growth[i] * (1 - frac[i])
            return (center, size)
        }
    }

    /// 1 at the cursor, 0 at the edge of the magnified range.
    static func falloff(_ c: Curve, _ d: CGFloat) -> CGFloat {
        switch c {
        case .smooth: return (1 + cos(.pi * d)) / 2
        case .wide: return cos(.pi * d / 2)
        case .sharp: return (1 - d) * (1 - d)
        case .linear: return 1 - d
        }
    }

    static func selfTest() {
        let S: CGFloat = 50, M: CGFloat = 100, gap: CGFloat = 6
        let tiles = (0..<8).map { (CGFloat($0) * (S + gap), S, true) }
        let flat = magnify(tiles, hover: nil, S: S, M: M, R: 120)
        assert(zip(flat, tiles).allSatisfy { $0.0 == $1.0 && $0.1 == S }, "no hover: unchanged")
        for curve in Curve.allCases {
            for x in stride(from: -30, through: 7 * (S + gap) + 30, by: 7.0) {
            let p = magnify(tiles, hover: x, S: S, M: M, R: 120, curve: curve)
            for i in 1..<p.count {
                assert(p[i].0 - p[i - 1].0 >= (p[i].1 + p[i - 1].1) / 2 + gap - 0.001, "overlap at x=\(x) \(curve)")
            }
            }
        }
        let onIcon = magnify(tiles, hover: tiles[3].0, S: S, M: M, R: 120)
        assert(abs(onIcon[3].0 - tiles[3].0) < 0.001 && onIcon[3].1 == M, "hovered icon stays put at full size")
        assert(onIcon[2].1 == onIcon[4].1 && onIcon[2].1 < M && onIcon[2].1 > S, "symmetric falloff")
        print("selftest ok")
    }

    private var dropTile: Tile? { dropKey.flatMap { k in tiles.first { $0.key == k } } }

    private func place(_ l: TileLayer, _ t: Tile, _ size: CGFloat) {
        let b = t.nameWidth > 0 ? CGRect(x: 0, y: 0, width: size, height: size) : CGRect(origin: .zero, size: l.bounds.size)
        l.title.isHidden = t.nameWidth == 0
        if t.nameWidth > 0 {
            let k = size / CGFloat(st.iconSize) // the name grows with its icon
            // A plain string, not an attributed one: CATextLayer only truncates plain strings, and draws nothing for a long attributed one.
            let font = Fonts.font(CGFloat(st.labelSize) * k, .medium)
            let h = ceil(font.ascender - font.descender + font.leading), x = size + CGFloat(st.iconSize) * 0.15 * k
            l.title.string = t.title
            l.title.font = font
            l.title.fontSize = font.pointSize
            l.title.foregroundColor = NSColor(hex: st.widgetTextHex).cgColor
            l.title.contentsScale = window?.backingScaleFactor ?? 2
            l.title.opacity = t.faded ? 0.55 : 1
            l.title.frame = CGRect(x: x, y: (size - h) / 2, width: max(0, l.bounds.width - x - 8 * k), height: h)
        }
        l.icon.frame = t.kind == .minimized ? b.insetBy(dx: size * 0.08, dy: size * 0.08) : b
        l.icon.cornerRadius = t.kind == .minimized ? size * 0.12 : 0
        if t.overlay != nil, let h = t.highlight { slide(l, to: h, in: b) }
        l.icon.opacity = t.key == dropKey ? 0.55 : t.faded ? 0.45 : 1

        let bar = st.indicator == .bar
        let (w, h) = bar ? (size * 0.32, 3.0) : (5.0, 5.0)
        let d = max(pad / 2, 3)
        switch edge {
        case .bottom: l.dot.frame = CGRect(x: size / 2 - w / 2, y: -d - h / 2, width: w, height: h)
        case .top: l.dot.frame = CGRect(x: size / 2 - w / 2, y: size + d - h / 2, width: w, height: h)
        case .left: l.dot.frame = CGRect(x: -d - h / 2, y: size / 2 - w / 2, width: h, height: w)
        case .right: l.dot.frame = CGRect(x: size + d - h / 2, y: size / 2 - w / 2, width: h, height: w)
        }
        l.dot.cornerRadius = min(w, h) / 2

        if let text = t.badge {
            let bh = max(16, size * 0.3)
            let str = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: bh * 0.62, weight: .semibold), .foregroundColor: NSColor.white])
            let bw = max(bh, str.size().width + bh * 0.6)
            l.badgeBG.frame = CGRect(x: min(size * 0.86 - bw / 2, size - bw + 4), y: size * 0.86 - bh / 2, width: bw, height: bh)
            l.badgeBG.cornerRadius = bh / 2
            l.badge.string = str
            l.badge.frame = CGRect(x: 0, y: (bh - str.size().height) / 2, width: bw, height: str.size().height)
        }
    }

    /// Moves the Desktops widget's pill to the current desktop with a spring, so switching desktops visibly slides it.
    private func slide(_ l: TileLayer, to h: CGRect, in b: CGRect) {
        let H = b.height
        let target = CGRect(x: b.minX + h.minX * b.width + H * 0.04, y: H * 0.06, width: max(h.width * b.width - H * 0.08, 0), height: H * 0.88)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.overlay.frame = b
        let from = l.pill.presentation()?.frame ?? l.pill.frame
        l.pill.cornerRadius = target.height * CGFloat(st.deskCorner)
        l.pill.frame = target
        CATransaction.commit()
        guard abs(from.midX - target.midX) > 0.5 || abs(from.width - target.width) > 0.5, from.width > 0,
              abs(from.height - target.height) < 1 else { return } // a resized dock jumps; only a move between desktops glides
        for (key, a, b) in [("position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: CGPoint(x: target.midX, y: target.midY))),
                            ("bounds.size", NSValue(size: from.size), NSValue(size: target.size))] {
            let s = CASpringAnimation(perceptualDuration: 0.42, bounce: 0.18)
            s.keyPath = key; s.fromValue = a; s.toValue = b
            l.pill.add(s, forKey: key)
        }
    }

    private func placeLabel(_ t: Tile?) {
        guard let t, !t.title.isEmpty else { labelBG.isHidden = true; return }
        labelBG.isHidden = false
        let str = NSAttributedString(string: t.title, attributes: [.font: Fonts.font(CGFloat(st.labelSize), .medium), .foregroundColor: NSColor.white])
        let sz = str.size()
        let w = min(sz.width + 20, 320), h = sz.height + 8
        // Above the icon for horizontal docks, beside it for vertical ones.
        var r = rect(t.center, gap + pad + t.across + (t.kind == .widget ? 0 : labelLift) + 8, horizontal ? w : h, horizontal ? h : w)
        if !horizontal { r.size = CGSize(width: w, height: h); if edge == .right { r.origin.x -= w - h } }
        labelBG.frame = r
        labelBG.cornerRadius = h / 2
        label.string = str
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 10, y: 4, width: w - 20, height: sz.height)
        label.truncationMode = .middle
    }

    func frame(of t: Tile) -> NSRect { layers[t.key]?.frame ?? .zero }

    // MARK: Bounce

    func bounce(_ key: String, on: Bool) {
        guard let icon = layers[key]?.icon else { return }
        guard on, st.launchAnim != .none, !Store.shared.reduceMotion else {
            icon.removeAnimation(forKey: "launch"); return
        }
        let anim: CAAnimation
        switch st.launchAnim {
        case .pulse:
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1; a.toValue = 1.18; a.autoreverses = true; a.duration = 0.32; a.repeatCount = 60
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim = a
        case .wiggle:
            let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            a.values = [0, 0.16, -0.16, 0]; a.duration = 0.36; a.repeatCount = 60
            anim = a
        default:
            let a = CAKeyframeAnimation(keyPath: horizontal ? "transform.translation.y" : "transform.translation.x")
            let h = S * 0.45 * (edge == .bottom || edge == .left ? 1 : -1)
            a.values = [0, h, 0]
            a.keyTimes = [0, 0.45, 1]
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            a.duration = 0.6
            a.repeatCount = 30
            anim = a
        }
        icon.add(anim, forKey: "launch")
    }

    /// Click feedback while the button is held.
    private func press(_ t: Tile?, _ on: Bool) {
        guard let t, t.iconic, let icon = layers[t.key]?.icon else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.08)
        switch st.clickEffect {
        case .darken: icon.opacity = on ? 0.55 : t.faded ? 0.45 : 1
        case .shrink: icon.transform = on ? CATransform3DMakeScale(0.86, 0.86, 1) : CATransform3DIdentity
        case .none: break
        }
        CATransaction.commit()
    }

    /// Zoom reveal: scales the dock's contents toward the screen edge.
    func zoom(from a: CGFloat, to b: CGFloat, duration: Double) {
        guard let l = layer else { return }
        let c: CGPoint = switch edge {
        case .bottom: CGPoint(x: bounds.midX, y: 0)
        case .top: CGPoint(x: bounds.midX, y: bounds.maxY)
        case .left: CGPoint(x: 0, y: bounds.midY)
        case .right: CGPoint(x: bounds.maxX, y: bounds.midY)
        }
        func m(_ s: CGFloat) -> CATransform3D {
            CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(c.x, c.y, 0), s, s, 1), -c.x, -c.y, 0)
        }
        let anim = CABasicAnimation(keyPath: "sublayerTransform")
        anim.fromValue = m(a); anim.toValue = m(b); anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.sublayerTransform = b == 1 ? CATransform3DIdentity : m(b)
        l.add(anim, forKey: "zoom")
    }

    func resetZoom() { layer?.removeAnimation(forKey: "zoom"); layer?.sublayerTransform = CATransform3DIdentity }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func tile(at p: NSPoint) -> Tile? {
        let (a, c) = axes(p)
        guard c <= gap + 2 * pad + (tiles.map(\.across).max() ?? S) else { return nil }
        return tiles.first { $0.kind != .separator && $0.kind != .placeholder && abs(a - $0.center) <= $0.size / 2 + spacing / 2 }
    }

    override func mouseEntered(with e: NSEvent) { dock.hoverBegan(); mouseMoved(with: e) }
    override func mouseExited(with e: NSEvent) { if dragging == nil { dock.hoverEnded() } }

    override func mouseMoved(with e: NSEvent) {
        let (a, c) = axes(convert(e.locationInWindow, from: nil))
        let top = gap + 2 * pad + (tiles.map(\.across).max() ?? S)
        if c > top { if hover != nil { dock.hoverEnded() }; return }
        if hover == nil { dock.hoverBegan() }
        hover = a
        layout(animated: false)
    }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { return rightMouseDown(with: e) }
        let p = convert(e.locationInWindow, from: nil)
        down = (tile(at: p), p)
        press(down?.tile, true)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = down, let t = d.tile, t.draggable else { return }
        let p = convert(e.locationInWindow, from: nil)
        if dragging == nil {
            guard hypot(p.x - d.point.x, p.y - d.point.y) > 5 else { return }
            dragging = t
            press(t, false)
            hover = nil
        }
        let (a, c) = axes(p)
        dragPos = CGPoint(x: a, y: c)
        let wasRemoving = removing
        removing = c > thickness + 50 && (t.pinned || t.kind != .app)
        if removing != wasRemoving { (removing ? NSCursor.disappearingItem : NSCursor.arrow).set() }
        // Live reorder: anything the user placed can go anywhere.
        if !removing, let from = tiles.firstIndex(where: { $0 === t }) {
            let slots = tiles.indices.filter { tiles[$0].draggable || tiles[$0] === t }
            if let to = slots.min(by: { abs(tiles[$0].base - a) < abs(tiles[$1].base - a) }), to != from {
                tiles.insert(tiles.remove(at: from), at: to)
            }
        }
        layout(animated: true)
    }

    override func mouseUp(with e: NSEvent) {
        defer { down = nil }
        press(down?.tile, false)
        if let t = dragging {
            let wasRemoving = removing
            dragging = nil; removing = false
            NSCursor.arrow.set()
            if wasRemoving, let w = window {
                NSAnimationEffect.poof.show(centeredAt: w.convertPoint(toScreen: e.locationInWindow), size: .zero)
            }
            dock.commitDrag(t, removed: wasRemoving)
            if !(window?.frame.contains(NSEvent.mouseLocation) ?? false) { dock.hoverEnded() }
            return
        }
        let p = convert(e.locationInWindow, from: nil)
        if let t = down?.tile, tile(at: p) === t {
            dock.click(t, e.modifierFlags, at: (axes(p).along - (t.center - t.size / 2)) / max(t.size, 1))
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        dock.showMenu(for: tile(at: p), at: p)
    }

    override func scrollWheel(with e: NSEvent) {
        guard st.scrollCycles, let t = tile(at: convert(e.locationInWindow, from: nil)), t.app != nil else { return }
        scrollAccum += e.scrollingDeltaY + e.scrollingDeltaX
        if abs(scrollAccum) > (e.hasPreciseScrollingDeltas ? 30 : 1) {
            dock.cycleWindows(t, forward: scrollAccum < 0)
            scrollAccum = 0
        }
        if e.phase == .ended { scrollAccum = 0 }
    }

    // MARK: Drops from Finder and other apps

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        dock.hoverBegan()
        return draggingUpdated(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let urls = urls(info)
        guard !urls.isEmpty else { return [] }
        let p = convert(info.draggingLocation, from: nil)
        let a = axes(p).along
        let target = tile(at: p)
        let apps = urls.allSatisfy { $0.pathExtension == "app" }
        var op: NSDragOperation = []
        var newDrop: String?
        dock.trashShowsEject(target?.kind == .trash && urls.allSatisfy(Volumes.isEjectable))

        // Onto the middle of an app/folder/Trash acts on it; anywhere else opens a gap to place the item there.
        let onCenter = target.map { abs(a - $0.center) <= $0.size * 0.3 } ?? false
        let acts = target?.kind == .trash || (!apps && onCenter && (target?.kind == .app || target?.kind == .folder))
        if !acts {
            movePlaceholder(to: a)
            op = apps ? .copy : .link
        } else {
            removePlaceholder()
            switch target?.kind {
            case .trash: op = .move; newDrop = target?.key
            case .app: op = .copy; newDrop = target?.key
            case .folder: op = NSEvent.modifierFlags.contains(.option) ? .copy : .move; newDrop = target?.key
            default: op = .link
            }
        }
        if newDrop != dropKey { dropKey = newDrop; layout(animated: false) }
        return op
    }

    override func draggingExited(_ info: NSDraggingInfo?) { endDrop(); dock.hoverEnded() }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let urls = urls(info)
        let target = tile(at: convert(info.draggingLocation, from: nil))
        if let i = tiles.firstIndex(where: { $0.kind == .placeholder }) {
            let at = tiles[..<i].filter(\.pinned).count
            endDrop()
            dock.pin(urls, at: at)
        } else {
            endDrop()
            dock.drop(urls, onto: target, copy: NSEvent.modifierFlags.contains(.option))
        }
        return true
    }

    private func endDrop() {
        dropKey = nil
        dock.trashShowsEject(false)
        removePlaceholder()
        layout(animated: true)
    }

    private func movePlaceholder(to a: CGFloat) {
        let ph = tiles.first { $0.kind == .placeholder } ?? Tile(.placeholder, key: "placeholder")
        var rest = tiles.filter { $0 !== ph }
        rest.insert(ph, at: rest.firstIndex { $0.base > a } ?? rest.count)
        if rest.map(\.key) != tiles.map(\.key) { set(rest) }
    }

    private func removePlaceholder() {
        if tiles.contains(where: { $0.kind == .placeholder }) { set(tiles.filter { $0.kind != .placeholder }) }
    }

    // MARK: VoiceOver

    override func accessibilityChildren() -> [Any]? {
        tiles.filter(\.iconic).map { t in
            let el = TileAX { [weak self] in self?.dock.click(t, []) }
            el.setAccessibilityRole(.button)
            el.setAccessibilityLabel(t.title)
            el.setAccessibilityParent(self)
            el.setAccessibilityFrameInParentSpace(frame(of: t))
            return el
        }
    }
}

private final class TileAX: NSAccessibilityElement {
    let press: () -> Void
    init(_ press: @escaping () -> Void) { self.press = press; super.init() }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// Glass views take their corner radius as a property, not via the layer.
protocol GlassLike: AnyObject { var radius: CGFloat { get set } }

@available(macOS 26, *)
extension NSGlassEffectView: GlassLike {
    var radius: CGFloat { get { cornerRadius } set { cornerRadius = newValue } }
}

enum Volumes {
    static func isEjectable(_ u: URL) -> Bool {
        let v = try? u.resourceValues(forKeys: [.isVolumeKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey])
        return v?.isVolume == true && (v?.volumeIsEjectable == true || v?.volumeIsRemovable == true || v?.volumeIsInternal == false)
    }
}
