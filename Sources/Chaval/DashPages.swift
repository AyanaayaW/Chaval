import SwiftUI
import IOKit
import UniformTypeIdentifiers

/// Colours and fonts every dashboard page draws with, from the bar's theme.
struct DashStyle {
    let t: BarTheme
    var fg: Color { Color(nsColor: NSColor(hex: t.fgHex)) }
    var accent: Color { Color(nsColor: NSColor(hex: t.accentHex)) }
    var tile: Color { Color(nsColor: NSColor(hex: t.pillHex)) }
    var onAccent: Color { Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(1)) }
    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font { Font(Fonts.font(size, weight, family: t.fontName)) }

    func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 10).fill(tile))
    }
    func title(_ s: String) -> some View { Text(s.uppercased()).font(font(10, .bold)).opacity(0.5) }
    func pill(_ label: String, symbol: String? = nil, on: Bool = false, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                if !label.isEmpty { Text(label).font(font(10, .semibold)) }
            }
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(on ? accent.opacity(0.9) : fg.opacity(0.1)))
            .foregroundStyle(on ? onAccent : fg)
        }.buttonStyle(.plain)
    }
}

private let work = DispatchQueue(label: "chaval.dash", qos: .userInitiated)

/// Repeats `f` while a page is on screen.
private struct Ticker: ViewModifier {
    let every: TimeInterval
    let f: () -> Void
    @State private var timer: Timer?
    func body(content: Content) -> some View {
        content
            .onAppear { f(); timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in f() } }
            .onDisappear { timer?.invalidate(); timer = nil }
    }
}
private extension View { func tick(_ every: TimeInterval, _ f: @escaping () -> Void) -> some View { modifier(Ticker(every: every, f: f)) } }

// MARK: - Now Playing

final class PlayerModel: ObservableObject {
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var shuffle = false
    @Published var repeatMode = "off" // off, one, all
    private var seeking = false

    /// Position, length, shuffle and repeat: the players don't broadcast these, so they're read while the page is open.
    func poll() {
        guard !seeking, let player = NowPlaying.shared.track?.player else { return }
        work.async { [weak self] in
            let script = player == "Spotify"
                ? "tell application \"Spotify\" to return {player position, (duration of current track) / 1000, shuffling, repeating}"
                : "tell application \"Music\" to return {player position, duration of current track, shuffle enabled, (song repeat as text)}"
            guard let r = Script.run(script), r.numberOfItems == 4 else { return }
            let pos = r.atIndex(1)?.doubleValue ?? 0, dur = r.atIndex(2)?.doubleValue ?? 0, sh = r.atIndex(3)?.booleanValue ?? false
            let rep = player == "Spotify" ? (r.atIndex(4)?.booleanValue == true ? "all" : "off") : (r.atIndex(4)?.stringValue ?? "off")
            DispatchQueue.main.async { self?.position = pos; self?.duration = dur; self?.shuffle = sh; self?.repeatMode = rep }
        }
    }

    func seek(_ t: Double, done: Bool) {
        position = t; seeking = !done
        guard done, let player = NowPlaying.shared.track?.player else { return }
        work.async { Script.run("tell application \"\(player)\" to set player position to \(t)") }
    }

    func toggleShuffle() {
        guard let player = NowPlaying.shared.track?.player else { return }
        shuffle.toggle()
        work.async { Script.run(player == "Spotify" ? "tell application \"Spotify\" to set shuffling to not shuffling"
                                                    : "tell application \"Music\" to set shuffle enabled to not shuffle enabled") }
    }

    func cycleRepeat() {
        guard let player = NowPlaying.shared.track?.player else { return }
        if player == "Spotify" {
            repeatMode = repeatMode == "off" ? "all" : "off"
            work.async { Script.run("tell application \"Spotify\" to set repeating to not repeating") }
        } else {
            repeatMode = ["off": "all", "all": "one", "one": "off"][repeatMode] ?? "off"
            let m = repeatMode
            work.async { Script.run("tell application \"Music\" to set song repeat to \(m)") }
        }
    }
}

