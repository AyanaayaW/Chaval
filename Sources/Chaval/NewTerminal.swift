import AppKit

/// ⌘Return, Omarchy's way: a new Ghostty window that's born on the tile it's going to, instead of opening wherever
/// Ghostty likes and then moving. Ghostty has no way to be told where to open a window except its config, so the tile
/// goes into ~/.config/ghostty/chaval-window (included by the user's config), Ghostty reloads it, then opens the window.
enum NewTerminal {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/chaval-window")
    private static let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/config")
    private static let queue = DispatchQueue(label: "chaval.newterminal", qos: .userInteractive)

    static func open() {
        let scr = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        if let r = Tiler.shared.nextTile(on: scr) { write(r, on: scr); Tiler.shared.expectWindow(on: scr) }
        queue.async {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").isEmpty else {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
                    NSWorkspace.shared.openApplication(at: app, configuration: .init())
                }
                return
            }
            _ = Script.run("""
            tell application "Ghostty"
                if (count of windows) > 0 then perform action "reload_config" on focused terminal of selected tab of front window
                new window
                activate
            end tell
            """)
        }
    }

    /// The tile as Ghostty wants it: position in points from the top left of the screen's visible area, size in cells.
    private static func write(_ r: CGRect, on s: NSScreen) {
        let top = NSScreen.screens.first?.frame.maxY ?? s.frame.maxY
        let visible = CGRect(x: s.visibleFrame.minX, y: top - s.visibleFrame.maxY, width: s.visibleFrame.width, height: s.visibleFrame.height)
        let (cell, pad) = metrics()
        let cols = max(10, Int((r.width - 2 * pad.width) / cell.width)), rows = max(4, Int((r.height - 2 * pad.height) / cell.height))
        let text = """
        # Written by Chaval for the next new window (⌘Return): it opens on its tile.
        window-position-x = \(Int(r.minX - visible.minX))
        window-position-y = \(Int(r.minY - visible.minY))
        window-width = \(cols)
        window-height = \(rows)

        """
        try? text.write(to: file, atomically: true, encoding: .utf8)
        includeOnce()
    }

    /// One cell of the user's Ghostty font, and the window padding, from their config (Ghostty's defaults otherwise).
    static func metrics() -> (cell: CGSize, pad: CGSize) {
        var family = "SF Mono", size: CGFloat = 13, bold = false, px: CGFloat = 2, py: CGFloat = 2
        for line in ((try? String(contentsOf: config, encoding: .utf8)) ?? "").split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "font-family": family = kv[1]
            case "font-size": size = CGFloat(Double(kv[1]) ?? 13)
            case "font-style": bold = kv[1].lowercased().contains("bold")
            case "window-padding-x": px = CGFloat(Double(kv[1].split(separator: ",").first ?? "") ?? 2)
            case "window-padding-y": py = CGFloat(Double(kv[1].split(separator: ",").first ?? "") ?? 2)
            default: break
            }
        }
        let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        return (CGSize(width: w, height: ceil(font.ascender - font.descender + font.leading)), CGSize(width: px, height: py))
    }

    /// Adds `config-file = ?chaval-window` to the user's Ghostty config the first time (optional, so it's harmless if missing).
    private static func includeOnce() {
        guard let text = try? String(contentsOf: config, encoding: .utf8), !text.contains("chaval-window") else { return }
        try? (text + (text.hasSuffix("\n") ? "" : "\n") + "config-file = ?chaval-window\n").write(to: config, atomically: true, encoding: .utf8)
    }

    static func selfTest() {
        let m = metrics()
        assert(m.cell.width > 4 && m.cell.width < 30 && m.cell.height > 8 && m.cell.height < 50, "a sane cell size")
        print(String(format: "newterminal selftest ok (cell %.2f × %.0f pt)", m.cell.width, m.cell.height))
    }
}
