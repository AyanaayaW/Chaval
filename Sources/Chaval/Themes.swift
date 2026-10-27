import AppKit

/// A colour theme applied everywhere at once: the top bar and its panel, the dock, window borders, Ghostty and tmux.
struct Palette: Identifiable, Equatable {
    let name: String
    let family: String
    let dark: Bool
    let bg: String       // RRGGBB
    let surface: String  // raised elements: sections, tiles
    let fg: String
    let accent: String
    let ghostty: String? // a theme bundled with Ghostty; nil = Chaval writes the colours (`ansi`)
    var ansi: [String] = [] // 16 colours, for themes Ghostty doesn't ship
    var termFg: String?     // terminal text when it differs from the UI text (Vesper's orange)
    var selection: String?

    var id: String { name }
    var swatches: [String] { ansi.count == 16 ? [1, 2, 3, 4, 5].map { ansi[$0] } : Themes.ghosttyPalette(ghostty ?? "").map { Array($0[1...5]) } ?? [accent] }

    static let all: [Palette] = {
        func p(_ n: String, _ f: String, _ d: Bool, _ bg: String, _ s: String, _ fg: String, _ a: String, _ g: String? = nil) -> Palette {
            Palette(name: n, family: f, dark: d, bg: bg, surface: s, fg: fg, accent: a, ghostty: g ?? n)
        }
        // Everforest: Ghostty ships two of the six, so all six are written from the official palette.
        func ever(_ n: String, dark: Bool, bg: String, bg1: String) -> Palette {
            let c = dark ? ["e67e80", "a7c080", "dbbc7f", "7fbbb3", "d699b6", "83c092"] : ["f85552", "8da101", "dfa000", "3a94c5", "df69ba", "35a77c"]
            let fg = dark ? "d3c6aa" : "5c6a72", grey = dark ? "859289" : "939f91"
            return Palette(name: n, family: "Everforest", dark: dark, bg: bg, surface: bg1, fg: fg, accent: c[1], ghostty: nil,
                           ansi: [dark ? "414b50" : "5c6a72"] + c + [fg, grey] + c + [fg])
        }
        return [
            // Vesper as the user's Ghostty had it: orange text on black.
            Palette(name: "Vesper", family: "Vesper", dark: true, bg: "101010", surface: "1c1c1c", fg: "ffffff", accent: "ffc799", ghostty: nil,
                    ansi: ["101010", "f5a191", "90b99f", "e6b99d", "aca1cf", "e29eca", "ea83a5", "a0a0a0",
                           "7e7e7e", "ff8080", "99ffe4", "ffc799", "b9aeda", "ecaad6", "f591b2", "c8c8c8"],
                    termFg: "ffc799", selection: "3a2f26"),
            ever("Everforest Dark Hard", dark: true, bg: "272e33", bg1: "2e383c"),
            ever("Everforest Dark Medium", dark: true, bg: "2d353b", bg1: "343f44"),
            ever("Everforest Dark Soft", dark: true, bg: "333c43", bg1: "3a464c"),
            ever("Everforest Light Hard", dark: false, bg: "fffbef", bg1: "f2efdf"),
            ever("Everforest Light Medium", dark: false, bg: "fdf6e3", bg1: "efebd4"),
            ever("Everforest Light Soft", dark: false, bg: "f3ead3", bg1: "e5dfc5"),
            p("Catppuccin Mocha", "Catppuccin", true, "1e1e2e", "313244", "cdd6f4", "cba6f7"),
            p("Catppuccin Macchiato", "Catppuccin", true, "24273a", "363a4f", "cad3f5", "c6a0f6"),
            p("Catppuccin Frappé", "Catppuccin", true, "303446", "414559", "c6d0f5", "ca9ee6", "Catppuccin Frappe"),
            p("Catppuccin Latte", "Catppuccin", false, "eff1f5", "dce0e8", "4c4f69", "8839ef"),
            p("Rosé Pine", "Rosé Pine", true, "191724", "26233a", "e0def4", "ebbcba", "Rose Pine"),
            p("Rosé Pine Moon", "Rosé Pine", true, "232136", "393552", "e0def4", "ea9a97", "Rose Pine Moon"),
            p("Rosé Pine Dawn", "Rosé Pine", false, "faf4ed", "f2e9e1", "575279", "d7827e", "Rose Pine Dawn"),
            p("Tokyo Night", "Tokyo Night", true, "1a1b26", "24283b", "c0caf5", "7aa2f7", "TokyoNight Night"),
            p("Tokyo Night Storm", "Tokyo Night", true, "24283b", "2f354f", "c0caf5", "7aa2f7", "TokyoNight Storm"),
            p("Tokyo Night Moon", "Tokyo Night", true, "222436", "2f334d", "c8d3f5", "82aaff", "TokyoNight Moon"),
            p("Tokyo Night Day", "Tokyo Night", false, "e1e2e7", "d0d5e3", "3760bf", "2e7de9", "TokyoNight Day"),
            p("Nord", "Nord", true, "2e3440", "3b4252", "d8dee9", "88c0d0"),
            p("Nord Light", "Nord", false, "eceff4", "d8dee9", "2e3440", "5e81ac"),
            p("Gruvbox Dark", "Gruvbox", true, "282828", "3c3836", "ebdbb2", "fe8019"),
            p("Gruvbox Dark Hard", "Gruvbox", true, "1d2021", "32302f", "ebdbb2", "fe8019"),
            p("Gruvbox Material", "Gruvbox", true, "282828", "32302f", "d4be98", "d8a657", "Gruvbox Material Dark"),
            p("Gruvbox Light", "Gruvbox", false, "fbf1c7", "ebdbb2", "3c3836", "af3a03"),
            p("Gruvbox Light Hard", "Gruvbox", false, "f9f5d7", "ebdbb2", "3c3836", "af3a03"),
            p("Monokai Classic", "Monokai", true, "272822", "3e3d32", "fdfff1", "a6e22e"),
            p("Monokai Pro", "Monokai", true, "2d2a2e", "403e41", "fcfcfa", "ffd866"),
            p("Monokai Pro Ristretto", "Monokai", true, "2c2525", "403838", "fff1f3", "f9cc6c"),
            p("Monokai Pro Spectrum", "Monokai", true, "222222", "363537", "f7f1ff", "fc618d"),
            p("Dracula", "Dracula", true, "282a36", "44475a", "f8f8f2", "bd93f9"),
            p("One Dark", "One Dark", true, "282c34", "2c313a", "abb2bf", "61afef", "Atom One Dark"),
            p("Solarized Dark", "Solarized", true, "002b36", "073642", "93a1a1", "b58900", "iTerm2 Solarized Dark"),
            p("Solarized Light", "Solarized", false, "fdf6e3", "eee8d5", "586e75", "cb4b16", "iTerm2 Solarized Light"),
            p("Kanagawa Wave", "Kanagawa", true, "1f1f28", "2a2a37", "dcd7ba", "7e9cd8"),
            p("Kanagawa Dragon", "Kanagawa", true, "181616", "282727", "c5c9c5", "8ba4b0"),
            p("Kanagawa Lotus", "Kanagawa", false, "f2ecbc", "e5ddb0", "545464", "4d699b"),
            p("Ayu Dark", "Ayu", true, "0b0e14", "131721", "bfbdb6", "e6b450", "Ayu"),
            p("Ayu Mirage", "Ayu", true, "1f2430", "242936", "cccac2", "ffcc66"),
            p("Ayu Light", "Ayu", false, "fcfcfc", "eef0f2", "5c6166", "fa8d3e"),
            p("GitHub Dark", "GitHub", true, "0d1117", "161b22", "e6edf3", "2f81f7", "GitHub Dark Default"),
            p("Night Owl", "Night Owl", true, "011627", "0b2942", "d6deeb", "82aaff"),
            p("Nightfox", "Nightfox", true, "192330", "212e3f", "cdcecf", "719cd6"),
            p("Oxocarbon", "Oxocarbon", true, "161616", "262626", "f2f4f8", "ff7eb6"),
        ]
    }()