struct MusicPage: View {
    let s: DashStyle
    @ObservedObject var dash: DashModel
    @StateObject private var p = PlayerModel()

    private func time(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    var body: some View {
        // The cover as big as the page allows (a square of its height), the details beside it spread over the same height.
        GeometryReader { g in
        let side = min(g.size.height, g.size.width * 0.5)
        HStack(alignment: .center, spacing: 18) {
            Group {
                if let art = dash.track?.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "music.note").font(.system(size: side * 0.28)).opacity(0.35) }
            }
            .frame(width: side, height: side).background(s.tile).clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 10) {
                Text(dash.track?.title ?? "Not Playing").font(s.font(20, .bold)).lineLimit(2)
                Text(dash.track?.artist ?? "Open Spotify or Music").font(s.font(13)).opacity(0.75).lineLimit(1)
                if let album = dash.track?.album, !album.isEmpty { Text(album).font(s.font(11)).opacity(0.5).lineLimit(1) }
                Spacer(minLength: 6)
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { p.position }, set: { p.seek($0, done: false) }), in: 0...max(p.duration, 1)) { editing in
                        if !editing { p.seek(p.position, done: true) }
                    }.tint(s.accent).controlSize(.small)
                    HStack { Text(time(p.position)); Spacer(); Text(time(p.duration)) }.font(s.font(10)).opacity(0.6).monospacedDigit()
                }
                HStack(spacing: 22) {
                    icon("shuffle", on: p.shuffle) { p.toggleShuffle() }
                    icon("backward.fill", size: 18) { NowPlaying.shared.send("previous track") }
                    icon(dash.track?.playing == true ? "pause.circle.fill" : "play.circle.fill", size: 38) { NowPlaying.shared.send("playpause") }
                    icon("forward.fill", size: 18) { NowPlaying.shared.send("next track") }
                    icon(p.repeatMode == "one" ? "repeat.1" : "repeat", on: p.repeatMode != "off") { p.cycleRepeat() }
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    s.pill("Spotify", symbol: "dot.radiowaves.left.and.right", on: dash.track?.player == "Spotify") { open("com.spotify.client") }
                    s.pill("Music", symbol: "music.note", on: dash.track?.player == "Music") { open("com.apple.Music") }
                }
            }
            .frame(height: side)
        }
        .frame(width: g.size.width, height: g.size.height)
        }
        .tick(1) { p.poll() }
    }

    private func icon(_ name: String, size: CGFloat = 14, on: Bool = false, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Image(systemName: name).font(.system(size: size, weight: .semibold)).foregroundStyle(on ? s.accent : s.fg) }.buttonStyle(.plain)
    }

    private func open(_ bid: String) { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { launch(u) } }
}

// MARK: - System

final class SystemModel: ObservableObject {
    struct Proc: Identifiable { let id: pid_t; let name: String; let cpu: Double; let app: Bool }
    @Published var cpu: [Double] = []
    @Published var mem: [Double] = []
    @Published var down = 0.0 // bytes/s
    @Published var up = 0.0
    @Published var procs: [Proc] = []
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var battery: (health: Int, cycles: Int, temp: Double)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    func refresh() {
        Widgets.sample()
        cpu = Widgets.history[.cpu] ?? []; mem = Widgets.history[.memory] ?? []
        if let (rx, tx) = Self.netBytes() {
            let now = Date()
            if let l = lastNet { let dt = max(now.timeIntervalSince(l.at), 0.1); down = Double(rx &- l.rx) / dt; up = Double(tx &- l.tx) / dt }
            lastNet = (rx, tx, now)
        }
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        diskFree = v?.volumeAvailableCapacityForImportantUsage ?? 0; diskTotal = Int64(v?.volumeTotalCapacity ?? 0)
        if battery == nil { battery = Self.batteryInfo() }
        work.async { [weak self] in
            let out = Script.shell("/bin/ps", ["-Aceo", "pid=,pcpu=,comm=", "-r"])
            let list: [Proc] = out.split(separator: "\n").prefix(14).compactMap { line in
                let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard f.count == 3, let pid = pid_t(f[0]), let c = Double(f[1]) else { return nil }
                return Proc(id: pid, name: String(f[2]), cpu: c, app: NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular)
            }
            DispatchQueue.main.async { self?.procs = list }
        }
    }

