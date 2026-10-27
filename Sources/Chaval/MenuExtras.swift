import AppKit
import ScreenCaptureKit

/// Another process's menu bar icon, read through Accessibility. Pressing it opens that app's real menu.
/// On this macOS status items aren't separate windows any more (the menu bar draws them all), so AX is the only handle.
struct MenuExtra {
    let key: String      // bundle ID + the item's identifier or description; stable across launches, used for hiding
    let bundleID: String
    let name: String     // what the item calls itself, else the app's name
    let identifier: String
    let title: String    // text the item shows (Amphetamine's "∞", a timer, the clock)
    let pid: pid_t
    let hasMenu: Bool    // a classic menu (Rectangle, BetterDisplay): AXPress opens it instantly; others need a real click
    let el: AXUIElement
    let frame: CGRect    // where it really is (global, top-left origin); x < 0 = hidden for lack of room (the notch)
    var x: CGFloat { frame.minX }
    var onScreen: Bool { frame.minX >= 0 && frame.width > 0 }
    var isSystem: Bool { bundleID.hasPrefix("com.apple.") }
    /// Changes whenever what the bar draws for this item would.
    var signature: String { "\(key)|\(title)|\(Int(frame.minX))|\(Int(frame.width))" }
}

enum MenuExtras {
    /// Every app's menu bar icons, left to right as the real menu bar has them. Blocks (AX), so call it off the main thread.
    static func scan() -> [MenuExtra] {
        guard AXIsProcessTrusted() else { return [] }
        let me = getpid()
        var out: [MenuExtra] = []
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me && !app.isTerminated {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15) // a hung app must not stall the bar
            guard let bar: AXUIElement = AX.get(root, "AXExtrasMenuBar") else { continue }
            let bid = app.bundleIdentifier ?? app.localizedName ?? "\(app.processIdentifier)"
            for var el in AX.children(bar) {
                // MenuBarAgent (Control Center, battery, clock…) wraps each item in a hosting group.
                if AX.get(el, kAXRoleAttribute) as String? == kAXGroupRole, let inner = AX.children(el).first { el = inner }
                let ident: String = AX.get(el, kAXIdentifierAttribute) ?? ""
                let attributed: NSAttributedString? = AX.get(el, "AXAttributedDescription")
                let desc: String = AX.get(el, kAXDescriptionAttribute) ?? attributed?.string ?? AX.get(el, kAXHelpAttribute) ?? ""
                let title: String = (AX.get(el, kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (ident.hasSuffix(".clock") ? AX.get(el, kAXValueAttribute) ?? "" : "")
                let name = desc.isEmpty ? app.localizedName ?? bid : desc
                out.append(MenuExtra(key: bid + ":" + (ident.isEmpty ? desc : ident), bundleID: bid, name: name, identifier: ident,
                                     title: title.trimmingCharacters(in: .whitespaces),
                                     pid: app.processIdentifier,
                                     hasMenu: AX.children(el).contains { AX.get($0, kAXRoleAttribute) as String? == kAXMenuRole }, el: el, frame: AX.frame(el) ?? .zero))
            }
        }
        return out.sorted { $0.x < $1.x }
    }

    /// AX actions block until the target answers; never on the main thread.
    static func press(_ el: AXUIElement) {
        DispatchQueue.global(qos: .userInteractive).async { AXUIElementPerformAction(el, kAXPressAction as CFString) }
    }

    /// The front app's menus (Apple menu first), so the bar can stand in for the real menu bar.
    static func appMenus(_ app: NSRunningApplication) -> [(title: String, el: AXUIElement)] {
        guard AXIsProcessTrusted() else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let bar: AXUIElement = AX.get(root, kAXMenuBarAttribute) else { return [] }
        return AX.children(bar).compactMap { el in
            let t: String = AX.get(el, kAXTitleAttribute) ?? ""
            return t.isEmpty ? nil : (t, el)
        }
    }

    /// SF Symbol for Apple's items that publish no image.
    static func symbol(for e: MenuExtra) -> String {
        let id = (e.identifier + " " + e.name).lowercased()
        if id.contains("audiovideo") { return micInUse() ? "mic.fill" : "video.fill" } // what's being used: the mic, else the camera
        let map: [(String, String)] = [
            ("controlcenter", "switch.2"), ("control cent", "switch.2"), ("wifi", "wifi"), ("wi-fi", "wifi"),
            ("battery", "battery.75percent"), ("sound", "speaker.wave.2.fill"), ("bluetooth", "dot.radiowaves.left.and.right"),
            ("focus", "moon.fill"), ("display", "sun.max.fill"), ("airdrop", "airplayaudio"), ("screenmirroring", "rectangle.on.rectangle"),
            ("nowplaying", "play.fill"), ("now playing", "play.fill"), ("spotlight", "magnifyingglass"), ("siri", "mic.fill"),
            ("textinput", "keyboard"), ("keyboard", "keyboard"), ("user", "person.crop.circle"), ("timemachine", "clock.arrow.circlepath"),
            ("vpn", "network.badge.shield.half.filled"), ("accessibility", "accessibility"), ("weather", "cloud.sun.fill"), ("clock", "clock"),
        ]
        return map.first { id.contains($0.0) }?.1 ?? "circle.grid.2x2.fill"
    }

    /// Whether some app is recording from the default microphone right now.
    static func micInUse() -> Bool {
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return true }
        var running: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        a.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &running) == noErr else { return true }
        return running != 0
    }

    /// Diagnostic: `Chaval --dump-extras FILE` writes what AX sees (needs Accessibility).
    static func dump(to path: String) {
        var lines = ["trusted \(AXIsProcessTrusted())"]
        for e in scan() { lines.append("\(Int(e.x))\t\(e.key)\t\(e.name)\t\(e.title)\tmenu:\(e.hasMenu)") }
        if let front = NSWorkspace.shared.frontmostApplication {
            lines.append("front \(front.localizedName ?? "?"): " + appMenus(front).map(\.title).joined(separator: " | "))
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: false, encoding: .utf8)
    }
}

