import SwiftUI
import Carbon.HIToolbox

/// The front app's menus drawn in Chaval's theme, in place of macOS's. Items are read from the app over Accessibility
/// (title, enabled, checkmark, shortcut, submenu) and choosing one presses it there, as the real menu would.
/// Some apps fill parts of a menu only as the real one opens (a Window menu's window list, Open Recent); those can be
/// missing or stale here. Settings → Top Bar can switch back to the real menus.
final class ChavalMenu {
    static let shared = ChavalMenu()

    struct Item: Identifiable {
        let id: Int
        let el: AXUIElement
        let title: String
        let enabled: Bool
        let mark: String
        let shortcut: String
        let submenu: Bool
        var separator: Bool { title.isEmpty }
    }

    /// One open level: the top menu, or a submenu beside its parent row.
    fileprivate final class Level {
        let panel: NSPanel
        let model: MenuModel
        init(_ p: NSPanel, _ m: MenuModel) { panel = p; model = m }
    }

    private var levels: [Level] = []
    private var monitors: [Any] = []
    private(set) var openTitle: String?
    var isOpen: Bool { !levels.isEmpty }

    /// Opens `menu` (a menu bar item) hanging under `anchor` (its rect on screen).
    func open(_ menu: AXUIElement, title: String, anchor: NSRect) {
        close()
        openTitle = title
        DispatchQueue.global(qos: .userInteractive).async {
            let items = ChavalMenu.read(menu)
            DispatchQueue.main.async {
                guard self.openTitle == title else { return }
                guard !items.isEmpty else { self.openTitle = nil; MenuExtras.press(menu); return } // nothing readable: the real menu
                self.push(items, at: NSPoint(x: anchor.minX, y: anchor.minY - 4), beside: nil)
                self.watch()
            }
        }
    }

    func close() {
        levels.forEach { $0.panel.orderOut(nil) }
        levels = []
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        openTitle = nil
    }

    func owns(_ w: NSWindow?) -> Bool { levels.contains { $0.panel === w } }

    // MARK: Reading

    /// The items of a menu bar item or menu item: its AXMenu child's children.
    static func read(_ parent: AXUIElement) -> [Item] {
        guard let menu = AX.children(parent).first else { return [] }
        AXUIElementSetMessagingTimeout(menu, 0.3)
        return AX.children(menu).enumerated().map { i, el in
            let title: String = AX.get(el, kAXTitleAttribute) ?? ""
            let char: String = AX.get(el, kAXMenuItemCmdCharAttribute) ?? ""
            let glyph: Int = AX.get(el, kAXMenuItemCmdGlyphAttribute) ?? 0
            let mods: Int = AX.get(el, kAXMenuItemCmdModifiersAttribute) ?? 0
            let key = char.isEmpty ? glyphs[glyph] ?? "" : keyName(char)
            var shortcut = ""
            if !key.isEmpty {
                if mods & 4 != 0 { shortcut += "⌃" }
                if mods & 2 != 0 { shortcut += "⌥" }
                if mods & 1 != 0 { shortcut += "⇧" }
                if mods & 8 == 0 { shortcut += "⌘" }
                shortcut += key
            }
            return Item(id: i, el: el, title: title, enabled: AX.get(el, kAXEnabledAttribute) ?? true,
                        mark: AX.get(el, kAXMenuItemMarkCharAttribute) ?? "", shortcut: shortcut,
                        submenu: !(AX.children(el).isEmpty))
        }
    }

    /// A shortcut's key as shown: control and function-key characters (which draw as boxes) by their symbols.
    private static func keyName(_ c: String) -> String {
        guard let u = c.unicodeScalars.first?.value else { return c }
        switch u {
        case 0x08, 0x7F: return "⌫"
        case 0xF728: return "⌦"
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x09: return "⇥"
        case 0x20: return "Space"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF70F: return "F\(u - 0xF704 + 1)"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0..<0x20: return ""
        default: return c.uppercased()
        }
    }

    /// Menu glyph codes (Carbon's kMenu…Glyph) for keys without a character.
    private static let glyphs: [Int: String] = [
        0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "␣", 0x0A: "⌦", 0x0B: "↩", 0x17: "⌫", 0x1B: "⎋",
        0x64: "←", 0x65: "→", 0x68: "↑", 0x6A: "↓", 0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5",
        0x74: "F6", 0x75: "F7", 0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
    ]

    // MARK: Levels