    /// Total bytes in/out over every non-loopback interface.
    private static func netBytes() -> (UInt64, UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard p.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = p.pointee.ifa_data,
                  !String(cString: p.pointee.ifa_name).hasPrefix("lo") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes); tx += UInt64(d.ifi_obytes)
        }
        return (rx, tx)
    }

    private static func batteryInfo() -> (Int, Int, Double)? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        // Apple silicon keeps the mAh figures in BatteryData; Intel at the top level.
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        let full = data["NominalChargeCapacity"] as? Int ?? d["AppleRawMaxCapacity"] as? Int ?? 0
        let design = data["DesignCapacity"] as? Int ?? d["DesignCapacity"] as? Int ?? 0
        return (design > 0 ? min(full * 100 / design, 100) : 0, d["CycleCount"] as? Int ?? 0, Double(d["Temperature"] as? Int ?? 0) / 100)
    }

    func quit(_ p: Proc) { NSRunningApplication(processIdentifier: p.id)?.terminate() }
}

struct SystemPage: View {
    let s: DashStyle
    @StateObject private var m = SystemModel()

    private func rate(_ b: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary) + "/s" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                graph("CPU", m.cpu)
                graph("Memory", m.mem)
                HStack(spacing: 10) {
                    s.card {
                        VStack(alignment: .leading, spacing: 4) {
                            s.title("Network")
                            Label(rate(m.down), systemImage: "arrow.down").font(s.font(11, .semibold))
                            Label(rate(m.up), systemImage: "arrow.up").font(s.font(11, .semibold)).opacity(0.75)
                        }
                    }
                    s.card {
                        VStack(alignment: .leading, spacing: 4) {
                            s.title("Disk")
                            Text(ByteCountFormatter.string(fromByteCount: m.diskFree, countStyle: .file) + " free").font(s.font(11, .semibold))
                            bar(m.diskTotal > 0 ? 1 - Double(m.diskFree) / Double(m.diskTotal) : 0)
                        }
                    }
                    if let b = m.battery {
                        s.card {
                            VStack(alignment: .leading, spacing: 4) {
                                s.title("Battery")
                                Text("\(b.health)% health").font(s.font(11, .semibold))
                                Text("\(b.cycles) cycles" + (b.temp > 0 ? " · \(String(format: "%.0f", b.temp))°C" : "")).font(s.font(10)).opacity(0.7)
                            }
                        }
                    }
                }
            }
            s.card {
                VStack(alignment: .leading, spacing: 4) {
                    s.title("Top processes")
                    ForEach(m.procs) { p in
                        HStack(spacing: 6) {
                            Text(p.name).font(s.font(11)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", p.cpu)).font(s.font(11, .semibold)).monospacedDigit().foregroundStyle(p.cpu > 50 ? s.accent : s.fg)
                            // Only real apps get a quit button: ending a system process could log you out.
                            if p.app { s.pill("", symbol: "xmark") { m.quit(p) }.help("Quit \(p.name)") }
                        }
                        .frame(height: 22)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 250)
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .tick(2) { m.refresh() }
    }

    private func bar(_ v: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) { Capsule().fill(s.fg.opacity(0.15)); Capsule().fill(s.accent).frame(width: g.size.width * min(max(v, 0.02), 1)) }
        }.frame(height: 4)
    }

    private func graph(_ name: String, _ v: [Double]) -> some View {
        s.card {
            VStack(alignment: .leading, spacing: 6) {
                HStack { s.title(name); Spacer(); Text("\(Int((v.last ?? 0) * 100))%").font(s.font(12, .bold)).monospacedDigit() }
                GeometryReader { g in
                    let pts = v.enumerated().map { CGPoint(x: g.size.width * CGFloat($0.offset) / 39, y: g.size.height * (1 - CGFloat(min(max($0.element, 0), 1)))) }
                    ZStack {
                        Path { p in guard let f = pts.first else { return }; p.move(to: CGPoint(x: f.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)) }
                            .fill(s.accent.opacity(0.18))
                        Path { p in p.addLines(pts) }.stroke(s.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }.frame(minHeight: 54, maxHeight: .infinity) // the graphs take the height the page has
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Wallpapers

/// The current theme's wallpapers (~/Documents/Wallpapers/<theme>); picking one is remembered for that theme.
final class WallpaperModel: ObservableObject {
    @Published var folder = Themes.wallpaperFolder(Themes.palette)
    @Published var files: [URL] = []
    @Published var thumbs: [URL: NSImage] = [:]

    func load() {
        folder = Themes.wallpaperFolder(Themes.palette)
        files = Themes.wallpapers(Themes.palette)
        for f in files where thumbs[f] == nil {
            work.async { [weak self] in
                guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 420,
                                                                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
                let img = NSImage(cgImage: cg, size: .zero)
                DispatchQueue.main.async { self?.thumbs[f] = img }
            }
        }
    }

    func set(_ url: URL) { Themes.setWallpaper(url, for: Themes.palette) }
}

extension Notification.Name { static let chavalWallpaperChanged = Notification.Name("chavalWallpaperChanged") }

struct WallpaperPage: View {
    let s: DashStyle
    @StateObject private var m = WallpaperModel()
    @State private var sel = 0
    @State private var drag: CGFloat = 0
    @State private var scroll: (monitor: Any?, sum: CGFloat, apply: DispatchWorkItem?) = (nil, 0, nil)
    private let step: CGFloat = 230

    /// Curved carousel: the selected card in the middle, neighbours shrinking and turning away. Click a side card to bring
    /// it to the middle, click the middle one to set it; drag or use the arrows to flip through. Scrolling flips through
    /// and sets the one it stops on. Cards show the whole wallpaper, uncropped.
    private var carousel: some View {
        let pos = CGFloat(sel) - drag / step
        return ZStack {
            ForEach(Array(m.files.enumerated()), id: \.element) { i, f in
                let d = CGFloat(i) - pos
                if abs(d) < 4.5 {
                    let size = t(f).map { CGSize(width: 300, height: min(300 * $0.size.height / max($0.size.width, 1), 300)) } ?? CGSize(width: 300, height: 169)
                    Group {
                        if let t = t(f) { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) } else { s.tile }
                    }
                    .frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(i == sel ? s.accent : .clear, lineWidth: 2))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
                    .scaleEffect(1 - min(abs(d), 3) * 0.14)
                    .rotation3DEffect(.degrees(Double(max(min(d, 2.5), -2.5)) * -16), axis: (0, 1, 0), perspective: 0.6)
                    .offset(x: d * step * (1 - min(abs(d), 3) * 0.08))
                    .opacity(1 - Double(min(abs(d), 4)) * 0.18)
                    .zIndex(-Double(abs(d)))
                    .onTapGesture { if i == sel { m.set(f) } else { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { sel = i } } }
                    .help(i == sel ? "Set \(f.lastPathComponent) as wallpaper" : f.lastPathComponent)
                }
            }
            HStack {
                s.pill("", symbol: "chevron.left") { move(-1) }
                Spacer()
                s.pill("", symbol: "chevron.right") { move(1) }
            }
            .zIndex(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation.width }
            .onEnded { v in
                let target = Int((CGFloat(sel) - v.predictedEndTranslation.width / step).rounded())
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { sel = min(max(target, 0), m.files.count - 1); drag = 0 }
            })
    }

    private func t(_ f: URL) -> NSImage? { m.thumbs[f] }

    private func onScroll(_ e: NSEvent) -> NSEvent? {
        guard Dashboard.shared.owns(e.window), !m.files.isEmpty else { return e }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? -e.scrollingDeltaX : -e.scrollingDeltaY
        scroll.sum += e.hasPreciseScrollingDeltas ? d : d.sign == .minus ? -40 : 40 // a wheel notch is one card
        guard abs(scroll.sum) >= 40 else { return nil }
        move(scroll.sum > 0 ? 1 : -1)
        scroll.sum = 0
        scroll.apply?.cancel()
        let w = DispatchWorkItem { [sel, m] in if m.files.indices.contains(sel) { m.set(m.files[sel]) } }
        scroll.apply = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w) // set it once scrolling stops
        return nil
    }

    private func move(_ by: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { sel = min(max(sel + by, 0), max(m.files.count - 1, 0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                s.title(m.folder.lastPathComponent)
                Spacer()
                s.pill("Add your own…", symbol: "folder") {
                    try? FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(m.folder)
                }
            }
            if m.files.isEmpty {
                Text("No wallpapers for this theme yet. Add images to \(m.folder.path).").font(s.font(11)).opacity(0.6).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                carousel
            }
        }
        .onAppear {
            m.load()
            // Start on the current wallpaper.
            if let cur = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }), let i = m.files.firstIndex(of: cur) { sel = i }
            scroll.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { onScroll($0) }
        }
        .onDisappear { scroll.monitor.map(NSEvent.removeMonitor); scroll = (nil, 0, nil) }
    }
}

// MARK: - Quick Launch

struct LaunchItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path = ""     // app, folder or file
    var command = ""  // or a shell script
}

