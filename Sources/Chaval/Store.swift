import AppKit

enum Edge: String, Codable, CaseIterable { case bottom, left, right, top }
enum DisplayMode: String, Codable, CaseIterable { case followCursor, main, fixed }
enum IndicatorStyle: String, Codable, CaseIterable { case dot, bar, glow, none }
enum LabelMode: String, Codable, CaseIterable { case hover, always, never }
enum Material: String, Codable, CaseIterable { case glass, blur, solid, clear }
enum Look: String, Codable, CaseIterable { case dark, light, system }
enum StackView: String, Codable, CaseIterable { case auto, fan, grid, list }
enum RevealAnim: String, Codable, CaseIterable { case slide, fade, zoom, none }
enum LaunchAnim: String, Codable, CaseIterable { case bounce, pulse, wiggle, none }
enum ClickEffect: String, Codable, CaseIterable { case darken, shrink, none }
enum Curve: String, Codable, CaseIterable { case smooth, wide, sharp, linear }
enum WidgetKind: String, Codable, CaseIterable {
    case clock, date, battery, cpu, memory, music, desktops
    var name: String { self == .cpu ? "CPU" : self == .music ? "Now Playing" : rawValue.capitalized }

    /// Per-widget toggles: (key, label).
    var options: [(String, String)] { [("background", "Show background")] + kindOptions }

    private var kindOptions: [(String, String)] {
        switch self {
        case .clock: return [("seconds", "Show seconds"), ("24h", "24-hour time"), ("weekday", "Show weekday / date")]
        case .date: return [("weekday", "Show weekday (otherwise month)")]
        case .battery: return [("bar", "Show level bar")]
        case .cpu, .memory: return [("bar", "Show bar"), ("graph", "Show history graph (wide sizes)")]
        case .music: return [("artwork", "Show album art"), ("controls", "Show controls (wide sizes)")]
        case .desktops: return []
        }
    }
}
enum TintMode: String, Codable, CaseIterable { case colorize, wash }
enum TileLayout: String, Codable, CaseIterable { case main, dwindle, grid, accordion } // main + stack · Hyprland/bspwm spiral · even grid · AeroSpace-style accordion
enum TileStyle: String, Codable, CaseIterable { case smooth, live } // smooth: GPU-animated snapshots (Compositor); live: the real windows, through Accessibility
enum StackSort: String, Codable, CaseIterable { case name, dateAdded, dateModified, dateCreated, kind }

struct Item: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case app, folder, file, spacer, widget, finder, trash, launcher, flexSpace }
    var id = UUID()
    var kind: Kind
    var path = ""
    var bundleID: String?
    var view: StackView = .auto
    var sort: StackSort = .dateAdded
    var asStack = true
    var widget: WidgetKind?
    // Widget customisation. Optional so layouts saved by older versions still decode.
    var span: Int?
    var bgHex: String?
    var fgHex: String?
    var opts: [String: Bool]?
    var textScale: Double?

    var url: URL { URL(fileURLWithPath: path) }

    var spanCount: Int {
        get { span ?? (widget == .music ? 3 : 1) }
        set { span = newValue }
    }

    func opt(_ key: String) -> Bool { opts?[key] ?? Item.optDefaults[key] ?? false }
    mutating func setOpt(_ key: String, _ on: Bool) { opts = (opts ?? [:]).merging([key: on]) { $1 } }

    private static let optDefaults: [String: Bool] = [
        "background": true, "weekday": true, "bar": true, "graph": true, "artwork": true, "controls": true,
        "24h": DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("H") ?? false,
    ]

    static let finderPath = "/System/Library/CoreServices/Finder.app"
    static let appsPath = "/System/Applications/Apps.app"
    static let missionControlPath = "/System/Applications/Mission Control.app"
}

/// Per-icon override, keyed by the item's path. tintHex: nil follows the dock-wide tint, "" means no tint.
struct IconStyle: Codable, Equatable {
    var image: String?
    var tintHex: String?
}

