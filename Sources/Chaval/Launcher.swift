import AppKit
import SwiftUI

/// Chaval's Raycast: ⌥Space, type, Return. Finds apps, Chaval's own actions and the shortcuts' launchers, does sums, and
/// falls back to a web search. Apps you open often rise to the top; with nothing typed, the most used are listed.
/// Files (Spotlight's index, by name) join in from three letters; "/" or "~" first searches only files, ":" emoji.
/// "theme" lists themes and "wallpaper" (or "wall", "bg") the theme's wallpapers, like Omarchy's style menu: Return
/// applies one and the launcher stays open, so you can flip through them.
final class Launcher: NSObject {
    static let shared = Launcher()

    struct Item: Identifiable {
        let id: String, title: String, subtitle: String
        var icon: NSImage? = nil, symbol: String? = nil, glyph: String? = nil
        var keepOpen = false
        var alt: (() -> Void)? = nil // ⌘Return
        let run: () -> Void
    }

    let model = SearchModel()
    private var panel: NSPanel?
    private var apps: [(name: String, url: URL)] = []
    private var uses: [String: Int] = UserDefaults.standard.dictionary(forKey: "launcherUses") as? [String: Int] ?? [:]
    private static var st: Chaval.Settings { Store.shared.settings }
    static var width: CGFloat { CGFloat(st.launcherWidth) }
    static var field: CGFloat { (CGFloat(st.launcherFontSize) * CGFloat(st.launcherFieldScale)).rounded() }
    static var padding: CGFloat { CGFloat(st.launcherPadding) }
    /// The first result on show: the rows follow the selection, so the arrows reach every result.
    static func firstShown(_ m: SearchModel) -> Int { max(0, min(m.selected - maxRows + 1, m.items.count - maxRows)) }
    static var row: CGFloat { CGFloat(st.launcherRowHeight) }
    static var maxRows: Int { st.launcherRows }
    private let files = NSMetadataQuery()
    private var fileHits: (term: String, items: [Item]) = ("", [])
    private var fileTerm = ""