final class LauncherModel: ObservableObject {
    @Published var items: [LaunchItem] { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "quickLaunch") } }
    @Published var query = ""
    private(set) var apps: [URL] = []

    init() {
        items = UserDefaults.standard.data(forKey: "quickLaunch").flatMap { try? JSONDecoder().decode([LaunchItem].self, from: $0) } ?? []
        work.async { [weak self] in
            let fm = FileManager.default
            let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            let found = dirs.flatMap { d in ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".app") }.map { URL(fileURLWithPath: d).appendingPathComponent($0) } }
            DispatchQueue.main.async { self?.apps = found }
        }
    }

    var results: [URL] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return apps.filter { $0.deletingPathExtension().lastPathComponent.lowercased().contains(q) }
            .sorted { a, b in a.lastPathComponent.lowercased().hasPrefix(q) && !b.lastPathComponent.lowercased().hasPrefix(q) }
            .prefix(8).map { $0 }
    }

    func run(_ i: LaunchItem) {
        if !i.command.isEmpty { work.async { Script.shell("/bin/zsh", ["-lc", i.command]) }; return }
        let u = URL(fileURLWithPath: i.path)
        if u.pathExtension == "app" { launch(u) } else { NSWorkspace.shared.open(u) }
    }

    func add(_ u: URL) {
        guard !items.contains(where: { $0.path == u.path }) else { return }
        items.append(LaunchItem(name: u.deletingPathExtension().lastPathComponent, path: u.path))
    }

    func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        if p.runModal() == .OK { p.urls.forEach(add) }
    }
}

