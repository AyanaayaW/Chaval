import AppKit
import QuickLookThumbnailing

// MARK: - Icons (rendered once at the exact pixel size the layer needs)

enum Icons {
    private static var cache: [String: CGImage] = [:]
    private static let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
    static let trashEmpty = coreTypes + "TrashIcon.icns"
    static let trashFull = coreTypes + "FullTrashIcon.icns"
    static let eject = coreTypes + "EjectMediaIcon.icns"

    static func clear() { cache.removeAll() }
    static func forget(_ path: String) { cache = cache.filter { !$0.key.hasPrefix(path + "#") } }

    static func icon(_ path: String, px: Int) -> CGImage? {
        let custom = Store.shared.iconStyles[path]?.image
        let tint = tint(for: path)
        let key = "\(path)#\(px)#\(custom ?? "")#\(tint?.hex ?? "")"
        if let c = cache[key] { return c }
        let source = custom.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? path
        let img: NSImage
        if source != path || path.hasSuffix(".icns"), !source.hasSuffix(".app"), let i = NSImage(contentsOfFile: source) { img = i }
        else if FileManager.default.fileExists(atPath: source) { img = NSWorkspace.shared.icon(forFile: source) }
        else { img = NSWorkspace.shared.icon(for: .applicationBundle) } // missing item; drawn faded by caller
        let c = draw(px) { img.draw(in: fitted(img.size, px)) }.flatMap { tinted($0, tint) }
        cache[key] = c
        return c
    }

    /// Custom images keep their aspect ratio inside the square.
    private static func fitted(_ size: NSSize, _ px: Int) -> NSRect {
        let s = CGFloat(px), scale = s / max(size.width, size.height, 1)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
    }

    static func tint(for path: String) -> NSColor? {
        let st = Store.shared.settings
        switch Store.shared.iconStyles[path]?.tintHex {
        case nil: return st.iconTint ? NSColor(hex: st.iconTintHex) : nil
        case ""?: return nil
        case let hex?: return NSColor(hex: hex)
        }
    }