/// Copies the real menu bar icons off the screen (needs Screen Recording) so the bar can redraw them in its theme colour.
enum MenuBarCapture {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks once; macOS applies a new grant after Chaval restarts.
    static func requestOnce() {
        guard !allowed, !UserDefaults.standard.bool(forKey: "askedScreenCapture") else { return }
        UserDefaults.standard.set(true, forKey: "askedScreenCapture")
        CGRequestScreenCaptureAccess()
    }

    /// The strip as the screen shows it without Chaval's own windows; `rect` is in global top-left points.
    static func strip(_ rect: CGRect, scale: CGFloat, _ done: @escaping (CGImage?) -> Void) {
        guard allowed else { return done(nil) }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content, let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) ?? content.displays.first
            else { return done(nil) }
            let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            cfg.width = Int(rect.width * scale); cfg.height = Int(rect.height * scale)
            cfg.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: mine), configuration: cfg) { img, _ in done(img) }
        }
    }

    /// One icon as a template image: how far each pixel stands out from the menu bar behind it. The background is
    /// read per column from the strip's top and bottom rows, which icons don't reach, so any wallpaper works.
    static func glyph(_ strip: CGImage, x: CGFloat, width: CGFloat, scale: CGFloat) -> NSImage? {
        let crop = CGRect(x: (x * scale).rounded(), y: 0, width: (width * scale).rounded(), height: CGFloat(strip.height))
        // ponytail: assumes the strip starts at the menu bar's top edge (true for the main display)
        guard let img = strip.cropping(to: crop) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 12 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lum(_ i: Int) -> Double { (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255 }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var any = false
        // Rows just inside the real menu bar: the strip can be a point taller than it, so its last rows may show
        // whatever window sits under the menu bar. Median of four, so one stray row can't skew it.
        let bgs = (0..<w).map { col -> Double in
            let edge = [2, 3, h - 6, h - 5].map { lum(($0 * w + col) * 4) }.sorted()
            return (edge[1] + edge[2]) / 2
        }
        // A filled pill behind the symbol (the camera/mic indicator, a highlighted item): one shade that differs from
        // the bar and covers much of the item. It's background too; only what's drawn on it is the glyph.
        var bins = [Int](repeating: 0, count: 32)
        for row in 0..<h { for col in 0..<w where abs(lum((row * w + col) * 4) - bgs[col]) > 0.08 { bins[min(31, Int(lum((row * w + col) * 4) * 32))] += 1 } }
        let mode = bins.indices.max { bins[$0] < bins[$1] }!
        let plate: Double? = bins[mode] > w * h * 3 / 10 ? (Double(mode) + 0.5) / 32 : nil
        for col in 0..<w {
            let bg = bgs[col], range = max(bg > 0.5 ? bg : 1 - bg, 0.25)
            for row in 0..<h {
                let i = (row * w + col) * 4
                var a = abs(lum(i) - bg) / range
                if let plate { a = min(a, max(0, abs(lum(i) - plate) - 1.0 / 32) / max(plate > 0.5 ? plate : 1 - plate, 0.25)) }
                a = a < 0.12 ? 0 : min(1, (a - 0.12) / 0.7)
                let v = UInt8(a * 255)
                out[i] = v; out[i + 1] = v; out[i + 2] = v; out[i + 3] = v
                if v > 0 { any = true }
            }
        }
        guard any, let octx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = octx.makeImage() else { return nil }
        let ns = NSImage(cgImage: cg, size: NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
        ns.isTemplate = true
        return ns
    }
}

extension MenuBarCapture {
    /// Dark menu bar, a white glyph in the middle, and a light window peeking in under the last two rows (the bug that
    /// boxed every icon): only the glyph may come out opaque.
    static func selfTest() {
        let w = 40, h = 78
        let strip = Icons.draw(w, h) {
            NSColor(white: 0.1, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            NSColor(white: 0.95, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: 2).fill() // window below (bottom rows)
            NSColor.white.setFill(); NSRect(x: 15, y: 30, width: 10, height: 18).fill()                // glyph
        }!
        let g = glyph(strip, x: 0, width: CGFloat(w), scale: 1)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(g, in: CGRect(x: 0, y: 0, width: w, height: h))
        func alpha(_ x: Int, _ yUp: Int) -> UInt8 { px[((h - 1 - yUp) * w + x) * 4 + 3] }
        assert(alpha(20, 39) > 200, "glyph is opaque")
        assert(alpha(5, 39) == 0 && alpha(35, 60) == 0, "menu bar background is transparent")
        // The camera indicator: a grey pill under the glyph is background too.
        let pill = Icons.draw(w, h) {
            NSColor(white: 0.1, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            NSColor(white: 0.45, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 2, y: 12, width: 36, height: 54), xRadius: 10, yRadius: 10).fill()
            NSColor.white.setFill(); NSRect(x: 15, y: 30, width: 10, height: 18).fill()
        }!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(glyph(pill, x: 0, width: CGFloat(w), scale: 1)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: 0, y: 0, width: w, height: h))
        assert(alpha(20, 39) > 200 && alpha(8, 39) == 0 && alpha(30, 60) == 0, "pill is dropped, its symbol kept")
        print("glyph selftest ok")
    }
}