struct LauncherPage: View {
    let s: DashStyle
    let close: () -> Void
    @StateObject private var m = LauncherModel()
    @State private var scriptName = ""
    @State private var scriptCmd = ""
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").opacity(0.6)
                TextField("Search apps", text: $m.query).textFieldStyle(.plain).font(s.font(14))
                    .onSubmit { if let u = m.results.first { launch(u); close() } }
            }
            .padding(.horizontal, 10).frame(height: 34).background(RoundedRectangle(cornerRadius: 9).fill(s.tile))

            if !m.query.isEmpty {
                VStack(spacing: 2) {
                    ForEach(m.results, id: \.self) { u in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 22, height: 22)
                            Text(u.deletingPathExtension().lastPathComponent).font(s.font(12))
                            Spacer()
                            s.pill("", symbol: "star") { m.add(u) }.help("Add to favourites")
                        }
                        .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                        .onTapGesture { launch(u); close() }
                    }
                }
            } else {
                HStack { s.title("Favourites"); Spacer()
                    s.pill("Add…", symbol: "plus") { m.pick() }
                    s.pill("Script", symbol: "terminal", on: adding) { adding.toggle() }
                }
                if adding {
                    HStack(spacing: 6) {
                        TextField("Name", text: $scriptName).textFieldStyle(.plain).font(s.font(11)).padding(.horizontal, 8).frame(width: 130, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(s.tile))
                        TextField("Shell command", text: $scriptCmd).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 7).fill(s.tile))
                        s.pill("Save", on: true) {
                            guard !scriptName.isEmpty, !scriptCmd.isEmpty else { return }
                            m.items.append(LaunchItem(name: scriptName, command: scriptCmd)); scriptName = ""; scriptCmd = ""; adding = false
                        }
                    }
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(m.items) { i in
                            Button { m.run(i); if i.command.isEmpty { close() } } label: {
                                VStack(spacing: 6) {
                                    if i.command.isEmpty { Image(nsImage: NSWorkspace.shared.icon(forFile: i.path)).resizable().frame(width: 44, height: 44) }
                                    else { Image(systemName: "terminal.fill").font(.system(size: 24)).frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 10).fill(s.accent.opacity(0.25))) }
                                    Text(i.name).font(s.font(10)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(s.tile))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Remove", role: .destructive) { m.items.removeAll { $0.id == i.id } } }
                        }
                    }
                    if m.items.isEmpty { Text("Drop apps, folders or files here, or use Add…").font(s.font(11)).opacity(0.55).padding(.top, 30) }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for pr in providers {
                        _ = pr.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { m.add(u) } } }
                    }
                    return true
                }
            }
        }
    }
}