    /// Colorize keeps the icon's shading and swaps its hue (like tinted iOS icons); wash lays the colour over it.
    static func tinted(_ img: CGImage, _ color: NSColor?) -> CGImage? {
        guard let color else { return img }
        let st = Store.shared.settings
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: r)
        ctx.setBlendMode(st.iconTintMode == .colorize ? .color : .sourceAtop)
        ctx.setFillColor(color.withAlphaComponent(st.iconTintStrength).cgColor)
        ctx.fill(r)
        if st.iconTintMode == .colorize { ctx.setBlendMode(.destinationIn); ctx.draw(img, in: r) } // restore the icon's silhouette
        return ctx.makeImage()
    }

    /// Folder shown "as Stack": the newest items piled on top of each other.
    static func stack(_ item: Item, px: Int) -> CGImage? {
        let top = Folder.contents(item.url, item.sort).prefix(3).reversed()
        if top.isEmpty { return icon(item.path, px: px) }
        let tint = tint(for: item.path)
        let key = "\(item.path)#stack\(item.sort)\(top.map(\.path).joined())#\(px)#\(tint?.hex ?? "")"
        if let c = cache[key] { return c }
        let c = draw(px) {
            let s = CGFloat(px), ctx = NSGraphicsContext.current!.cgContext
            for (i, url) in top.enumerated() {
                ctx.saveGState()
                ctx.translateBy(x: s / 2, y: s / 2)
                ctx.rotate(by: CGFloat([-0.12, 0.09, 0][3 - top.count + i]))
                NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: -s * 0.42, y: -s * 0.42, width: s * 0.84, height: s * 0.84))
                ctx.restoreGState()
            }
        }.flatMap { tinted($0, tint) }
        cache = cache.filter { !$0.key.hasPrefix(item.path + "#stack") }
        cache[key] = c
        return c
    }

    static func selfTest() {
        // Left half opaque red, right half transparent.
        let img = draw(4) { NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 4).fill() }!
        let out = tinted(img, .blue)!
        var px = [UInt8](repeating: 0, count: 16 * 4)
        let ctx = CGContext(data: &px, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(out, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        assert(px[3] == 255 && px[2] > px[0], "opaque pixel turns blue")
        assert(px[3 * 4 + 3] == 0, "transparent pixel stays transparent")
        print("tint selftest ok")
    }

    static func draw(_ px: Int, _ draw: () -> Void) -> CGImage? { self.draw(px, px, draw) }

    static func draw(_ w: Int, _ h: Int, _ draw: () -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - Folder contents

enum Folder {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey,
                                                 .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey]

    static func contents(_ dir: URL, _ sort: StackSort) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        func date(_ u: URL, _ k: URLResourceKey) -> Date {
            let v = try? u.resourceValues(forKeys: [k])
            return (k == .addedToDirectoryDateKey ? v?.addedToDirectoryDate : k == .creationDateKey ? v?.creationDate : v?.contentModificationDate) ?? .distantPast
        }
        switch sort {
        case .name: return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .dateAdded: return urls.sorted { date($0, .addedToDirectoryDateKey) > date($1, .addedToDirectoryDateKey) }
        case .dateModified: return urls.sorted { date($0, .contentModificationDateKey) > date($1, .contentModificationDateKey) }
        case .dateCreated: return urls.sorted { date($0, .creationDateKey) > date($1, .creationDateKey) }
        case .kind:
            func kind(_ u: URL) -> String { (try? u.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "" }
            return urls.sorted { (kind($0), $0.lastPathComponent) < (kind($1), $1.lastPathComponent) }
        }
    }

    static func isDir(_ u: URL) -> Bool {
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    static func name(_ u: URL) -> String { FileManager.default.displayName(atPath: u.path) }
}

// MARK: - List view: a native menu, lazily filled so deep folders cost nothing until opened

final class FolderMenu: NSMenu, NSMenuDelegate {
    let url: URL, sort: StackSort

    init(_ url: URL, sort: StackSort) {
        self.url = url; self.sort = sort
        super.init(title: Folder.name(url))
        delegate = self
    }
    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        addItem(Menu.item("Open in Finder") { [url] in NSWorkspace.shared.open(url) })
        addItem(.separator())
        for u in Folder.contents(url, sort) {
            let mi = Menu.item(Folder.name(u)) { NSWorkspace.shared.open(u) }
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            if Folder.isDir(u) { mi.submenu = FolderMenu(u, sort: sort) }
            addItem(mi)
        }
    }
}

enum Menu {
    private final class Action: NSObject {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        @objc func run() { f() }
    }

    static func item(_ title: String, checked: Bool = false, _ f: @escaping () -> Void) -> NSMenuItem {
        let a = Action(f)
        let mi = NSMenuItem(title: title, action: #selector(Action.run), keyEquivalent: "")
        mi.target = a
        mi.representedObject = a // menu items hold targets weakly
        mi.state = checked ? .on : .off
        return mi
    }

    static func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = NSMenu(title: title)
        items.forEach { mi.submenu!.addItem($0) }
        return mi
    }
}

// MARK: - Fan and grid views

final class StackPanel: NSPanel {
    static var current: StackPanel?

    private var monitors: [Any] = []
    private var trail: [URL] = []
    private let item: Item, edge: Edge, anchor: NSRect, bar: NSRect
    private let onClose: () -> Void

    /// anchor: the tile's screen rect; bar: the dock bar's screen rect.
    static func show(_ item: Item, view: StackView, anchor: NSRect, bar: NSRect, edge: Edge, onClose: @escaping () -> Void) {
        current?.close()
        let p = StackPanel(item, anchor: anchor, bar: bar, edge: edge, onClose: onClose)
        let urls = Folder.contents(item.url, item.sort)
        let fan = view == .fan || (view == .auto && urls.count <= 12)
        if fan && edge == .bottom && urls.count <= 12 { p.buildFan(urls) } else { p.push(item.url) }
        current = p
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
    }

    private init(_ item: Item, anchor: NSRect, bar: NSRect, edge: Edge, onClose: @escaping () -> Void) {
        self.item = item; self.edge = edge; self.anchor = anchor; self.bar = bar; self.onClose = onClose
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        let close: (NSEvent) -> Void = { [weak self] _ in self?.close() }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: close) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if e.window !== self { self?.close() }
            return e
        } as Any)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        guard StackPanel.current === self else { return }
        StackPanel.current = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        super.close()
        onClose()
    }

    private func place(_ size: NSSize) {
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var o: NSPoint
        switch edge {
        case .bottom: o = NSPoint(x: anchor.midX - size.width / 2, y: bar.maxY + 8)
        case .top: o = NSPoint(x: anchor.midX - size.width / 2, y: bar.minY - 8 - size.height)
        case .left: o = NSPoint(x: bar.maxX + 8, y: anchor.midY - size.height / 2)
        case .right: o = NSPoint(x: bar.minX - 8 - size.width, y: anchor.midY - size.height / 2)
        }
        o.x = min(max(o.x, vf.minX + 4), vf.maxX - size.width - 4)
        o.y = min(max(o.y, vf.minY + 4), vf.maxY - size.height - 4)
        setFrame(NSRect(origin: o, size: size), display: true)
    }

    // Fan: items rise from the icon along a gentle curve, nearest item first.
    private func buildFan(_ urls: [URL]) {
        let rowH: CGFloat = 50, iconMid: CGFloat = 258 // cell.x 10 + icon centre 248
        func curve(_ i: Int) -> CGFloat { 0.5 * CGFloat(i * i) }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 290 + curve(urls.count), height: rowH * CGFloat(urls.count + 1) + 8))
        for (i, u) in urls.enumerated() {
            let cell = Cell(u, style: .fan) { [weak self] in self?.activate(u, navigate: false) }
            cell.frame = NSRect(x: 10 + curve(i), y: CGFloat(i) * rowH, width: 270, height: rowH)
            root.addSubview(cell)
        }
        let finder = Pill("Open in Finder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.item.url); self.close()
        }
        finder.sizeToFit()
        finder.setFrameOrigin(NSPoint(x: min(iconMid + curve(urls.count) - finder.frame.width / 2, root.frame.width - finder.frame.width),
                                      y: CGFloat(urls.count) * rowH + 10))
        root.addSubview(finder)
        contentView = root
        let size = root.frame.size
        var o = NSPoint(x: anchor.midX - iconMid, y: bar.maxY + 6)
        if let vf = (NSScreen.screens.first { $0.frame.intersects(anchor) })?.visibleFrame {
            o.x = min(max(o.x, vf.minX), vf.maxX - size.width)
        }
        setFrame(NSRect(origin: o, size: size), display: true)
    }

    // Grid: scrollable, folders open in place with a back button.
    private func push(_ url: URL) {
        trail.append(url)
        let urls = Folder.contents(url, item.sort)
        let cols = max(1, min(urls.count, 6)), cell = NSSize(width: 96, height: 96), header: CGFloat = 40
        let rows = Int(ceil(Double(urls.count) / Double(cols)))
        let docH = max(CGFloat(rows) * cell.height, cell.height)
        let size = NSSize(width: CGFloat(cols) * cell.width + 24, height: min(docH, cell.height * 4.5) + header + 16)

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow; bg.state = .active; bg.blendingMode = .behindWindow
        bg.wantsLayer = true; bg.layer?.cornerRadius = 16; bg.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: Folder.name(url))
        title.font = .boldSystemFont(ofSize: 15)
        title.frame = NSRect(x: 44, y: size.height - 32, width: size.width - 170, height: 20)
        bg.addSubview(title)
        if trail.count > 1 {
            let back = Pill("‹") { [weak self] in
                guard let self else { return }
                self.trail.removeLast(); let prev = self.trail.removeLast(); self.push(prev)
            }
            back.frame = NSRect(x: 10, y: size.height - 34, width: 28, height: 24)
            bg.addSubview(back)
        }
        let finder = Pill("Open in Finder") { [weak self] in NSWorkspace.shared.open(url); self?.close() }
        finder.sizeToFit()
        finder.setFrameOrigin(NSPoint(x: size.width - finder.frame.width - 12, y: size.height - 34))
        bg.addSubview(finder)

        let doc = Flipped(frame: NSRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: docH))
        for (i, u) in urls.enumerated() {
            let c = Cell(u, style: .grid) { [weak self] in self?.activate(u, navigate: true) }
            c.frame = NSRect(x: CGFloat(i % cols) * cell.width, y: CGFloat(i / cols) * cell.height, width: cell.width, height: cell.height)
            doc.addSubview(c)
        }
        if urls.isEmpty {
            let empty = NSTextField(labelWithString: "No items")
            empty.textColor = .secondaryLabelColor
            empty.sizeToFit()
            empty.setFrameOrigin(NSPoint(x: (doc.frame.width - empty.frame.width) / 2, y: 36))
            doc.addSubview(empty)
        }
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 8, width: size.width - 24, height: size.height - header - 16))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = docH > scroll.frame.height
        scroll.documentView = doc
        bg.addSubview(scroll)
        contentView = bg
        place(size)
    }

    private func activate(_ url: URL, navigate: Bool) {
        if navigate && Folder.isDir(url) { push(url); return }
        NSWorkspace.shared.open(url)
        close()
    }
}