    static var families: [String] { all.map(\.family).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
}

enum Themes {
    static var current: String? { UserDefaults.standard.string(forKey: "palette") }

    /// Applies a theme to everything Chaval styles, plus Ghostty and tmux.
    static func apply(_ p: Palette) {
        UserDefaults.standard.set(p.name, forKey: "palette")
        let store = Store.shared
        var bar = store.bar.theme
        bar.bgHex = p.bg + "F2"; bar.fgHex = p.fg + "FF"; bar.accentHex = p.accent + "FF"
        bar.pillHex = p.surface + "FF"; bar.borderHex = p.accent + "66"
        store.bar.theme = bar
        var s = store.settings
        s.tintHex = p.bg + "C8"; s.indicatorHex = p.accent + "FF"
        s.widgetBgHex = p.surface + "FF"; s.widgetTextHex = p.fg + "FF"
        s.look = p.dark ? .dark : .light
        s.iconTintHex = p.accent + "FF" // used when icon tinting is on (Appearance → Icon tint)
        if s.iconTint && s.iconTintStrength < 0.2 { s.iconTintStrength = 0.35 } // a tint too faint to see reads as "not following the theme"
        store.settings = s
        // Per-icon tints that are some theme's accent were set to match a theme, so they follow it; custom colours stay.
        let accents = Set(Palette.all.map { $0.accent.uppercased() })
        for (key, style) in store.iconStyles {
            guard let hex = style.tintHex, hex.count >= 6, accents.contains(String(hex.prefix(6)).uppercased()) else { continue }
            store.setTint(key, p.accent.uppercased() + "FF")
        }
        DispatchQueue.global(qos: .utility).async { ghostty(p); tmux(p); cava(p); fastfetch(p); clock(p); FetchArt.draw(p) }
        // The wallpaper picked last time for this theme's folder, else its first.
        let files = wallpapers(p)
        let saved = UserDefaults.standard.string(forKey: "wallpaper." + wallpaperFolder(p).lastPathComponent)
        if let w = files.first(where: { $0.path == saved }) ?? files.first { setWallpaper(w, for: p) }
    }