    override init() {
        super.init()
        files.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: files, queue: .main) { [weak self] _ in self?.foundFiles() }
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        rescan()
        if !Self.st.launcherKeepQuery { model.query = "" }
        model.selected = 0; model.still = NSEvent.mouseLocation
        model.items = results(for: model.query)
        let p = panel ?? make()
        panel = p
        closing = false
        fit(animated: false)
        p.alphaValue = Self.st.launcherAnimate ? 0 : 1
        p.orderFrontRegardless()
        p.makeKey() // typing comes here without bringing Chaval forward
        model.focus += 1
        guard Self.st.launcherAnimate else { return }
        // In: springs down into place from a touch smaller and higher, fading up.
        pop(p, scale: 0.94, lift: 14, to: 1, spring: true)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; $0.timingFunction = CAMediaTimingFunction(name: .easeOut); p.animator().alphaValue = 1 }
    }

    private var closing = false

    func close() {
        guard let p = panel, p.isVisible, !closing else { return }
        closing = true
        guard Self.st.launcherAnimate else { return p.orderOut(nil) }
        // Out: a quick shrink and fade.
        pop(p, scale: 1, lift: 0, to: 0.96, spring: false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.11; $0.timingFunction = CAMediaTimingFunction(name: .easeIn); p.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in if self?.closing == true { p.orderOut(nil) } })
    }

    func search(_ q: String) {
        model.still = NSEvent.mouseLocation
        findFiles(fileTerm(q))
        withAnimation(.snappy(duration: 0.2)) {
            model.items = results(for: q)
            model.selected = model.items.firstIndex { $0.subtitle.hasSuffix("· current") } ?? 0 // a theme or wallpaper list opens on the current one
        }
        fit(animated: true)
    }

    /// Scales the content about its centre (and lifts it) from `scale` to `to`: a spring on the way in, ease-in out.
    private func pop(_ p: NSPanel, scale: CGFloat, lift: CGFloat, to: CGFloat, spring: Bool) {
        guard let v = p.contentView else { return }
        v.wantsLayer = true
        guard let l = v.layer else { return }
        let b = l.bounds
        func t(_ k: CGFloat, _ dy: CGFloat) -> CATransform3D {
            CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-b.midX, -b.midY, 0), CATransform3DMakeScale(k, k, 1)),
                                CATransform3DMakeTranslation(b.midX, b.midY + dy, 0))
        }
        let a: CABasicAnimation
        if spring { a = CASpringAnimation(perceptualDuration: 0.34, bounce: 0.18) } else { a = CABasicAnimation(); a.duration = 0.11; a.timingFunction = CAMediaTimingFunction(name: .easeIn) }
        a.keyPath = "transform"
        a.fromValue = NSValue(caTransform3D: spring ? t(scale, lift) : (l.presentation() ?? l).transform)
        a.toValue = NSValue(caTransform3D: t(to, 0))
        CATransaction.begin(); CATransaction.setDisableActions(true); l.transform = t(to, 0); CATransaction.commit()
        l.add(a, forKey: "pop")
    }

    func clearUses() { uses = [:]; UserDefaults.standard.removeObject(forKey: "launcherUses") }

    func reveal(_ i: Int) {
        guard model.items.indices.contains(i), let alt = model.items[i].alt else { return }
        close(); alt()
    }

    func choose(_ i: Int) {
        guard model.items.indices.contains(i) else { return }
        let it = model.items[i]
        uses[it.id, default: 0] += 1
        UserDefaults.standard.set(uses, forKey: "launcherUses")
        if !it.keepOpen { close() }
        it.run()
        if it.keepOpen { // stays open (a theme or wallpaper): show which is current now, same row selected
            let sel = model.selected
            model.items = results(for: model.query)
            model.selected = min(sel, max(model.items.count - 1, 0))
        }
    }

    /// Height follows the results; the top edge stays put so the field doesn't jump while typing.
    private func fit(animated: Bool = false) {
        guard let p = panel else { return }
        let rows = min(model.items.count, Self.maxRows)
        let h = Self.field + (rows > 0 ? CGFloat(rows) * Self.row + 2 * Self.padding + (Self.st.launcherDivider ? 1 : 0) : 0)
        let s = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = p.isVisible ? p.frame.maxY : s.frame.maxY - s.frame.height * Self.st.launcherTop
        let r = NSRect(x: p.isVisible ? p.frame.minX : s.frame.midX - Self.width / 2, y: top - h, width: Self.width, height: h)
        guard animated && p.isVisible && r != p.frame else { return p.setFrame(r, display: true) }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2; c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1) // fast out, soft landing
            p.animator().setFrame(r, display: true)
        }
    }

    private func make() -> NSPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // the system's shadow (and its light rim) follows the square panel, not the rounded shape
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: LauncherView(model: model).environmentObject(Store.shared))
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in self?.close() }
        return p
    }

    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

    // MARK: Finding things

    /// The .app bundles in the usual places (a directory listing each: a few milliseconds).
    private func rescan() {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        var seen = Set<String>(), out: [(String, URL)] = []
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let n = String(name.dropLast(4))
                guard n != "Chaval", seen.insert(n).inserted else { continue }
                out.append((n, URL(fileURLWithPath: dir + "/" + name)))
            }
        }
        out.append(("Finder", URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")))
        apps = out
    }

    private func everything() -> [Item] {
        let st = Self.st
        let appItems = !st.launcherApps ? [] : apps.map { a in
            Item(id: "app:" + a.url.path, title: a.name, subtitle: "Application", icon: NSWorkspace.shared.icon(forFile: a.url.path)) {
                NSWorkspace.shared.openApplication(at: a.url, configuration: .init())
            }
        }
        let actions = !st.launcherActions ? [] : HotKeys.Action.allCases.filter { $0 != .launcher }.map { a in
            Item(id: "chaval:" + a.rawValue, title: a.title, subtitle: "Chaval · " + (HotKeys.symbols(a.keys).joined(separator: " ").nilIfEmpty ?? a.group),
                 symbol: "command") { a.run() }
        }
        let commands = !st.launcherActions ? [] : st.keyCommands.filter { !$0.command.isEmpty }.map { c in
            Item(id: "cmd:" + c.command, title: c.command, subtitle: "Launcher · " + HotKeys.symbols(c.keys).joined(separator: " "), symbol: "terminal") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", c.command]
                try? p.run()
            }
        }
        return appItems + actions + commands + (st.launcherActions ? themeItems(named: true) : [])
    }

    // MARK: Themes and wallpapers (Omarchy's style menu)

    /// "theme …" lists themes and "wallpaper …" / "wall …" / "bg …" this theme's wallpapers, filtered by the rest; nil otherwise.
    private func styleResults(_ q: String) -> [Item]? {
        let parts = q.lowercased().split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = parts.first else { return nil }
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let items: [Item]
        if ["theme", "themes"].contains(head) { items = themeItems(named: false) }
        else if ["wallpaper", "wallpapers", "wall", "bg", "background"].contains(head) { items = wallpaperItems() }
        else { return nil }
        guard !rest.isEmpty else { return items }
        return items.compactMap { it in Launcher.score(rest, it.title).map { (it, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func themeItems(named: Bool) -> [Item] {
        Palette.all.map { p in
            Item(id: "theme:" + p.name, title: named ? "Theme: " + p.name : p.name,
                 subtitle: p.name == Themes.current ? "Theme · current" : "Theme · " + (p.dark ? "dark" : "light"),
                 icon: swatch(p), keepOpen: true) { Themes.apply(p) }
        }
    }

    private func wallpaperItems() -> [Item] {
        let p = Themes.palette, folder = Themes.wallpaperFolder(p), files = Themes.wallpapers(p)
        guard !files.isEmpty else {
            return [Item(id: "wall:open", title: "Add wallpapers for \(p.family)", subtitle: "Opens its folder", symbol: "photo.badge.plus") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }]
        }
        let current = UserDefaults.standard.string(forKey: "wallpaper." + folder.lastPathComponent)
        let next = Item(id: "wall:next", title: "Next wallpaper", subtitle: HotKeys.symbols(HotKeys.Action.nextWallpaper.keys).joined(separator: " ").nilIfEmpty ?? "Wallpaper",
                        symbol: "arrow.forward.circle", keepOpen: true) { HotKeys.Action.nextWallpaper.run() }
        return [next] + files.map { url in
            Item(id: "wall:" + url.path, title: url.deletingPathExtension().lastPathComponent,
                 subtitle: url.path == current ? "Wallpaper · current" : "Wallpaper", icon: thumbnail(url), keepOpen: true,
                 alt: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) { Themes.setWallpaper(url, for: p) }
        }
    }

    private var swatches: [String: NSImage] = [:], thumbnails: [String: NSImage] = [:]

    /// A theme at a glance: its background, its accent, and two of its colours.
    private func swatch(_ p: Palette) -> NSImage {
        if let i = swatches[p.name] { return i }
        let cols = p.swatches.prefix(2).map { NSColor(hex: $0 + "FF") }
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
            NSColor(hex: p.bg + "FF").setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            NSColor(hex: p.fg + "FF").withAlphaComponent(0.25).setStroke()
            let edge = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 7.5, yRadius: 7.5); edge.lineWidth = 1; edge.stroke()
            NSColor(hex: p.accent + "FF").setFill(); NSBezierPath(ovalIn: NSRect(x: 7, y: 13, width: 12, height: 12)).fill()
            for (i, c) in cols.enumerated() { c.setFill(); NSBezierPath(ovalIn: NSRect(x: 19, y: 18 - CGFloat(i) * 10, width: 7, height: 7)).fill() }
            return true
        }
        swatches[p.name] = img
        return img
    }

    /// A small picture of a wallpaper, decoded at thumbnail size (not the whole 6K image), kept while Chaval runs.
    private func thumbnail(_ url: URL) -> NSImage? {
        if let i = thumbnails[url.path] { return i }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        thumbnails[url.path] = img
        return img
    }

    /// What to look for in file names: the rest after "/" or "~", or the query itself from three letters (nil: no files).
    static func fileTerm(_ raw: String, inline: Bool = true) -> String? {
        let q = raw.trimmingCharacters(in: .whitespaces).filter { !"*?\\\"'".contains($0) } // no wildcards or quotes into the predicate
        if let f = q.first, f == "/" || f == "~" { return String(q.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return inline && q.count >= 3 && !q.hasPrefix(":") && calculate(q) == nil ? q : nil
    }

    private func fileTerm(_ q: String) -> String? {
        Self.st.launcherFiles ? Self.fileTerm(q, inline: Self.st.launcherFilesInline) : nil
    }

    private func findFiles(_ term: String?) {
        let name = term ?? ""
        guard name != fileTerm else { return }
        files.stop(); fileTerm = name
        guard name.count >= 2 else { return }
        let folders = Self.st.launcherFileFolders.map { ($0 as NSString).expandingTildeInPath }
        files.searchScopes = folders.isEmpty ? [NSMetadataQueryUserHomeScope] : folders
        files.predicate = NSPredicate(format: "%K LIKE[cd] %@ AND %K != 'com.apple.application-bundle'",
                                      NSMetadataItemFSNameKey, "*\(name)*", NSMetadataItemContentTypeKey)
        files.start()
    }

    /// The first gather is all we want; the newest-used matches, best named first, join whatever's on screen.
    private func foundFiles() {
        files.stop()
        let paths = (0..<min(files.resultCount, 300)).compactMap { (files.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
            .filter { !$0.contains("/Library/") && !$0.contains("/.") } // app guts and hidden files, as Spotlight leaves out
        let term = fileTerm
        let ranked = paths.compactMap { p -> (String, Double)? in Launcher.score(term, (p as NSString).lastPathComponent).map { (p, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(Self.maxRows).map(\.0)
        fileHits = (term, ranked.map { p in
            let url = URL(fileURLWithPath: p)
            return Item(id: "file:" + p, title: url.lastPathComponent,
                        subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                        icon: NSWorkspace.shared.icon(forFile: p), alt: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                NSWorkspace.shared.open(url)
            }
        })
        guard isOpen else { return }
        model.still = NSEvent.mouseLocation
        let id = model.items.indices.contains(model.selected) ? model.items[model.selected].id : nil
        withAnimation(.snappy(duration: 0.2)) {
            model.items = results(for: model.query)
            model.selected = model.items.firstIndex { $0.id == id } ?? 0
        }
        fit(animated: true)
    }

    /// Every single-character emoji Unicode draws as a picture, by its Unicode name.
    /// ponytail: names only ("grinning face"), no keywords like "lol" or ZWJ sequences; add CLDR annotations if missed.
    static let emoji: [(glyph: String, name: String)] = [0x2600...0x27BF, 0x1F300...0x1FAFF].flatMap { $0 }.compactMap { v in
        guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, let n = s.properties.name else { return nil }
        return (String(s), n.lowercased())
    }

    private func emojiResults(_ q: String) -> [Item] {
        let q = q.trimmingCharacters(in: .whitespaces)
        return Self.emoji.compactMap { e -> (Item, Double)? in
            let id = "emoji:" + e.glyph, used = Double(min(uses[id] ?? 0, 50)) * 8
            guard let s = q.isEmpty ? (uses[id] != nil ? used : nil) : Launcher.score(q, e.name) else { return nil }
            return (Item(id: id, title: e.name.capitalized, subtitle: "Return copies it", glyph: e.glyph) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.glyph, forType: .string)
            }, s + used)
        }.sorted { $0.1 > $1.1 }.prefix(Self.maxRows).map(\.0)
    }

    func results(for raw: String) -> [Item] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        let st = Self.st
        if q.hasPrefix(":") && st.launcherEmoji { return emojiResults(String(q.dropFirst())) }
        if let style = styleResults(q) { return style }
        let term = fileTerm(q)
        let found = term != nil && term == fileHits.term ? fileHits.items : []
        if let f = q.first, f == "/" || f == "~" { return found }
        let all = everything()
        if q.isEmpty { // the most used, apps first
            return all.filter { uses[$0.id] != nil }.sorted { uses[$0.id]! > uses[$1.id]! }.prefix(Self.maxRows).map { $0 }
        }
        var out: [Item] = []
        if st.launcherCalc, let v = Launcher.calculate(q) {
            let text = Launcher.format(v)
            out.append(Item(id: "calc", title: "= " + text, subtitle: "Return copies it", symbol: "equal.square.fill") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            })
        }
        let ranked = all.compactMap { it -> (Item, Double)? in
            guard let s = Launcher.score(q, it.title) else { return nil }
            return (it, s + Double(min(uses[it.id] ?? 0, 50)) * 8 + (it.id.hasPrefix("app:") ? 30 : 0))
        }.sorted { $0.1 > $1.1 }.prefix(found.isEmpty ? Self.maxRows - 1 : 4).map(\.0)
        out += ranked
        out += found.prefix(max(0, Self.maxRows - 1 - out.count))
        if !st.launcherWeb.isEmpty,
           let u = URL(string: st.launcherWeb.replacingOccurrences(of: "%s", with: q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)) {
            out.append(Item(id: "web", title: "Search the web for “\(q)”", subtitle: u.host() ?? "Web", symbol: "magnifyingglass") {
                NSWorkspace.shared.open(u)
            })
        }
        return out
    }

    /// How well `q` matches `title` (nil: not at all): whole prefix, then a word's start, then initials ("vsc" →
    /// Visual Studio Code), then anywhere, then the letters in order.
    static func score(_ q: String, _ title: String) -> Double? {
        let q = q.lowercased(), t = title.lowercased()
        if t.hasPrefix(q) { return 1000 - Double(t.count) }
        let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 800 - Double(t.count) }
        if q.count > 1, String(words.compactMap(\.first)).hasPrefix(q) { return 700 }
        if t.contains(q) { return 500 - Double(t.count) }
        var i = t.startIndex, run = 0, best = 0
        for c in q {
            guard let j = t[i...].firstIndex(of: c) else { return nil }
            run = j == i ? run + 1 : 1; best = max(best, run)
            i = t.index(after: j)
        }
        return 100 + Double(best * 10) - Double(t.count)
    }

    // MARK: Sums

    /// + − × ÷ ^ % and brackets ("2*(3+4)^2", "15% of 80" isn't understood). nil unless it's a whole sum with an
    /// operator in it, so a plain number or a word never shows a result.
    static func calculate(_ s: String) -> Double? {
        let chars = Array(s.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: ",", with: "").filter { $0 != " " })
        guard chars.contains(where: { "+-*/^%".contains($0) }), chars.allSatisfy({ "0123456789.+-*/^%()".contains($0) }) else { return nil }
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" { i += 1; guard let r = term() else { return nil }; v = c == "+" ? v + r : v - r }
            return v
        }
        func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1; guard let r = power() else { return nil }
                v = c == "*" ? v * r : c == "/" ? v / r : v.truncatingRemainder(dividingBy: r)
            }
            return v
        }
        func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }
        func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "(" { i += 1; let v = expr(); guard peek() == ")" else { return nil }; i += 1; return v }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
        guard let v = expr(), i == chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.10g", v)
    }

    /// Diagnostic for `--render-launcher QUERY FILE`.
    func render(_ q: String, to path: String) {
        rescan()
        findFiles(fileTerm(q))
        RunLoop.main.run(until: Date().addingTimeInterval(1.5)) // Spotlight answers
        model.query = q; model.items = results(for: q)
        let rows = min(model.items.count, Self.maxRows)
        let v = NSHostingView(rootView: LauncherView(model: model).environmentObject(Store.shared))
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: Self.width, height: Self.field + CGFloat(rows) * Self.row + 2 * Self.padding + 1), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = v
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func selfTest() {
        assert(calculate("2*(3+4)^2") == 98 && calculate("10/4") == 2.5 && calculate("-3+5") == 2, "sums")
        assert(calculate("42") == nil && calculate("2+") == nil && calculate("hello") == nil && calculate("(1+2") == nil, "not sums")
        assert(format(98) == "98" && format(2.5) == "2.5", "sum formatting")
        assert(score("saf", "Safari")! > score("saf", "Messages Safari")!, "prefix beats a later word")
        assert(score("vsc", "Visual Studio Code") != nil && score("xyz", "Safari") == nil, "initials match, strangers don't")
        assert(emoji.contains { $0.glyph == "😀" && $0.name == "grinning face" } && emoji.count > 1000, "emoji by name")
        assert(shared.results(for: "theme").count == Palette.all.count && shared.results(for: "theme").allSatisfy { $0.id.hasPrefix("theme:") }, "theme lists every theme")
        assert(shared.results(for: "wallpaper").allSatisfy { $0.id.hasPrefix("wall:") }, "wallpaper lists wallpapers")
        assert(fileTerm("/ notes") == "notes" && fileTerm("~cv") == "cv" && fileTerm("ab") == nil && fileTerm(":smile") == nil && fileTerm("2+2") == nil, "file terms")
        print("launcher selftest ok")
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var items: [Launcher.Item] = []
    @Published var selected = 0
    @Published var focus = 0 // bumped on open: the field takes focus
    var still = NSPoint.zero // where the pointer was when results last changed: hovering only selects once it moves
}