struct Settings: Codable, Equatable {
    var edge: Edge = .bottom
    var iconSize = 56.0
    var spacing = 6.0
    var padding = 8.0
    var edgeGap = 4.0
    var magnify = true
    var magnifiedSize = 96.0
    var magnifySpread = 3.0
    var autohide = false
    var autohideDelay = 0.0
    var animationSpeed = 0.25
    var showInFullscreen = true
    var taskbar = false
    var windowsOnly = false // a tile per open window instead of per running app
    var dockWindows = true  // show those window tiles at all (off: just the dock's own items and widgets)
    var reserveSpace = true
    var displayMode: DisplayMode = .followCursor
    var fixedDisplay = ""
    var material: Material = .glass
    var look: Look = .dark
    var tintHex = "00000000"
    var opacity = 1.0
    var cornerRadius = 20.0
    var border = true
    var desktopsInUse = true  // only desktops with windows (and the one you're on), by their real numbers
    var deskCorner = 0.2      // the current desktop's highlight: corner radius as a fraction of its height (0.5 = round)
    var stillWallpaper = true // the wallpaper stays put while desktops slide (Chaval draws it)
    var dockBorderWidth = 1.0
    var dockBorderAccent = true // the theme's accent; off: a faint white edge
    var shadow = true
    var indicator: IndicatorStyle = .dot
    var indicatorHex = "FFFFFFD9"
    var labels: LabelMode = .hover
    var launchAnim: LaunchAnim = .bounce
    var revealAnim: RevealAnim = .slide
    var clickEffect: ClickEffect = .darken
    var hoverLift = false
    var magnifyCurve: Curve = .smooth
    var fontName = ""
    var labelSize = 13.0
    var widgetBgHex = "FFFFFF26"
    var widgetTextHex = "FFFFFFFF"
    var widgetCorner = 0.22
    var dimHidden = true
    var iconTint = false
    var iconTintHex = "5E9BFFFF"
    var iconTintStrength = 0.7
    var iconTintMode: TintMode = .colorize
    var clickHides = false
    var scrollCycles = true
    var minimizeIntoApp = false
    var showRecents = false
    var recentCount = 3
    var animateWithReduceMotion = false
    var tiling = false
    var tileGap = 8.0
    var tileOuterGap = 10.0
    var tileRatio = 0.55
    var tileAnimate = true
    var tileSpeed = 1.0
    var tileStyle: TileStyle = .smooth
    var tileLayout: TileLayout = .main
    var tileMasters = 1          // windows in the main (left) column
    var tileAccordionPeek = 30.0 // how much of the windows behind the focused one shows, each side
    var focusFollowsMouse = true // with tiling on, the window under the pointer takes focus
    var cmdTab = true        // Chaval's window switcher replaces the system's ⌘Tab
    var autoUpdate = true    // install new GitHub releases on their own (Updater)
    var chavalMenus = true     // the top bar's app menus open in Chaval's theme (off: the real macOS menus)
    var borders = true       // the tiler draws window borders that move with its glides
    var borderWidth = 4.0
    var borderRadius = 14.0  // the window's own corner radius (a continuous corner, as macOS 26+ draws them); the border wraps it
    var borderThemed = true  // the theme's accent (focused) and a faint accent (others); off: the two colours below
    var borderActiveHex = "A7C080FF"
    var borderInactiveHex = "A7C08059"
    var borderInactive = true // unfocused windows get a border too
    var tileFloat = ["System Settings", "Calculator", "Archive Utility"] // app names or bundle IDs
    var launcherApps = true
    var launcherActions = true     // Chaval's actions and the Keys tab's commands
    var launcherCalc = true
    var launcherFiles = true
    var launcherFilesInline = true // files join the results from three letters (off: only after / or ~)
    var launcherFileFolders: [String] = [] // empty: the home folder
    var launcherEmoji = true
    var launcherWeb = "https://duckduckgo.com/?q=%s" // %s is the query; empty: no web search
    var launcherWidth = 640.0
    var launcherRows = 8
    var launcherRowHeight = 44.0
    var launcherFontSize = 18.0    // the search field; rows scale with it
    var launcherTop = 0.22         // the top edge, as a fraction of the screen down from the top
    var launcherCorner = 14.0
    var launcherOpacity = 0.97
    var launcherBorder = true
    var launcherSubtitles = true
    var launcherSubtleHighlight = false // a faint highlight instead of the accent
    var launcherAnimate = true
    var launcherFieldScale = 3.0   // the search bar's height, in text sizes
    var launcherIcons = true       // app, file and action icons beside each result
    var launcherSearchIcon = true  // the magnifying glass
    var launcherDivider = true     // the line between the search bar and the results
    var launcherPadding = 6.0      // around the results
    var launcherNumbers = false    // ⌘1–⌘9 hints on the results (the keys work either way)
    var launcherKeepQuery = false  // reopens with the last search
    var keys: [String: String] = [:]          // HotKeys.Action → shortcut, only where changed from the default
    var keyCommands: [KeyCommand] = [ // the launchers skhd ran here
        KeyCommand(keys: "alt - return", command: "~/.local/bin/ghostty-run"),
        KeyCommand(keys: "alt - e", command: "~/.local/bin/ghostty-run yazi"),
        KeyCommand(keys: "alt - b", command: "~/.local/bin/ghostty-run btop"),
        KeyCommand(keys: "alt - g", command: "~/.local/bin/ghostty-run lazygit"),
        KeyCommand(keys: "alt - n", command: "~/.local/bin/ghostty-run nvim"),
        KeyCommand(keys: "alt - m", command: "~/.local/bin/ghostty-run cava-launch"),
        KeyCommand(keys: "alt - s", command: "~/.local/bin/ghostty-run spotify_player"),
        KeyCommand(keys: "alt - i", command: "~/.local/bin/ghostty-run fastfetch"),
        KeyCommand(keys: "alt + shift - p", command: "~/.local/bin/ghostty-run pipes.sh"),
        KeyCommand(keys: "alt - c", command: "~/.local/bin/ghostty-run ~/.local/bin/chaval-clock"),
    ]
}