    static var palette: Palette { Palette.all.first { $0.name == current } ?? Palette.all[0] }

    /// ~/Documents/Wallpapers/<family>, or "<family> Light" for light variants.
    static func wallpaperFolder(_ p: Palette) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Wallpapers/" + p.family + (p.dark ? "" : " Light"))
    }

    static func wallpapers(_ p: Palette) -> [URL] {
        let exts: Set = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"]
        return ((try? FileManager.default.contentsOfDirectory(at: wallpaperFolder(p), includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func setWallpaper(_ url: URL, for p: Palette) {
        UserDefaults.standard.set(url.path, forKey: "wallpaper." + wallpaperFolder(p).lastPathComponent)
        for screen in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
        NotificationCenter.default.post(name: .chavalWallpaperChanged, object: nil)
    }

    // MARK: Ghostty

    private static let ghosttyThemes = "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/"
    private static var ghosttyDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty") }

    /// The 16 colours of a theme bundled with Ghostty, for previews.
    static func ghosttyPalette(_ name: String) -> [String]? {
        guard let text = try? String(contentsOfFile: ghosttyThemes + name, encoding: .utf8) else { return nil }
        var out = [String](repeating: "888888", count: 16)
        for line in text.split(separator: "\n") where line.hasPrefix("palette") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 3, let i = Int(parts[1]), out.indices.contains(i) { out[i] = parts[2].replacingOccurrences(of: "#", with: "") }
        }
        return out
    }

    /// Writes the colours to ~/.config/ghostty/chaval-theme, which the main config loads last (one line added, backup kept),
    /// so the theme wins over colours set in the config itself. Then asks Ghostty to reload.
    static func ghostty(_ p: Palette) {
        let fm = FileManager.default, config = ghosttyDir.appendingPathComponent("config")
        guard fm.fileExists(atPath: config.path) else { return }
        var colors: String
        if let g = p.ghostty, let text = try? String(contentsOfFile: ghosttyThemes + g, encoding: .utf8) {
            colors = text
        } else {
            colors = p.ansi.enumerated().map { "palette = \($0.offset)=#\($0.element)" }.joined(separator: "\n")
            let fg = p.termFg ?? p.fg
            colors += "\nbackground = #\(p.bg)\nforeground = #\(fg)\ncursor-color = #\(p.termFg ?? p.accent)\ncursor-text = #\(p.bg)"
            colors += "\nselection-background = #\(p.selection ?? p.surface)\nselection-foreground = #\(fg)\n"
        }
        // Six of the 256 colours hold the accent's gradient, so text drawn in them (fastfetch's name) follows the theme
        // even after it's printed: Ghostty repaints it when this file changes.
        let accentSlots = zip(accentSlotNumbers, accentGradient(p)).map { "palette = \($0)=#\($1)" }.joined(separator: "\n")
        let file = "# Written by Chaval (theme: \(p.name)). Pick themes in Chaval's dashboard; edits here are overwritten.\n"
            + colors + "\n" + accentSlots + "\nwindow-theme = \(p.dark ? "dark" : "light")\n"
        try? file.write(to: ghosttyDir.appendingPathComponent("chaval-theme"), atomically: true, encoding: .utf8)

        if var text = try? String(contentsOf: config, encoding: .utf8), !text.contains("config-file = ?chaval-theme") {
            let backup = ghosttyDir.appendingPathComponent("config.before-chaval")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: config, to: backup) }
            text += (text.hasSuffix("\n") ? "" : "\n") + "\n# Chaval's theme (colours only); remove this line to stop it.\nconfig-file = ?chaval-theme\n"
            try? text.write(to: config, atomically: true, encoding: .utf8)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").isEmpty else { return }
        Script.run("tell application \"Ghostty\" to perform action \"reload_config\" on terminal 1 of tab 1 of window 1")
    }

    // MARK: tmux

    private static var tmuxDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tmux") }

    /// At launch: the theme into the config files that may have been replaced since (cava's, fastfetch's, the clock's colour).
    static func refreshFiles() {
        guard let name = current, let p = Palette.all.first(where: { $0.name == name }) else { return }
        DispatchQueue.global(qos: .utility).async { ghostty(p); cava(p); fastfetch(p); clock(p); FetchArt.draw(p); FetchArt.writeGallery() }
    }

    // MARK: fastfetch

    /// Recolours ~/.config/fastfetch/config.jsonc in place (it has comments, so not parsed as JSON; backup kept): the
    /// colour values only, as true-colour codes from the theme. Labels and logo in the accent, the title in another of the
    /// theme's colours, separators dimmed, values in the text colour. Everything else in the file is left as it is.
    static func fastfetch(_ p: Palette) {
        let fm = FileManager.default, config = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/fastfetch/config.jsonc")
        guard var text = try? String(contentsOf: config, encoding: .utf8) else { return }
        let backup = config.deletingLastPathComponent().appendingPathComponent("config.jsonc.before-chaval")
        if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: config, to: backup) }
        func rgb(_ h: String) -> (Int, Int, Int) { let v = Int(h.prefix(6), radix: 16) ?? 0; return (v >> 16 & 255, v >> 8 & 255, v & 255) }
        func code(_ h: String) -> String { let c = rgb(h); return "38;2;\(c.0);\(c.1);\(c.2)" }
        let fg = p.termFg ?? p.fg, f = rgb(fg), b = rgb(p.bg)
        let dim = String(format: "%02x%02x%02x", (f.0 + b.0) / 2, (f.1 + b.1) / 2, (f.2 + b.2) / 2)
        let second = p.swatches.first { $0.lowercased() != p.accent.lowercased() } ?? fg
        // "key": "<colour>" pairs; only true-colour codes (38;2;…) are touched, so a style like example 12's bold
        // separator ("1") or a named colour ("red", which already follows the terminal's themed palette) is left alone.
        let pairs: [(String, String)] = [("keys", p.accent), ("title", second), ("separator", dim), ("output", fg), ("outputColor", dim),
                                        ("1", p.accent), ("2", second)]
        for (key, hex) in pairs {
            text = text.replacingOccurrences(of: "\"\(key)\": \"38;2;[0-9;]+\"", with: "\"\(key)\": \"\(code(hex))\"", options: .regularExpression)
        }
        fetchName(p)
        text = text.replacingOccurrences(of: "(?m)^  // (Vesper:.*|Colours written by Chaval.*)$", with: "  // Colours written by Chaval (theme: \(p.name)); pick themes in Chaval's dashboard.",
                                         options: .regularExpression)
        try? text.write(to: config, atomically: true, encoding: .utf8)
    }