private final class Flipped: NSView { override var isFlipped: Bool { true } }

private final class Pill: NSButton {
    private let f: () -> Void
    init(_ title: String, _ f: @escaping () -> Void) {
        self.f = f
        super.init(frame: .zero)
        self.title = title; bezelStyle = .push; controlSize = .small
        target = self; action = #selector(run)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { f() }
}

/// One file in a fan or grid. Click opens, drag carries the file out.
private final class Cell: NSView, NSDraggingSource {
    enum Style { case fan, grid }
    let url: URL
    private let onClick: () -> Void
    private let image = NSImageView()
    private let label: NSTextField
    private var down: NSPoint?

    init(_ url: URL, style: Style, onClick: @escaping () -> Void) {
        self.url = url; self.onClick = onClick
        label = NSTextField(labelWithString: Folder.name(url))
        super.init(frame: .zero)
        wantsLayer = true
        image.image = NSWorkspace.shared.icon(forFile: url.path)
        image.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .white
        switch style {
        case .grid:
            image.frame = NSRect(x: 20, y: 34, width: 56, height: 56)
            label.frame = NSRect(x: 2, y: 2, width: 92, height: 30)
            label.alignment = .center; label.maximumNumberOfLines = 2; label.font = .systemFont(ofSize: 11)
            label.cell?.wraps = true
        case .fan:
            image.frame = NSRect(x: 226, y: 3, width: 44, height: 44)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.sizeToFit()
            let w = min(label.frame.width + 16, 210)
            let pill = NSView(frame: NSRect(x: 218 - w, y: 14, width: w, height: 22))
            pill.wantsLayer = true; pill.layer?.cornerRadius = 11
            pill.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
            label.frame = NSRect(x: 8, y: 3, width: w - 16, height: 16)
            pill.addSubview(label)
            addSubview(pill)
        }
        addSubview(image)
        if style == .grid { addSubview(label) }
        thumbnail()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func thumbnail() {
        guard !Folder.isDir(url), url.pathExtension != "app" else { return }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.image.image = img }
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor; layer?.cornerRadius = 10 }
    override func mouseExited(with e: NSEvent) { layer?.backgroundColor = nil }
    override func mouseDown(with e: NSEvent) { down = e.locationInWindow }
    override func mouseUp(with e: NSEvent) { if down != nil { down = nil; onClick() } }
    override func mouseDragged(with e: NSEvent) {
        guard let d = down, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
        down = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(image.frame, contents: image.image)
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation {
        c == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        StackPanel.current?.close()
    }
}
