import AppKit

/// Pictures for fastfetch's image logo (Ghostty shows real images), drawn in the current theme's colours and redrawn
/// when the theme changes, into ~/.config/fastfetch/images. ~/.config/fastfetch/gallery holds a config per picture:
/// example 12's "System Information" text (saved as example12.jsonc) with that picture beside it.
enum FetchArt {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/fastfetch")
    static let names = ["orb", "rings", "waves", "moon", "pixelcat", "apple", "terminal", "halftone"]

    /// Draws every picture for the palette (512 × 512, transparent background).
    static func draw(_ p: Palette) {
        let images = dir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let c = Colors(p)
        for name in names {
            guard let img = Icons.draw(512, 512, { picture(name, c) }) else { continue }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: images.appendingPathComponent("\(name).png"))
        }
    }

    struct Colors {
        let accent, second, third, fg, bg, surface: NSColor
        init(_ p: Palette) {
            let sw = p.swatches.map { NSColor(hex: $0 + "FF") }
            accent = NSColor(hex: p.accent + "FF")
            let others = sw.filter { $0.hex.prefix(6).lowercased() != p.accent.lowercased() }
            second = others.first ?? accent
            third = others.count > 2 ? others[2] : others.last ?? accent
            fg = NSColor(hex: (p.termFg ?? p.fg) + "FF"); bg = NSColor(hex: p.bg + "FF"); surface = NSColor(hex: p.surface + "FF")
        }
    }

    private static func picture(_ name: String, _ c: Colors) {
        let S: CGFloat = 512, ctx = NSGraphicsContext.current!.cgContext
        switch name {
        case "orb":
            // A sphere lit from the top left, with a soft glow around it.
            ctx.setShadow(offset: .zero, blur: 60, color: c.accent.withAlphaComponent(0.7).cgColor)
            let r = NSRect(x: 76, y: 76, width: 360, height: 360)
            NSGradient(colors: [c.second, c.accent, c.accent.shadow(withLevel: 0.6) ?? c.accent])!
                .draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: 150, y: 300, width: 90, height: 50)).fill()
        case "rings":
            // A record: rings in the palette, a label in the middle.
            let cols = [c.accent, c.second, c.third, c.fg.withAlphaComponent(0.6)]
            for i in 0..<9 {
                let inset = CGFloat(i) * 22, path = NSBezierPath(ovalIn: NSRect(x: 40 + inset, y: 40 + inset, width: S - 80 - 2 * inset, height: S - 80 - 2 * inset))
                path.lineWidth = 10; cols[i % cols.count].setStroke(); path.stroke()
            }
            c.accent.setFill(); NSBezierPath(ovalIn: NSRect(x: 216, y: 216, width: 80, height: 80)).fill()
            c.bg.setFill(); NSBezierPath(ovalIn: NSRect(x: 246, y: 246, width: 20, height: 20)).fill()
        case "waves":
            // Synthwave: a sun cut by lines over stacked waves.
            NSGradient(colors: [c.second, c.accent])!.draw(in: NSBezierPath(ovalIn: NSRect(x: 136, y: 220, width: 240, height: 240)), angle: 90)
            c.bg.withAlphaComponent(0.0).setFill()
            for (i, y) in stride(from: 240, to: 340, by: 18).enumerated() {
                ctx.setBlendMode(.clear); ctx.fill(CGRect(x: 120, y: CGFloat(y), width: 280, height: CGFloat(3 + i))); ctx.setBlendMode(.normal)
            }
            for (i, col) in [c.accent, c.second, c.third, c.fg.withAlphaComponent(0.7)].enumerated() {
                let path = NSBezierPath(); let base = CGFloat(190 - i * 40)
                path.move(to: NSPoint(x: 0, y: base))
                for x in stride(from: 0, through: S, by: 4) { path.line(to: NSPoint(x: x, y: base + 18 * sin(x / 40 + CGFloat(i)))) }
                path.lineWidth = 7; path.lineCapStyle = .round; col.setStroke(); path.stroke()
            }
        case "moon":
            // A crescent and a scatter of stars.
            var g = SystemRandomNumberGenerator()
            for _ in 0..<40 {
                let s = CGFloat.random(in: 3...9, using: &g)
                c.fg.withAlphaComponent(CGFloat.random(in: 0.35...0.9, using: &g)).setFill()
                NSBezierPath(ovalIn: NSRect(x: .random(in: 20...490, using: &g), y: .random(in: 20...490, using: &g), width: s, height: s)).fill()
            }
            let moon = NSBezierPath(ovalIn: NSRect(x: 110, y: 110, width: 300, height: 300))
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 40, color: c.accent.withAlphaComponent(0.6).cgColor)
            NSGradient(colors: [c.accent, c.second])!.draw(in: moon, angle: -45)
            ctx.restoreGState()
            ctx.setBlendMode(.clear); NSBezierPath(ovalIn: NSRect(x: 190, y: 170, width: 290, height: 290)).fill(); ctx.setBlendMode(.normal)
        case "pixelcat":
            // 16 × 16 pixel art: a cat, accent body, second-colour eyes.
            let art = ["................", "..X..........X..", ".XXX........XXX.", ".XXXX......XXXX.", ".XXXXXXXXXXXXXX.", "XXXXXXXXXXXXXXXX", "XXXEEXXXXXXEEXXX",
                       "XXXEEXXXXXXEEXXX", "XXXXXXXNNXXXXXXX", "XXXXXXXXXXXXXXXX", ".XXXXWXXXXWXXXX.", "..XXXXWWWWXXXX..", "...XXXXXXXXXX...", "....XXXXXXXX....",
                       ".....XXXXXX.....", "................"]
            let px = S / 16
            for (row, line) in art.enumerated() {
                for (col, ch) in line.enumerated() where ch != "." {
                    (ch == "E" ? c.second : ch == "N" ? c.third : ch == "W" ? c.fg : c.accent).setFill()
                    NSRect(x: CGFloat(col) * px, y: S - CGFloat(row + 1) * px, width: px, height: px).fill()
                }
            }
        case "apple":
            // The Apple logo filled with a gradient of the palette.
            guard let sym = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 360, weight: .regular)) else { return }
            let z = sym.size, r = NSRect(x: (S - z.width) / 2, y: (S - z.height) / 2, width: z.width, height: z.height)
            sym.draw(in: r)
            ctx.setBlendMode(.sourceAtop)
            NSGradient(colors: [c.accent, c.second, c.third])!.draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: -60)
            ctx.setBlendMode(.normal)
        case "terminal":
            // A little terminal window: traffic lights, a prompt, a cursor.
            let win = NSBezierPath(roundedRect: NSRect(x: 40, y: 90, width: 432, height: 330), xRadius: 30, yRadius: 30)
            c.surface.setFill(); win.fill()
            c.accent.withAlphaComponent(0.8).setStroke(); win.lineWidth = 6; win.stroke()
            for (i, col) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                col.setFill(); NSBezierPath(ovalIn: NSRect(x: 76 + CGFloat(i) * 40, y: 368, width: 24, height: 24)).fill()
            }
            let font = NSFont.monospacedSystemFont(ofSize: 54, weight: .bold)
            NSAttributedString(string: "~ »", attributes: [.font: font, .foregroundColor: c.accent]).draw(at: NSPoint(x: 80, y: 220))
            NSAttributedString(string: "_", attributes: [.font: font, .foregroundColor: c.second]).draw(at: NSPoint(x: 270, y: 220))
            NSAttributedString(string: "chaval", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 38, weight: .medium), .foregroundColor: c.fg.withAlphaComponent(0.6)])
                .draw(at: NSPoint(x: 80, y: 140))
        default: // halftone: dots that grow towards the bottom left, in the accent fading to the second colour
            for row in 0..<16 {
                for col in 0..<16 {
                    let t = CGFloat(row + col) / 30, d = 4 + 26 * (1 - t)
                    (t < 0.5 ? c.accent : c.second).withAlphaComponent(0.4 + 0.6 * (1 - t)).setFill()
                    let cx = CGFloat(col) * 32 + 16, cy = CGFloat(row) * 32 + 16
                    NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)).fill()
                }
            }
        }
    }

    /// Writes example12.jsonc (the text, unchanged) and one gallery config per picture (that text with the picture as its logo).
    static func writeGallery() {
        let fm = FileManager.default, gallery = dir.appendingPathComponent("gallery")
        try? fm.createDirectory(at: gallery, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("example12.jsonc")
        if !fm.fileExists(atPath: base.path) {
            try? fm.copyItem(atPath: "/opt/homebrew/share/fastfetch/presets/examples/12.jsonc", toPath: base.path)
        }
        guard let text = try? String(contentsOf: base, encoding: .utf8) else { return }
        let images = dir.appendingPathComponent("images").path
        for name in names + ["album", "ghostty"] {
            let logo = "\"logo\": {\n        \"type\": \"kitty-direct\",\n        \"source\": \"\(images)/\(name).png\",\n        \"width\": 34,\n        \"height\": 17,\n        \"padding\": { \"top\": 2, \"right\": 3 }\n    },"
            let out = text.replacingOccurrences(of: #""logo": \{\s*"type": "none"\s*\},"#, with: logo, options: .regularExpression)
            try? out.write(to: gallery.appendingPathComponent("\(name).jsonc"), atomically: true, encoding: .utf8)
        }
        // Ghostty's own icon, once.
        let ghostty = dir.appendingPathComponent("images/ghostty.png")
        if !fm.fileExists(atPath: ghostty.path), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            if let cg = Icons.draw(512, 512, { icon.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512)) }) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: ghostty)
            }
        }
    }
}