    /// The 256-colour palette entries Chaval keeps for the accent's gradient (a run of the colour cube apps rarely ask for
    /// by number).
    static let accentSlotNumbers = Array(178...183)

    /// Six steps: the accent, through the theme colour nearest it in hue, to a light tint of the accent. One colour family
    /// for every theme (no detour through red because it happens to come next in the palette).
    static func accentGradient(_ p: Palette) -> [String] {
        func rgb(_ h: String) -> (Double, Double, Double) { let v = Int(h.prefix(6), radix: 16) ?? 0; return (Double(v >> 16 & 255), Double(v >> 8 & 255), Double(v & 255)) }
        func hue(_ h: String) -> CGFloat { NSColor(hex: String(h.prefix(6)) + "FF").usingColorSpace(.sRGB)?.hueComponent ?? 0 }
        func gap(_ a: CGFloat, _ b: CGFloat) -> CGFloat { let d = abs(a - b); return min(d, 1 - d) }
        let a = hue(p.accent)
        let near = Array(Set(p.swatches.map { $0.lowercased() }).subtracting([p.accent.lowercased()])).sorted { gap(hue($0), a) < gap(hue($1), a) }
        let ac = rgb(p.accent), t = rgb(p.termFg ?? p.fg)
        let stops = [ac] + near.prefix(1).map(rgb) + [((ac.0 + t.0) / 2, (ac.1 + t.1) / 2, (ac.2 + t.2) / 2)]
        return (0..<accentSlotNumbers.count).map { k in
            let x = Double(k) / Double(accentSlotNumbers.count - 1) * Double(stops.count - 1)
            let i = min(Int(x), stops.count - 2), f = x - Double(i), a = stops[i], b = stops[i + 1]
            return String(format: "%02x%02x%02x", Int(a.0 + (b.0 - a.0) * f), Int(a.1 + (b.1 - a.1) * f), Int(a.2 + (b.2 - a.2) * f))
        }
    }