extension Notification.Name {
    static let chavalChanged = Notification.Name("chavalChanged")
    static let chavalWindowsChanged = Notification.Name("chavalWindowsChanged")
    static let chavalWindowFrame = Notification.Name("chavalWindowFrame")
    static let chavalDockStrip = Notification.Name("chavalDockStrip")
}

final class Store: ObservableObject {
    static let shared = Store()
    private let d = UserDefaults.standard

    @Published var settings: Settings { didSet { if settings != oldValue { save("settings", settings) } } }
    @Published var pinned: [Item] { didSet { if pinned != oldValue { save("pinned", pinned) } } }
    @Published var iconStyles: [String: IconStyle] { didSet { if iconStyles != oldValue { save("iconStyles", iconStyles) } } }
    @Published var bar: BarConfig { didSet { if bar != oldValue { save("bar", bar) } } }
    var recents: [String] { didSet { d.set(recents, forKey: "recents") } }
    var imported: Bool { get { d.bool(forKey: "imported") } set { d.set(newValue, forKey: "imported") } }

    init() {
        settings = Store.load("settings", Settings())
        pinned = Store.load("pinned", [Item]())
        iconStyles = Store.load("iconStyles", [String: IconStyle]())
        bar = Store.load("bar", BarConfig())
        recents = d.stringArray(forKey: "recents") ?? []
        // Bars saved before the dashboard existed get its button once, at the front of the left side.
        if !d.bool(forKey: "barDashboard") {
            d.set(true, forKey: "barDashboard")
            if !bar.modules.contains(.dashboard) {
                if let i = bar.sections.firstIndex(where: { $0.side == .left }) { bar.sections[i].items.insert(BarItem(module: .dashboard), at: 0) }
                else { bar.sections.insert(BarSection(name: "Dashboard", side: .left, items: [BarItem(module: .dashboard)], pill: false), at: 0) }
            }
        }
        if imported && !d.bool(forKey: "unifiedLayout") { migrateToUnifiedLayout() }
    }

    /// Earlier versions kept Finder, launchers, folders and the Trash in fixed places; now everything is one ordered list.
    private func migrateToUnifiedLayout() {
        let old = d.data(forKey: "settings").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var list: [Item] = []
        if old["showFinder"] as? Bool ?? true { list.append(Item(kind: .finder, path: Item.finderPath)) }
        if old["showAppsButton"] as? Bool == true { list.append(Item(kind: .launcher, path: Item.appsPath)) }
        if old["showMissionControl"] as? Bool == true { list.append(Item(kind: .launcher, path: Item.missionControlPath)) }
        list += pinned + Store.load("others", [Item]()) + [Item(kind: .trash)]
        pinned = list
        d.set(try? JSONEncoder().encode(list), forKey: "pinned")
        d.removeObject(forKey: "others")
        d.set(true, forKey: "unifiedLayout")
    }