private struct LauncherView: View {
    @ObservedObject var model: SearchModel
    @EnvironmentObject var store: Store
    @FocusState private var focused: Bool
    @Namespace private var hl
    private var s: DashStyle { DashStyle(t: store.bar.theme) }
    private var st: Chaval.Settings { store.settings }
    private var text: CGFloat { CGFloat(st.launcherFontSize) * 13 / 18 } // row titles, in step with the field

    var body: some View {
        let t = store.bar.theme, bg = NSColor(hex: t.bgHex), corner = CGFloat(st.launcherCorner)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if st.launcherSearchIcon {
                    Image(systemName: "magnifyingglass").font(.system(size: CGFloat(st.launcherFontSize) - 1, weight: .medium)).foregroundStyle(s.accent)
                }
                TextField("Search apps, files, actions, sums   ·   : emoji   / files   theme   wallpaper", text: $model.query)
                    .textFieldStyle(.plain).font(s.font(CGFloat(st.launcherFontSize))).focused($focused)
                    .onChange(of: model.query) { _, q in Launcher.shared.search(q) }
                    .onSubmit { Launcher.shared.choose(model.selected) }
                    .onKeyPress(.return, phases: .down) { k in // ⌘Return: show a file in Finder
                        guard k.modifiers.contains(.command) else { return .ignored }
                        Launcher.shared.reveal(model.selected); return .handled
                    }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) { Launcher.shared.close(); return .handled }
                    .onKeyPress(characters: .decimalDigits, phases: .down) { k in // ⌘1–⌘9: that result, at once
                        guard k.modifiers == .command, let d = Int(k.characters), d >= 1 else { return .ignored }
                        let i = Launcher.firstShown(model) + d - 1
                        guard i < model.items.count else { return .handled }
                        Launcher.shared.choose(i); return .handled
                    }
                    .onKeyPress(characters: .init(charactersIn: "np"), phases: .down) { k in
                        guard k.modifiers == .control else { return .ignored }
                        return move(k.characters == "n" ? 1 : -1)
                    }
            }
            .padding(.horizontal, min(16, Launcher.field * 0.4)).frame(height: Launcher.field)
            if !model.items.isEmpty {
                if st.launcherDivider { Rectangle().fill(s.fg.opacity(0.08)).frame(height: 1) }
                VStack(spacing: 0) {
                    // The rows on show follow the selection, so the arrows reach every result (a long theme list), not just the first few.
                    let first = Launcher.firstShown(model)
                    ForEach(Array(model.items.enumerated()).dropFirst(first).prefix(Launcher.maxRows), id: \.element.id) { i, it in
                        row(it, on: i == model.selected, number: i - first + 1)
                            .contentShape(Rectangle())
                            .onTapGesture { Launcher.shared.choose(i) }
                            .onContinuousHover { phase in
                                guard case .active = phase, model.selected != i, NSEvent.mouseLocation != model.still else { return }
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { model.selected = i }
                            }
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .padding(Launcher.padding)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top) // the panel's height animates; the content stays pinned to the top
        .foregroundStyle(s.fg)
        .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(nsColor: bg.withAlphaComponent(st.launcherOpacity))))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(s.accent.opacity(st.launcherBorder ? 1 : 0), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onChange(of: model.focus) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    private func move(_ d: Int) -> KeyPress.Result {
        let n = model.items.count
        if n > 0 { withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { model.selected = (model.selected + d + n) % n } }
        return .handled
    }

    private func row(_ it: Launcher.Item, on: Bool, number: Int) -> some View {
        let fill = on && !st.launcherSubtleHighlight, icon = max(10, min(Launcher.row - 14, 40))
        return HStack(spacing: Launcher.row < 30 ? 7 : 10) {
            if st.launcherIcons || it.glyph != nil { // an emoji is the result itself, so it always shows
                Group {
                    if let icon = it.icon { Image(nsImage: icon).resizable() }
                    else if let g = it.glyph { Text(g).font(.system(size: icon * 0.77)) }
                    else { Image(systemName: it.symbol ?? "circle").font(.system(size: icon * 0.58, weight: .medium)).foregroundStyle(fill ? s.onAccent : s.accent) }
                }
                .frame(width: icon, height: icon)
            }
            Text(it.title).font(s.font(text, on ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 8)
            if st.launcherSubtitles { Text(it.subtitle).font(s.font(text - 2)).opacity(0.6).lineLimit(1) }
            if st.launcherNumbers && number <= 9 { Text("⌘\(number)").font(s.font(text - 2, .medium)).opacity(0.45).monospacedDigit() }
        }
        .padding(.horizontal, Launcher.row < 30 ? 8 : 10).frame(height: Launcher.row)
        .foregroundStyle(fill ? s.onAccent : s.fg)
        .background {
            // One highlight that slides from row to row.
            if on { RoundedRectangle(cornerRadius: max(4, CGFloat(st.launcherCorner) - 6)).fill(fill ? s.accent : s.fg.opacity(0.1)).matchedGeometryEffect(id: "hl", in: hl) }
        }
    }
}
