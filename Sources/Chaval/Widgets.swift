import AppKit
import IOKit.ps

enum Fonts {
    static let families = ["", "System Rounded", "System Monospaced"] + NSFontManager.shared.availableFontFamilies

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, family: String = Store.shared.settings.fontName) -> NSFont {
        let sys = NSFont.systemFont(ofSize: size, weight: weight)
        switch family {
        case "": return sys
        case "System Rounded": return sys.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? sys
        case "System Monospaced": return .monospacedSystemFont(ofSize: size, weight: weight)
        case let family:
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: weight >= .semibold ? 9 : 5, size: size) ?? sys
        }
    }
}

/// Simple live tiles. Each renders into the image a normal icon uses (wider for wide sizes).
enum Widgets {
    // MARK: Data

    private static var lastTicks: host_cpu_load_info?
    private(set) static var latest: [WidgetKind: Double] = [:]
    private(set) static var history: [WidgetKind: [Double]] = [:]

    /// Takes one CPU and memory reading; renders read the latest value, so redraws don't skew the CPU delta.
    static func sample() {
        for (k, v) in [(WidgetKind.cpu, cpu()), (.memory, memory())] {
            latest[k] = v
            history[k] = Array((history[k] ?? []).suffix(39)) + [v]
        }
    }

    /// Fraction of CPU busy since the previous call (first call returns 0).
    private static func cpu() -> Double {
        var info = host_cpu_load_info()
        var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) }
        } == KERN_SUCCESS
        defer { if ok { lastTicks = info } }
        guard ok, let p = lastTicks else { return 0 }
        let t = info.cpu_ticks, q = p.cpu_ticks
        let busy = Double(t.0 &- q.0) + Double(t.1 &- q.1) + Double(t.3 &- q.3), idle = Double(t.2 &- q.2)
        return busy + idle > 0 ? busy / (busy + idle) : 0
    }

    /// "Memory Used" as Activity Monitor counts it: app + wired + compressed.
    static func memory() -> Double {
        var s = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        guard withUnsafeMutablePointer(to: &s, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
        }) == KERN_SUCCESS else { return 0 }
        let app = max(Int64(s.internal_page_count) - Int64(s.purgeable_count), 0)
        let used = Double(app + Int64(s.wire_count) + Int64(s.compressor_page_count)) * Double(vm_kernel_page_size)
        return used / Double(ProcessInfo.processInfo.physicalMemory)
    }

    static func battery() -> (level: Int, plugged: Bool, present: Bool, minutes: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (0, true, false, nil) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, cap = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let mins = d[plugged ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            return (cur * 100 / max(cap, 1), plugged, true, mins.flatMap { $0 > 0 ? $0 : nil })
        }
        return (0, true, false, nil)
    }

    private static var onPower: [String: () -> Void] = [:]
    /// Event-driven: macOS calls back when charge or power source changes. One callback per `key` (dock, bar).
    static func watchPower(_ key: String = "dock", _ f: @escaping () -> Void) {
        let first = onPower.isEmpty
        onPower[key] = f
        guard first else { return }
        if let src = IOPSNotificationCreateRunLoopSource({ _ in Widgets.onPower.values.forEach { $0() } }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    // MARK: Rendering

    /// Apps per desktop for the Desktops widget; the dock refreshes it.
    static var desks: [[NSRunningApplication]] = []
    /// A desktop's width in icon heights: its number, plus room for up to four app icons.
    static func deskWeight(_ apps: Int) -> CGFloat { apps == 0 ? 0.9 : 1.08 + 0.66 * CGFloat(min(apps, 4)) } // last icon gets as much room after it as the number has before it
    /// The desktops shown (0-based, in order): every one, or only those in use, with windows or showing now.
    static var shown: [Int] {
        let cur = Desktops.current.index, inUse = Store.shared.settings.desktopsInUse
        return (0..<max(Desktops.current.count, 1)).filter { !inUse || $0 == cur || ($0 < desks.count && !desks[$0].isEmpty) }
    }
    private static var deskWeights: [CGFloat] { shown.map { deskWeight($0 < desks.count ? desks[$0].count : 0) } }
    /// A Nerd Font icon for an app, as Linux bars show (matched on its name or bundle ID); a window for anything unknown.
    static func glyph(_ app: NSRunningApplication) -> String {
        let id = ((app.bundleIdentifier ?? "") + " " + (app.localizedName ?? "")).lowercased()
        let map: [([String], Int)] = [
            (["firefox", "librewolf", "zen", "waterfox"], 0xF269), (["chrome", "brave", "arc", "edge", "chromium", "vivaldi"], 0xF268),
            (["safari"], 0xF267), (["spotify"], 0xF1BC), (["discord"], 0xF066F), (["whatsapp"], 0xF232),
            (["ghostty", "terminal", "iterm", "kitty", "alacritty", "wezterm", "warp"], 0xF120),
            (["vscode", "visual studio code", "cursor"], 0xF0A1E), (["zed", "xcode", "sublime", "nova"], 0xF121),
            (["finder"], 0xF0036), (["music", "cava"], 0xF001), (["messages", "imessage"], 0xF0361), (["mail", "outlook", "spark"], 0xF0E0),
            (["calendar", "fantastical"], 0xF073), (["settings", "preferences"], 0xF013), (["notes", "obsidian", "notion"], 0xF249),
            (["steam"], 0xF1B6), (["slack"], 0xF198), (["telegram"], 0xF2C6), (["claude", "chatgpt", "openai"], 0xF0674),
            (["youtube"], 0xF16A), (["github"], 0xF09B), (["preview", "photos"], 0xF03E), (["word", "pages"], 0xF1C2),
            (["books"], 0xF02D), (["zoom", "facetime", "teams"], 0xF03D),
        ]
        let cp = map.first { $0.0.contains(where: id.contains) }?.1 ?? 0xF2D0
        return String(UnicodeScalar(cp)!)
    }

    /// Every desktop: its number and its apps' icons. `active` draws them all as the current one looks (on a solid band,
    /// in the background colour); the dock shows that through a pill-shaped mask that slides to the current desktop.
    private static func drawDesks(W: CGFloat, H: CGFloat, fg: NSColor, bg: NSColor, active: Bool) {
        // The current desktop's pill is the theme's accent, as in the top bar.
        if active { NSColor(hex: Store.shared.bar.theme.accentHex).withAlphaComponent(1).setFill(); NSRect(x: 0, y: H * 0.06, width: W, height: H * 0.88).fill() }
        let corner = H * 0.88 * CGFloat(Store.shared.settings.deskCorner)
        for (s, i) in zip(deskSlots(W), shown) {
            let apps = i < desks.count ? Array(desks[i].prefix(4)) : []
            if !active && !apps.isEmpty {
                fg.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: s.minX + H * 0.04, y: H * 0.06, width: s.width - H * 0.08, height: H * 0.88), xRadius: corner, yRadius: corner).fill()
            }
            let color = active ? bg.withAlphaComponent(1) : apps.isEmpty ? fg.withAlphaComponent(0.32) : fg
            let k = s.width / (deskWeight(apps.count) * H) // the slot's stretch to fill the widget
            var pt = H * 0.54, num: NSAttributedString
            repeat { num = NSAttributedString(string: "\(i + 1)", attributes: [.font: Fonts.font(pt, .bold), .foregroundColor: color]); pt *= 0.92 } while num.size().width > H * 0.62
            let cx = apps.isEmpty ? s.midX : s.minX + H * 0.44 * k, z = num.size()
            num.draw(at: NSPoint(x: cx - z.width / 2, y: H / 2 - z.height / 2))
            for (j, a) in apps.enumerated() {
                let box = NSRect(x: s.minX + H * (0.76 + 0.66 * CGFloat(j)) * k, y: H * 0.2, width: H * 0.6, height: H * 0.6)
                guard let font = NSFont(name: "FiraCode Nerd Font", size: H * 0.5) else { a.icon?.draw(in: box); continue } // no Nerd Font: real icons
                let g = NSAttributedString(string: glyph(a), attributes: [.font: font, .foregroundColor: color])
                let gz = g.size()
                g.draw(at: NSPoint(x: box.midX - gz.width / 2, y: box.midY - gz.height / 2))
            }
        }
    }

    /// The Desktops widget as the current desktop looks, and where (0…1 across) the current desktop is.
    static func desksActive(_ item: Item, px: Int, span: Int) -> (CGImage?, CGRect) {
        let H = CGFloat(px), W = H * CGFloat(span), st = Store.shared.settings
        let fg = NSColor(hex: item.fgHex ?? st.widgetTextHex), bg = NSColor(hex: item.bgHex ?? st.widgetBgHex)
        let slots = deskSlots(1), cur = shown.firstIndex(of: Desktops.current.index) ?? -1
        return (Icons.draw(Int(W), Int(H)) { drawDesks(W: W, H: H, fg: fg, bg: bg, active: true) }, slots.indices.contains(cur) ? slots[cur] : .zero)
    }

    /// How many dock slots the Desktops widget takes.
    static var deskSpan: Int { max(1, Int(ceil(deskWeights.reduce(0, +)))) }
    /// Each desktop's strip of a widget `W` wide, stretched to fill it.
    static func deskSlots(_ W: CGFloat) -> [NSRect] {
        let w = deskWeights, k = W / w.reduce(0, +)
        var x: CGFloat = 0
        return w.map { defer { x += $0 * k }; return NSRect(x: x, y: 0, width: $0 * k, height: 1) }
    }

    static func render(_ item: Item, key: String, px: Int, span: Int) -> (CGImage?, String) {
        guard let kind = item.widget else { return (nil, "") }
        let H = CGFloat(px), W = H * CGFloat(span), wide = span > 1
        let st = Store.shared.settings
        let fg = NSColor(hex: item.fgHex ?? st.widgetTextHex), bg = NSColor(hex: item.bgHex ?? st.widgetBgHex)
        let dim = fg.withAlphaComponent(0.7)
        let scale = CGFloat(item.textScale ?? 1)
        let pad = H * 0.06, tile = NSRect(x: pad, y: pad, width: W - 2 * pad, height: H - 2 * pad)
        let shape = NSBezierPath(roundedRect: tile, xRadius: H * st.widgetCorner, yRadius: H * st.widgetCorner)
        // Wide layouts use a square on the left and a text column on the right.
        let col = NSRect(x: H * 0.98, y: pad, width: W - H * 0.98 - H * 0.12, height: H - 2 * pad)
        var title = kind.name

        /// Centred text that shrinks to fit `maxW`.
        func centered(_ str: String, _ size: CGFloat, _ weight: NSFont.Weight, cx: CGFloat = W / 2, y: CGFloat,
                      maxW: CGFloat? = nil, color: NSColor? = nil) {
            var pt = size * H * scale, ns: NSAttributedString
            repeat {
                ns = NSAttributedString(string: str, attributes: [.font: Fonts.font(pt, weight), .foregroundColor: color ?? fg])
                pt *= 0.92
            } while ns.size().width > (maxW ?? (wide ? W * 0.86 : H * 0.84)) && pt > 4
            let z = ns.size()
            ns.draw(at: NSPoint(x: cx - z.width / 2, y: y * H - z.height / 2))
        }
        /// Left-aligned single line in the text column, truncated with "…".
        func line(_ str: String, _ size: CGFloat, _ weight: NSFont.Weight, y: CGFloat, color: NSColor? = nil) {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            let ns = NSAttributedString(string: str, attributes: [.font: Fonts.font(size * H * scale, weight), .foregroundColor: color ?? fg, .paragraphStyle: p])
            let h = ns.size().height
            ns.draw(with: NSRect(x: col.minX, y: y * H - h / 2, width: col.width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        func bar(_ v: Double, color: NSColor, in r: NSRect) {
            fg.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            color.setFill()
            var f = r; f.size.width *= min(max(v, 0.04), 1)
            NSBezierPath(roundedRect: f, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
        func graph(_ values: [Double], color: NSColor, in r: NSRect) {
            guard values.count > 1 else { return }
            let path = NSBezierPath()
            for (i, v) in values.enumerated() {
                let p = NSPoint(x: r.minX + r.width * CGFloat(i) / 39, y: r.minY + r.height * CGFloat(min(max(v, 0), 1)))
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
            let fill = path.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: fill.currentPoint.x, y: r.minY))
            fill.line(to: NSPoint(x: r.minX, y: r.minY))
            color.withAlphaComponent(0.25).setFill(); fill.fill()
            path.lineWidth = max(1, H * 0.025); path.lineJoinStyle = .round
            color.setStroke(); path.stroke()
        }
        func symbol(_ name: String, _ size: CGFloat, center: NSPoint, color: NSColor? = nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: size * H, weight: .semibold).applying(.init(paletteColors: [color ?? fg]))
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
            img.draw(in: NSRect(x: center.x - img.size.width / 2, y: center.y - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        func level(_ v: Double) -> NSColor { v > 0.85 ? .systemRed : v > 0.6 ? .systemOrange : .systemBlue }

        let img = Icons.draw(Int(W), Int(H)) {
            if item.opt("background") { bg.setFill(); shape.fill() }
            let now = Date()
            switch kind {
            case .clock:
                let f = DateFormatter()
                f.setLocalizedDateFormatFromTemplate((item.opt("24h") ? "Hmm" : "hmm") + (item.opt("seconds") ? "ss" : ""))
                let time = f.string(from: now)
                if !item.opt("weekday") && !time.contains(" ") {
                    centered(time, 0.66, .bold, y: 0.5, maxW: W * 0.94) // just the time, as big as fits
                } else if wide {
                    centered(time, 0.46, .bold, y: item.opt("weekday") ? 0.6 : 0.5)
                    if item.opt("weekday") { centered(now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), 0.16, .medium, y: 0.24, color: dim) }
                } else {
                    let parts = time.split(separator: " ", maxSplits: 1).map(String.init)
                    let wd = item.opt("weekday"), ampm = parts.count > 1
                    if wd { centered(now.formatted(.dateTime.weekday(.abbreviated)).uppercased(), 0.13, .semibold, y: 0.77, color: dim) }
                    centered(parts[0], 0.42, .bold, y: wd ? (ampm ? 0.5 : 0.44) : (ampm ? 0.56 : 0.5))
                    if ampm { centered(parts[1], 0.13, .semibold, y: wd ? 0.24 : 0.28, color: dim) }
                }
                title = now.formatted(date: .complete, time: item.opt("seconds") ? .standard : .shortened)
            case .date:
                let band = NSRect(x: tile.minX, y: tile.maxY - H * 0.26, width: wide ? H * 0.88 : tile.width, height: H * 0.26)
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor.systemRed.setFill(); band.fill()
                NSGraphicsContext.restoreGraphicsState()
                let top = item.opt("weekday") ? now.formatted(.dateTime.weekday(.abbreviated)) : now.formatted(.dateTime.month(.abbreviated))
                centered(top.uppercased(), 0.13, .bold, cx: band.midX, y: 0.81, maxW: band.width * 0.86, color: .white)
                centered(now.formatted(.dateTime.day()), 0.4, .regular, cx: wide ? H * 0.5 : W / 2, y: 0.42, maxW: H * 0.76)
                if wide {
                    line(now.formatted(.dateTime.weekday(.wide)), 0.17, .semibold, y: 0.6)
                    line(now.formatted(.dateTime.month(.wide).year()), 0.14, .regular, y: 0.38, color: dim)
                }
                title = now.formatted(date: .complete, time: .omitted)
            case .battery:
                let b = battery()
                let color: NSColor = b.level <= 20 && !b.plugged ? .systemRed : .systemGreen
                let remaining = b.minutes.map { "\($0 / 60):\(String(format: "%02d", $0 % 60)) \(b.plugged ? "to full" : "left")" }
                if wide {
                    centered(b.present ? "\(b.level)%" : "AC", 0.3, .semibold, cx: H * 0.5, y: 0.5, maxW: H * 0.76)
                    line(b.present ? (b.plugged ? "⚡︎ Charging" : "On battery") : "Power adapter", 0.15, .semibold, y: 0.66)
                    if let remaining { line(remaining, 0.13, .regular, y: 0.45, color: dim) }
                    if b.present && item.opt("bar") { bar(Double(b.level) / 100, color: color, in: NSRect(x: col.minX, y: H * 0.2, width: col.width, height: H * 0.07)) }
                } else {
                    centered(b.plugged ? "⚡︎ BATTERY" : "BATTERY", 0.11, .semibold, y: 0.76, color: dim)
                    centered(b.present ? "\(b.level)%" : "AC", 0.3, .semibold, y: item.opt("bar") ? 0.48 : 0.42)
                    if b.present && item.opt("bar") { bar(Double(b.level) / 100, color: color, in: NSRect(x: H * 0.22, y: H * 0.2, width: H * 0.56, height: H * 0.07)) }
                }
                title = b.present ? "Battery \(b.level)%\(b.plugged ? ", on power adapter" : "")\(remaining.map { " · " + $0 } ?? "")" : "Power adapter"
            case .cpu, .memory:
                let v = latest[kind] ?? (kind == .memory ? memory() : 0)
                let pct = "\(Int((v * 100).rounded()))%", name = kind == .cpu ? "CPU" : "MEMORY"
                if wide {
                    centered(name, 0.12, .semibold, cx: H * 0.5, y: 0.72, maxW: H * 0.76, color: dim)
                    centered(pct, 0.3, .semibold, cx: H * 0.5, y: 0.44, maxW: H * 0.76)
                    let r = NSRect(x: col.minX, y: H * 0.18, width: col.width, height: H * 0.62)
                    if item.opt("graph") { graph(history[kind] ?? [v], color: level(v), in: r) }
                    else if item.opt("bar") { bar(v, color: level(v), in: NSRect(x: col.minX, y: H * 0.46, width: col.width, height: H * 0.08)) }
                } else {
                    centered(name, 0.12, .semibold, y: 0.76, color: dim)
                    centered(pct, 0.3, .semibold, y: item.opt("bar") ? 0.48 : 0.42)
                    if item.opt("bar") { bar(v, color: level(v), in: NSRect(x: H * 0.22, y: H * 0.2, width: H * 0.56, height: H * 0.07)) }
                }
                title = "\(kind.name) \(pct)"
            case .desktops:
                // The current desktop's highlight is a separate layer the dock slides between desktops (see desksActive).
                drawDesks(W: W, H: H, fg: fg, bg: bg, active: false)
                title = "Desktop \(Desktops.current.index + 1) of \(deskSlots(W).count)"
            case .music:
                let track = NowPlaying.shared.track
                let artRect = NSRect(x: pad, y: pad, width: H - 2 * pad, height: H - 2 * pad)
                if let art = track?.artwork, item.opt("artwork") {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: artRect, xRadius: H * st.widgetCorner, yRadius: H * st.widgetCorner).addClip()
                    art.draw(in: artRect)
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    symbol("music.note", 0.34, center: NSPoint(x: artRect.midX, y: artRect.midY), color: dim)
                }
                if !wide, let track {
                    // Small size: a play/pause badge over the art.
                    let c = NSPoint(x: H * 0.74, y: H * 0.26), r = H * 0.15
                    NSColor(white: 0, alpha: 0.55).setFill()
                    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
                    symbol(track.playing ? "pause.fill" : "play.fill", 0.13, center: c, color: .white)
                }
                if wide {
                    let controls = item.opt("controls")
                    line(track?.title ?? "Not Playing", 0.23, .bold, y: controls ? 0.74 : 0.62)
                    line(track.map { $0.artist.isEmpty ? $0.player : $0.artist } ?? "Click to open your player", 0.17, .medium, y: controls ? 0.5 : 0.38, color: dim)
                    if controls {
                        let names = ["backward.fill", track?.playing == true ? "pause.fill" : "play.fill", "forward.fill"]
                        for (i, n) in names.enumerated() {
                            symbol(n, (i == 1 ? 0.24 : 0.18) * scale, center: NSPoint(x: col.minX + col.width * CGFloat(2 * i + 1) / 6, y: H * 0.22))
                        }
                    }
                }
                title = track.map { "\($0.title)\($0.artist.isEmpty ? "" : " — " + $0.artist)" } ?? "Not Playing"
            }
        }
        return (img.flatMap { Icons.tinted($0, Icons.tint(for: key)) }, title)
    }

    static func open(_ kind: WidgetKind) {
        switch kind {
        case .clock, .date: launch(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        case .battery: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .cpu, .memory: launch(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case .music: NowPlaying.shared.openPlayer()
        case .desktops: break // handled by where it was clicked
        }
    }
}

// MARK: - Now playing (Spotify and Apple Music)

/// The system-wide Now Playing API is closed to third-party apps, so this listens to the players' own
/// broadcasts (instant, no polling) and controls them over Apple Events.
final class NowPlaying: NSObject {
    static let shared = NowPlaying()

    struct Track {
        var title = "", artist = "", album = "", player = ""
        var playing = false
        var artwork: NSImage?
    }

    private(set) var track: Track?
    private var listeners: [String: () -> Void] = [:]
    private var started = false
    private let queue = DispatchQueue(label: "chaval.nowplaying") // Apple Events block; keep them off the main thread
    private static let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]

    /// One listener per `key` (dock, bar); calling again replaces it.
    func start(_ key: String = "dock", _ onChange: @escaping () -> Void) {
        listeners[key] = onChange
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(self, selector: #selector(changed(_:)), name: .init(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(quit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Pick up whatever is already playing, without launching a player that isn't running.
        for (bid, name) in Self.players where isRunning(bid) {
            queue.async { [weak self] in
                let r = Script.run("tell application \"\(name)\" to if player state is not stopped then return {name of current track, artist of current track, album of current track, player state as text}")
                guard let r, r.numberOfItems == 4 else { return }
                let t = Track(title: r.atIndex(1)?.stringValue ?? "", artist: r.atIndex(2)?.stringValue ?? "",
                              album: r.atIndex(3)?.stringValue ?? "", player: name, playing: r.atIndex(4)?.stringValue == "playing")
                DispatchQueue.main.async { if self?.track == nil { self?.update(t) } }
            }
        }
    }

    private func isRunning(_ bid: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty }

    @objc private func changed(_ n: Notification) {
        let player = n.name.rawValue.hasPrefix("com.spotify") ? "Spotify" : "Music"
        let u = n.userInfo ?? [:]
        let state = u["Player State"] as? String ?? ""
        if state == "Stopped" {
            if track?.player == player { track = nil; notify() }
            return
        }
        update(Track(title: u["Name"] as? String ?? track?.title ?? "", artist: u["Artist"] as? String ?? "",
                     album: u["Album"] as? String ?? "", player: player, playing: state == "Playing"))
    }

    @objc private func quit(_ n: Notification) {
        let bid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        if let track, Self.players.contains(where: { $0.0 == bid && $0.1 == track.player }) { self.track = nil; notify() }
    }

    private func notify() { listeners.values.forEach { $0() } }

    private func update(_ new: Track) {
        var t = new
        let sameSong = track?.player == t.player && track?.title == t.title && track?.album == t.album
        if sameSong { t.artwork = track?.artwork } else { loadArtwork(for: t) }
        track = t
        notify()
    }

    private func loadArtwork(for t: Track) {
        let done: (NSImage?) -> Void = { [weak self] img in
            DispatchQueue.main.async {
                guard let self, let img, self.track?.title == t.title, self.track?.player == t.player else { return }
                self.track?.artwork = img
                self.notify()
            }
        }
        queue.async {
            if t.player == "Spotify" {
                guard let s = Script.run("tell application \"Spotify\" to artwork url of current track")?.stringValue,
                      let url = URL(string: s) else { return done(nil) }
                URLSession.shared.dataTask(with: url) { data, _, _ in done(data.flatMap(NSImage.init(data:))) }.resume()
            } else {
                done(Script.run("tell application \"Music\" to get raw data of artwork 1 of current track").flatMap { NSImage(data: $0.data) })
            }
        }
    }

    /// "playpause", "next track" or "previous track". With nothing playing, opens a player instead.
    func send(_ command: String) {
        guard let player = track?.player ?? Self.players.first(where: { isRunning($0.0) })?.1 else { return openPlayer() }
        queue.async { Script.run("tell application \"\(player)\" to \(command)") }
    }

    func openPlayer() {
        let bid = Self.players.first { $0.1 == track?.player }?.0 ?? Self.players.first { isRunning($0.0) }?.0
        let url = [bid, "com.spotify.client", "com.apple.Music"].compactMap { $0 }
            .lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        if let url { launch(url) }
    }
}