// MARK: - Notes

final class NotesModel: ObservableObject {
    struct Todo: Codable, Identifiable, Equatable { var id = UUID(); var text: String; var done = false }
    static let file = Store.iconDir.deletingLastPathComponent().appendingPathComponent("notes.md")
    @Published var text = (try? String(contentsOf: NotesModel.file, encoding: .utf8)) ?? "" { didSet { saveSoon() } }
    @Published var todos: [Todo] = UserDefaults.standard.data(forKey: "todos").flatMap { try? JSONDecoder().decode([Todo].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(todos), forKey: "todos") }
    }
    private var save: DispatchWorkItem?

    private func saveSoon() {
        save?.cancel()
        let t = text
        let w = DispatchWorkItem { try? t.write(to: NotesModel.file, atomically: true, encoding: .utf8) }
        save = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
}

struct NotesPage: View {
    let s: DashStyle
    @StateObject private var m = NotesModel()
    @State private var newTodo = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            s.card {
                VStack(alignment: .leading, spacing: 6) {
                    s.title("Scratchpad")
                    TextEditor(text: $m.text).font(s.font(12)).scrollContentBackground(.hidden).frame(maxHeight: .infinity)
                }
            }
            s.card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { s.title("To do"); Spacer(); if m.todos.contains(where: \.done) { s.pill("Clear done") { m.todos.removeAll(where: \.done) } } }
                    TextField("Add a task", text: $newTodo).textFieldStyle(.plain).font(s.font(12))
                        .padding(.horizontal, 8).frame(height: 28).background(RoundedRectangle(cornerRadius: 7).fill(s.fg.opacity(0.08)))
                        .onSubmit { guard !newTodo.isEmpty else { return }; m.todos.insert(.init(text: newTodo), at: 0); newTodo = "" }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach($m.todos) { $t in
                                HStack(spacing: 8) {
                                    Button { t.done.toggle() } label: { Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundStyle(t.done ? s.accent : s.fg) }.buttonStyle(.plain)
                                    Text(t.text).font(s.font(12)).strikethrough(t.done).opacity(t.done ? 0.5 : 1)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 260)
        }
    }
}