    private func push(_ items: [Item], at topLeft: NSPoint, beside parent: NSRect?) {
        let m = MenuModel(items: items, depth: levels.count)
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2) // above the bar
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: MenuView(model: m).environmentObject(Store.shared))
        p.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.screens[0]
        var x = topLeft.x
        if let parent, x + size.width > screen.visibleFrame.maxX { x = parent.minX - size.width + 4 } // no room on the right: open left
        x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        let y = max(topLeft.y - size.height, screen.visibleFrame.minY + 4)
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        m.choose = { [weak self] item, rowRect in self?.choose(item, rowRect: rowRect, level: m.depth) }
        m.hover = { [weak self] item, rowRect in self?.hovered(item, rowRect: rowRect, level: m.depth) }
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; p.animator().alphaValue = 1 }
        levels.append(Level(p, m))
    }

    /// Rows are reported top-left based within their panel (SwiftUI's global frame); this puts one on screen.
    private func screenRect(_ r: NSRect, level: Int) -> NSRect {
        guard levels.indices.contains(level) else { return r }
        let f = levels[level].panel.frame
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    private var subWork: DispatchWorkItem?

    private func hovered(_ item: Item?, rowRect: NSRect, level: Int) {
        subWork?.cancel()
        guard levels.indices.contains(level) else { return }
        // Moving within a level closes deeper submenus, unless it's onto the row that opened them.
        if let item, item.submenu, item.enabled {
            let r = screenRect(rowRect, level: level)
            let w = DispatchWorkItem { [weak self] in self?.openSub(item, row: r, level: level) }
            subWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        } else if levels.count > level + 1 {
            let w = DispatchWorkItem { [weak self] in self?.trim(to: level + 1) }
            subWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }
    }

    private func openSub(_ item: Item, row: NSRect, level: Int) {
        trim(to: level + 1)
        let items = ChavalMenu.read(item.el)
        guard !items.isEmpty else { return }
        push(items, at: NSPoint(x: row.maxX - 2, y: row.maxY + 6), beside: row)
    }

    private func trim(to n: Int) {
        while levels.count > n { levels.removeLast().panel.orderOut(nil) }
        levels.last?.panel.makeKey()
    }

    private func choose(_ item: Item, rowRect: NSRect, level: Int) {
        guard item.enabled, !item.separator else { return }
        if item.submenu { return openSub(item, row: screenRect(rowRect, level: level), level: level) }
        close()
        MenuExtras.press(item.el)
    }

    // MARK: Events

    private func watch() {
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() } as Any,
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e } as Any,
        ]
    }

    private func key(_ e: NSEvent) -> NSEvent? {
        guard let top = levels.last else { return e }
        switch Int(e.keyCode) {
        case kVK_Escape: levels.count > 1 ? trim(to: levels.count - 1) : close()
        case kVK_DownArrow: top.model.move(1)
        case kVK_UpArrow: top.model.move(-1)
        case kVK_LeftArrow: if levels.count > 1 { trim(to: levels.count - 1) }
        case kVK_RightArrow, kVK_Return, kVK_ANSI_KeypadEnter:
            if let i = top.model.selected, top.model.items.indices.contains(i) {
                let item = top.model.items[i], r = top.model.rects[i] ?? .zero
                if Int(e.keyCode) == kVK_RightArrow { if item.submenu { openSub(item, row: screenRect(r, level: levels.count - 1), level: levels.count - 1) } }
                else { choose(item, rowRect: r, level: levels.count - 1) }
            }
        default: return e
        }
        return nil
    }

    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

    /// Diagnostic for `--render-menu TITLE FILE`: the front app's menu of that title, drawn off screen.
    static func render(_ title: String, to path: String) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let m = MenuExtras.appMenus(app).first(where: { $0.title == title }) else { return }
        let model = MenuModel(items: read(m.el), depth: 0)
        model.selected = model.items.first { $0.enabled && !$0.separator }?.id
        let v = NSHostingView(rootView: MenuView(model: model).environmentObject(Store.shared))
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = v
        v.frame.size = v.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

final class MenuModel: ObservableObject {
    let items: [ChavalMenu.Item]
    let depth: Int
    @Published var selected: Int?
    var rects: [Int: NSRect] = [:] // each row, top-left based within the panel
    var choose: (ChavalMenu.Item, NSRect) -> Void = { _, _ in }
    var hover: (ChavalMenu.Item?, NSRect) -> Void = { _, _ in }
    init(items: [ChavalMenu.Item], depth: Int) { self.items = items; self.depth = depth }

    /// The next enabled item up or down (separators and greyed items skipped).
    func move(_ d: Int) {
        let usable = items.indices.filter { items[$0].enabled && !items[$0].separator }
        guard !usable.isEmpty else { return }
        guard let cur = selected, let at = usable.firstIndex(of: cur) else { selected = d > 0 ? usable.first : usable.last; return }
        selected = usable[(at + d + usable.count) % usable.count]
        if let s = selected { hover(items[s], rects[s] ?? .zero) }
    }
}

private struct MenuView: View {
    @ObservedObject var model: MenuModel
    @EnvironmentObject var store: Store
    private var s: DashStyle { DashStyle(t: store.bar.theme) }

    var body: some View {
        let t = store.bar.theme
        VStack(alignment: .leading, spacing: 1) {
            ForEach(model.items) { item in
                if item.separator {
                    Rectangle().fill(s.fg.opacity(0.12)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
                } else {
                    row(item)
                }
            }
        }
        .padding(5)
        .frame(minWidth: 220)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: max(t.pillCorner, 10)).fill(Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(max(NSColor(hex: t.bgHex).alphaComponent, 0.97)))))
        .overlay(RoundedRectangle(cornerRadius: max(t.pillCorner, 10)).stroke(Color(nsColor: NSColor(hex: t.borderHex)), lineWidth: t.border ? 1 : 0))
        .clipShape(RoundedRectangle(cornerRadius: max(t.pillCorner, 10)))
    }

    private func row(_ item: ChavalMenu.Item) -> some View {
        let on = model.selected == item.id && item.enabled
        return HStack(spacing: 6) {
            Text(item.mark.isEmpty ? " " : "✓").font(s.font(11, .bold)).frame(width: 12)
            Text(item.title).font(s.font(12, on ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 18)
            if !item.shortcut.isEmpty { Text(item.shortcut).font(s.font(11)).opacity(on ? 0.9 : 0.5) }
            if item.submenu { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.7) }
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: max(min(store.bar.theme.pillCorner, 8), 4)).fill(on ? s.accent : .clear))
        .foregroundStyle(on ? s.onAccent : s.fg)
        .opacity(item.enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .background(GeometryReader { g in Color.clear.onAppear { model.rects[item.id] = g.frame(in: .global) } })
        .onHover { inside in
            guard inside else { return }
            model.selected = item.id
            model.hover(item, model.rects[item.id] ?? .zero)
        }
        .onTapGesture { model.choose(item, model.rects[item.id] ?? .zero) }
    }
}
