import AppKit

/// The wallpaper stays put while desktops slide, as on Hyprland. macOS slides each desktop's wallpaper with it and
/// won't let anyone change that, so Chaval draws the wallpaper itself, at desktop level, in its own space that sits above
/// the desktops (the one the bar and dock live in): app windows slide over it, macOS's own wallpaper slides unseen below.
final class StillWallpaper {
    static let shared = StillWallpaper()
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var shown: [CGDirectDisplayID: URL] = [:]
    private var timer: Timer?

    private init() {
        let nc = NotificationCenter.default
        for n in [Notification.Name.chavalWallpaperChanged, .chavalChanged, NSApplication.didChangeScreenParametersNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.sync() }
        }
        // A wallpaper set elsewhere (System Settings) says nothing: look now and then (one URL read per screen).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sync() }
    }

    func sync() {
        guard Store.shared.settings.stillWallpaper else {
            panels.values.forEach { $0.orderOut(nil) }; panels = [:]; shown = [:]
            return
        }
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.displayID, $0) })
        for (id, p) in panels where screens[id] == nil { p.orderOut(nil); panels[id] = nil; shown[id] = nil }
        for (id, s) in screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: s) else { continue }
            let p = panels[id] ?? make()
            panels[id] = p
            if p.frame != s.frame { p.setFrame(s.frame, display: false) }
            if shown[id] != url {
                shown[id] = url
                let scale = s.backingScaleFactor, size = s.frame.size
                DispatchQueue.global(qos: .utility).async { // decoding a 6K picture takes a moment; off the main thread
                    let img = StillWallpaper.fill(url, size: CGSize(width: size.width * scale, height: size.height * scale))
                    DispatchQueue.main.async { p.contentView?.layer?.contents = img; p.contentView?.layer?.contentsScale = scale }
                }
            }
            if !p.isVisible { p.orderFrontRegardless(); Desktops.pinAbove(p) }
        }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))) // under desktop icons and every window
        p.isOpaque = true; p.hasShadow = false; p.ignoresMouseEvents = true; p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let v = NSView(); v.wantsLayer = true; v.layer?.contentsGravity = .resizeAspectFill; v.layer?.backgroundColor = .black
        p.contentView = v
        return p
    }

    /// The picture decoded at the screen's size (aspect fill), not at its own (a 6K image would hold ~100 MB).
    static func fill(_ url: URL, size: CGSize) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 1.5)] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }
}