// MARK: - Custom Manager (dotfiles)

struct CustomAction: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var command: String }

final class CustomModel: ObservableObject {
    struct Tool: Identifiable {
        let id: String       // process name
        let name: String
        let config: String   // path under ~
        let start: String?, stop: String?, reload: String?
    }
    static let tools: [Tool] = [
        Tool(id: "tmux", name: "tmux", config: ".config/tmux/tmux.conf", start: nil, stop: nil, reload: "tmux source-file ~/.config/tmux/tmux.conf"),
        Tool(id: "ghostty", name: "Ghostty", config: ".config/ghostty/config", start: nil, stop: nil, reload: "ghostty-reload"),
        // Terminal tools open in a Ghostty window. yabai, skhd, SketchyBar and paneru aren't listed: Chaval does their jobs,
        // and starting one would fight it for the windows, the keys or the bar.
        Tool(id: "cava", name: "cava", config: ".config/cava/config", start: "~/.local/bin/ghostty-run ~/.local/bin/cava-launch", stop: "pkill -x cava", reload: "pkill -USR1 -x cava"),
        Tool(id: "tty-clock", name: "Clock (tty-clock)", config: ".local/bin/chaval-clock", start: "~/.local/bin/ghostty-run ~/.local/bin/chaval-clock", stop: "pkill -x tty-clock", reload: nil),
        Tool(id: "btop", name: "btop", config: ".config/btop/btop.conf", start: "~/.local/bin/ghostty-run btop", stop: "pkill -x btop", reload: nil),
        Tool(id: "fastfetch", name: "fastfetch", config: ".config/fastfetch/config.jsonc", start: "~/.local/bin/ghostty-run fastfetch", stop: nil, reload: nil),
        Tool(id: "yazi", name: "yazi", config: ".config/yazi/yazi.toml", start: "~/.local/bin/ghostty-run yazi", stop: "pkill -x yazi", reload: nil),
    ]