    /// System Reduce Motion, unless the user asked Chaval to animate anyway.
    var reduceMotion: Bool { !settings.animateWithReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func contains(_ kind: Item.Kind, _ path: String = "") -> Bool {
        pinned.contains { $0.kind == kind && (path.isEmpty || $0.path == path) }
    }

    /// Adds a one-of-a-kind item where the system Dock would put it.
    func add(_ kind: Item.Kind, _ path: String = "") {
        guard !contains(kind, path) else { return }
        let item = Item(kind: kind, path: path)
        switch kind {
        case .finder: pinned.insert(item, at: 0)
        case .launcher: pinned.insert(item, at: contains(.finder) ? 1 : 0)
        default: pinned.append(item)
        }
    }

    /// Taskbar: the bar spans the whole edge; a flexible space (added before the first widget) pushes what follows to the far end.
    func setTaskbar(_ on: Bool) {
        settings.taskbar = on
        guard on, !contains(.flexSpace) else { return }
        pinned.insert(Item(kind: .flexSpace), at: pinned.firstIndex { $0.kind == .widget } ?? pinned.count)
    }

    func remove(_ kind: Item.Kind, _ path: String = "") {
        pinned.removeAll { $0.kind == kind && (path.isEmpty || $0.path == path) }
    }

    /// Custom icons are copied here so they survive the original file moving.
    static let iconDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chaval/Icons")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    func setIcon(_ key: String, from source: URL?) {
        if let old = iconStyles[key]?.image, old.hasPrefix(Store.iconDir.path) { try? FileManager.default.removeItem(atPath: old) }
        var path = source?.path
        if let source, source.pathExtension != "app" {
            let dest = Store.iconDir.appendingPathComponent(UUID().uuidString + "." + source.pathExtension)
            path = (try? FileManager.default.copyItem(at: source, to: dest)) != nil ? dest.path : nil
        }
        iconStyles[key, default: IconStyle()].image = path
        if iconStyles[key] == IconStyle() { iconStyles[key] = nil }
    }

    func setTint(_ key: String, _ hex: String?) {
        iconStyles[key, default: IconStyle()].tintHex = hex
        if iconStyles[key] == IconStyle() { iconStyles[key] = nil }
    }

    private func save<T: Encodable>(_ key: String, _ v: T) {
        d.set(try? JSONEncoder().encode(v), forKey: key)
        NotificationCenter.default.post(name: .chavalChanged, object: nil)
    }

    private static func load<T: Codable>(_ key: String, _ def: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key) else { return def }
        if let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        if let v = merged(data, def) { return v } // just settings added since they were saved: the usual case
        // Genuinely unreadable: keep a copy before anything can be saved over it, and salvage what reads.
        UserDefaults.standard.set(data, forKey: key + ".unreadable")
        return salvage(data, def)
    }

    /// Stored settings over the defaults (so ones added since fill in).
    private static func merged<T: Codable>(_ data: Data, _ def: T) -> T? {
        guard let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(def))) as? [String: Any],
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let m = try? JSONSerialization.data(withJSONObject: deepMerge(base, stored)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: m)
    }

    /// Stored values over the defaults at every level, so a setting added inside a group (the bar's theme, say) fills
    /// in too, instead of the whole group failing to load and falling back to its defaults.
    static func deepMerge(_ base: [String: Any], _ stored: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in stored {
            if let b = base[k] as? [String: Any], let s = v as? [String: Any] { out[k] = deepMerge(b, s) } else { out[k] = v }
        }
        return out
    }

    /// Reads what it can of stored settings that don't decode as a whole.
    static func salvage<T: Codable>(_ data: Data, _ def: T) -> T {
        // Merge stored keys over defaults so a newly added setting doesn't wipe the rest.
        guard let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(def))) as? [String: Any],
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: deepMerge(base, stored))
        else { return def }
        if let v = try? JSONDecoder().decode(T.self, from: merged) { return v }
        // Still not: take the stored settings one at a time and keep every one that reads, so a single bad value
        // (a malformed shortcut, say) costs only itself, never the whole layout.
        var kept = base
        for (k, v) in stored {
            var trial = kept; trial[k] = v
            if let d = try? JSONSerialization.data(withJSONObject: trial), (try? JSONDecoder().decode(T.self, from: d)) != nil { kept = trial }
        }
        return (try? JSONSerialization.data(withJSONObject: kept)).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? def
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        if hex.count == 6 { v = v << 8 | 0xFF }
        self.init(srgbRed: CGFloat(v >> 24 & 0xFF) / 255, green: CGFloat(v >> 16 & 0xFF) / 255,
                  blue: CGFloat(v >> 8 & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}