    /// Your name in big letters (figlet) for fastfetch's logo, ~/.config/fastfetch/name.txt, coloured left to right with
    /// the accent slots: on screen it takes the current theme's accent, and changes with it, even after it's printed.
    static func fetchName(_ p: Palette) {
        let figlet = ["/opt/homebrew/bin/figlet", "/usr/local/bin/figlet"].first(where: FileManager.default.isExecutableFile)
        guard let figlet else { return }
        let lines = Script.shell(figlet, ["-f", "slant", NSUserName()]).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let width = max(lines.map(\.count).max() ?? 1, 1), n = accentSlotNumbers.count
        let art = lines.map { line in
            line.enumerated().map { i, ch in
                ch == " " ? " " : "\u{1B}[38;5;\(accentSlotNumbers[min(n - 1, i * n / width)])m" + String(ch)
            }.joined() + "\u{1B}[0m"
        }.joined(separator: "\n") + "\n"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/fastfetch")
        try? art.write(to: dir.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: cava

    /// Rewrites only the [color] section of ~/.config/cava/config (backup kept): a gradient from the theme's raised
    /// colour through its accent and terminal colours to its text, on the terminal's own background. Then asks a running
    /// cava to reload (SIGUSR1 re-reads the config).
    static func cava(_ p: Palette) {
        let fm = FileManager.default, config = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/cava/config")
        guard var text = try? String(contentsOf: config, encoding: .utf8) else { return }
        let backup = config.deletingLastPathComponent().appendingPathComponent("config.before-chaval")
        if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: config, to: backup) }
        let sw = p.swatches
        var stops: [String] = []
        for c in [p.surface, p.accent] + [sw[safe: 2], sw[safe: 4], sw[safe: 1]].compactMap({ $0 }) + [p.termFg ?? p.fg]
            where !stops.contains(where: { $0.lowercased() == c.lowercased() }) { stops.append(c) } // each colour once
        let color = "[color]\n# Written by Chaval (theme: \(p.name)); pick themes in Chaval's dashboard.\nbackground = default\nforeground = '#\(p.accent)'\ngradient = 1\n"
            + stops.enumerated().map { "gradient_color_\($0.offset + 1) = '#\($0.element)'" }.joined(separator: "\n") + "\n\n"
        // Replace from [color] up to the next section (or the end).
        if let start = text.range(of: "\n[color]") ?? text.range(of: "[color]") {
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n[")?.lowerBound ?? text.endIndex
            text.replaceSubrange(start.lowerBound..<end, with: (text[start].hasPrefix("\n") ? "\n" : "") + color.dropLast())
        } else { text += "\n" + color }
        try? text.write(to: config, atomically: true, encoding: .utf8)
        Script.shell("/usr/bin/pkill", ["-USR1", "-x", "cava"])
    }

    // MARK: tty-clock

    /// tty-clock only takes the 8 basic terminal colours: records which is nearest the accent, for ~/.local/bin/chaval-clock.
    static func clock(_ p: Palette) {
        let ansi = p.ansi.count == 16 ? p.ansi : ghosttyPalette(p.ghostty ?? "") ?? []
        func rgb(_ h: String) -> (Double, Double, Double) {
            let v = Int(h.prefix(6), radix: 16) ?? 0
            return (Double(v >> 16 & 255), Double(v >> 8 & 255), Double(v & 255))
        }
        let a = rgb(p.accent)
        let best = (1...6).filter { ansi.indices.contains($0) }.min { i, j in
            let x = rgb(ansi[i]), y = rgb(ansi[j])
            return pow(x.0 - a.0, 2) + pow(x.1 - a.1, 2) + pow(x.2 - a.2, 2) < pow(y.0 - a.0, 2) + pow(y.1 - a.1, 2) + pow(y.2 - a.2, 2)
        } ?? 4
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/chaval")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(best)\n".write(to: dir.appendingPathComponent("accent-ansi"), atomically: true, encoding: .utf8)
    }

    /// Same scheme as Ghostty: colours in chaval-theme.conf, sourced last by tmux.conf (one line added, backup kept),
    /// then loaded into the running server so every session changes at once.
    static func tmux(_ p: Palette) {
        let fm = FileManager.default, conf = tmuxDir.appendingPathComponent("tmux.conf"), theme = tmuxDir.appendingPathComponent("chaval-theme.conf")
        guard fm.fileExists(atPath: conf.path) else { return }
        let muted = (p.ansi.count == 16 ? p.ansi : ghosttyPalette(p.ghostty ?? "") ?? [])[safe: 8] ?? p.fg
        let line = p.surface, sel = p.selection ?? p.surface
        let text = """
        # Written by Chaval (theme: \(p.name)). Pick themes in Chaval's dashboard; edits here are overwritten.
        set -g status-style "bg=#\(p.bg),fg=#\(p.fg)"
        set -g status-left "#[fg=#\(p.bg),bg=#\(p.accent),bold] #S #[default] "
        set -g status-right "#[fg=#\(muted)]%H:%M "
        set -g window-status-format " #I #W "
        set -g window-status-current-format "#[fg=#\(p.accent),bold] #I #W "
        set -g pane-border-style "fg=#\(line)"
        set -g pane-active-border-style "fg=#\(p.accent)"
        set -g message-style "bg=#\(p.bg),fg=#\(p.accent)"
        set -g mode-style "bg=#\(sel),fg=#\(p.termFg ?? p.fg)"

        """
        try? text.write(to: theme, atomically: true, encoding: .utf8)
        if var c = try? String(contentsOf: conf, encoding: .utf8), !c.contains("chaval-theme.conf") {
            let backup = tmuxDir.appendingPathComponent("tmux.conf.before-chaval")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: conf, to: backup) }
            c += (c.hasSuffix("\n") ? "" : "\n") + "\n# Chaval's theme (colours only); remove this line to stop it.\nsource-file -q ~/.config/tmux/chaval-theme.conf\n"
            try? c.write(to: conf, atomically: true, encoding: .utf8)
        }
        if let exe = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first(where: fm.isExecutableFile), isRunning("tmux") {
            Script.shell(exe, ["source-file", theme.path])
        }
    }

    private static func isRunning(_ name: String) -> Bool { !Script.shell("/usr/bin/pgrep", ["-x", name]).isEmpty }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