    @Published var running: Set<String> = []
    @Published var output = ""
    @Published var opacity: Double = 1
    @Published var actions: [CustomAction] = UserDefaults.standard.data(forKey: "customActions").flatMap { try? JSONDecoder().decode([CustomAction].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(actions), forKey: "customActions") }
    }
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var ghosttyConfig: URL { home.appendingPathComponent(".config/ghostty/config") }

    var installed: [Tool] { Self.tools.filter { FileManager.default.fileExists(atPath: home.appendingPathComponent($0.config).path) } }

    func refresh() {
        work.async { [weak self] in
            let names = Set(Script.shell("/bin/ps", ["-Aco", "comm="]).split(separator: "\n").map { String($0).lowercased() })
            DispatchQueue.main.async { self?.running = names }
        }
        if let text = try? String(contentsOf: ghosttyConfig, encoding: .utf8),
           let m = text.range(of: #"(?m)^background-opacity\s*=\s*([0-9.]+)"#, options: .regularExpression),
           let v = Double(text[m].split(separator: "=").last!.trimmingCharacters(in: .whitespaces)) { opacity = v }
    }

    func run(_ cmd: String, then: (() -> Void)? = nil) {
        if cmd == "ghostty-reload" { reloadGhostty(); return }
        output = "$ " + cmd
        work.async { [weak self] in
            let out = Script.shell("/bin/zsh", ["-lc", cmd + " 2>&1"])
            DispatchQueue.main.async {
                self?.output = "$ \(cmd)" + (out.isEmpty ? "" : "\n" + out.split(separator: "\n").suffix(3).joined(separator: "\n"))
                then?(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
            }
        }
    }

    func reloadGhostty() {
        output = "Reloaded Ghostty's config"
        work.async { Script.run("tell application \"Ghostty\" to perform action \"reload_config\" on terminal 1 of tab 1 of window 1") }
    }

    /// Rewrites the background-opacity line (or adds one) and reloads Ghostty.
    func setOpacity(_ v: Double) {
        guard var text = try? String(contentsOf: ghosttyConfig, encoding: .utf8) else { return }
        let line = "background-opacity = \(String(format: "%.2f", v))"
        if let r = text.range(of: #"(?m)^background-opacity\s*=.*$"#, options: .regularExpression) { text.replaceSubrange(r, with: line) }
        else { text += "\n\(line)\n" }
        try? text.write(to: ghosttyConfig, atomically: true, encoding: .utf8)
        reloadGhostty()
    }

    func edit(_ t: Tool) { NSWorkspace.shared.open([home.appendingPathComponent(t.config)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration()) }
}

struct CustomPage: View {
    let s: DashStyle
    @StateObject private var m = CustomModel()
    @State private var name = ""
    @State private var cmd = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(m.installed) { t in
                        let on = m.running.contains(t.id.lowercased())
                        HStack(spacing: 8) {
                            Circle().fill(on ? s.accent : s.fg.opacity(0.25)).frame(width: 7, height: 7)
                            Text(t.name).font(s.font(12, .semibold))
                            Spacer()
                            if let r = t.reload { s.pill("Reload", symbol: "arrow.clockwise") { m.run(r) } }
                            if let st = t.start {
                                if on, let sp = t.stop { s.pill("Stop", symbol: "stop.fill") { m.run(sp) } }
                                else { s.pill("Start", symbol: "play.fill") { m.run(st) } }
                            }
                            s.pill("Edit", symbol: "pencil") { m.edit(t) }
                        }
                        .padding(.horizontal, 10).frame(height: 36).background(RoundedRectangle(cornerRadius: 9).fill(s.tile))
                    }
                    s.card {
                        HStack(spacing: 8) {
                            Text("Ghostty opacity").font(s.font(11, .semibold))
                            Slider(value: $m.opacity, in: 0.3...1) { editing in if !editing { m.setOpacity(m.opacity) } }.tint(s.accent).controlSize(.small)
                            Text("\(Int(m.opacity * 100))%").font(s.font(10)).monospacedDigit().frame(width: 34)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                s.title("Your commands")
                ScrollView {
                    VStack(spacing: 6) {
                        if m.actions.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "terminal").font(.system(size: 22)).opacity(0.4)
                                Text("Save a shell command below to run it with one click, from here. Right-click one to remove it.")
                                    .font(s.font(10)).opacity(0.55).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(m.actions) { a in
                            HStack {
                                Text(a.name).font(s.font(11, .semibold)).lineLimit(1)
                                Spacer()
                                s.pill("Run", symbol: "play.fill", on: true) { m.run(a.command) }
                            }
                            .contextMenu { Button("Remove", role: .destructive) { m.actions.removeAll { $0.id == a.id } } }
                        }
                    }
                }
                TextField("Name", text: $name).textFieldStyle(.plain).font(s.font(11)).padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 7).fill(s.fg.opacity(0.08)))
                HStack {
                    TextField("Command", text: $cmd).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 7).fill(s.fg.opacity(0.08)))
                    s.pill("Add", symbol: "plus") { guard !name.isEmpty, !cmd.isEmpty else { return }; m.actions.append(.init(name: name, command: cmd)); name = ""; cmd = "" }
                }
                Text(m.output.isEmpty ? "Output appears here" : m.output).font(.system(size: 10, design: .monospaced)).opacity(0.65).lineLimit(4)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).padding(6).background(RoundedRectangle(cornerRadius: 7).fill(s.fg.opacity(0.06)))
            }
            .padding(10).frame(width: 250).frame(maxHeight: .infinity).background(RoundedRectangle(cornerRadius: 10).fill(s.tile))
        }
        .tick(3) { m.refresh() }
    }
}
