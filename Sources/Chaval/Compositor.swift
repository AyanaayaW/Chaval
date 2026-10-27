import AppKit
import ScreenCaptureKit

/// Tiling animations the way a Linux compositor does them. macOS won't let Chaval move other apps' window pictures, so
/// it borrows them: one capture of the screen (~13 ms), shown in an overlay over the desktop, where each tiled window
/// becomes a picture that Core Animation springs to its new tile on the GPU, locked to the display, every frame. The
/// real windows jump to their tiles underneath at once and have the whole glide to redraw; then the overlay fades away.
/// Nothing is hidden or parked, so no app can end up stuck off screen. Contents are still for the length of the glide.
final class Compositor {
    static let shared = Compositor()

    /// A capture the overlay's layers show directly: a GPU surface (an IOSurface) shared by every layer, each showing
    /// its part through contentsRect. Nothing is copied, so the overlay is on screen the frame it's committed; handing
    /// Core Animation full-screen images to copy made it ~240 ms late, and the real window showed before its pop-in.
    struct Pic {
        let contents: Any; let width: Int; let height: Int
        /// The capture's pixel buffer, held while the picture is in use: holding only its surface let ScreenCaptureKit
        /// hand that memory to the next capture while it was still on screen, which flashed it black for a frame.
        var owner: AnyObject? = nil
        /// Where every window really was (window server, global top-left) when this was captured: each picture is cut
        /// from there and its glide starts there, whatever the tiler believes (an app may not have moved it yet).
        var bounds: [CGWindowID: CGRect] = [:]
        /// The unit rect for `px` (pixels, top-left origin) as contentsRect wants it (bottom-left origin).
        func unit(_ px: CGRect) -> CGRect {
            let w = CGFloat(width), h = CGFloat(height)
            return CGRect(x: px.minX / w, y: 1 - px.maxY / h, width: px.width / w, height: px.height / h)
        }
    }

    static func grab(_ f: SCContentFilter, _ cfg: SCStreamConfiguration) async -> Pic? {
        let before = windowBounds()
        guard let sb = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: f, configuration: cfg), let pb = sb.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return nil }
        // Only windows that didn't move while the picture was taken (~15 ms) are trusted to be where it shows them.
        let after = windowBounds()
        return Pic(contents: surface, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                   owner: pb, bounds: before.filter { after[$0.key] == $0.value })
    }

    static func windowBounds() -> [CGWindowID: CGRect] {
        var out: [CGWindowID: CGRect] = [:]
        for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            // Chaval's own (window borders) aren't in its captures, so they mustn't be cut from them either.
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != getpid(), let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { continue }
            out[id] = b
        }
        return out
    }

    /// A tiled window: where it is, where it goes (top-left global coordinates, as Accessibility uses).
    struct Win {
        let id: CGWindowID; let from: CGRect; let to: CGRect
        var crop: CGRect? = nil // where its picture is in the capture, when that's not `from` (a new window, drawn on its tile)
        var appear = false      // just opened: pops in on its tile
        var carried = false     // its start is where the previous overlay was showing it (not where it really is)
        var vanish = false      // just closed (not drawn: it's already gone from the screen); lets the glide start from the settled picture
    }

    private var content: SCShareableContent?
    private var backdrops: [CGDirectDisplayID: Pic] = [:]   // the bare desktop, refreshed after each glide
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var capturing = false
    /// Captures started early (alongside the tiler's window scan), by display, with when they were asked for.
    private var early: [CGDirectDisplayID: (at: CFTimeInterval, shot: Task<Pic?, Never>)] = [:]

    private final class Overlay {
        let panel: NSPanel
        var proxies: [CGWindowID: CALayer] = [:]
        var end: DispatchWorkItem?
        var landed = false // steered onto where the apps really put their windows (once, just before the hand-over)
        init(_ p: NSPanel) { panel = p }
    }

    var busy: Bool { capturing || !overlays.isEmpty }

    /// Warms ScreenCaptureKit up (the first capture is slow) and caches the desktop pictures.

    func prepare() {
        Task {
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for s in NSScreen.screens { await refreshBackdrop(s) }
        }
    }

    /// Starts capturing every screen now, while the tiler is still finding the windows, so a glide that follows
    /// doesn't wait for its picture: the capture (~20 ms) overlaps the scan instead of coming after it.
    func prefetch() {
        guard let content else { return }
        let me = content.applications.filter { $0.processID == getpid() }
        for s in NSScreen.screens {
            let did = s.displayID, now = CACurrentMediaTime()
            guard let d = content.displays.first(where: { $0.displayID == did }), overlays[did] == nil,
                  now - (early[did]?.at ?? 0) > 0.15 else { continue } // a burst of rescans shares one picture (or an opening's)
            let cfg = config(s)
            early[did] = (now, Task {
                await Compositor.grab(SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), cfg)
            })
            // Unused (nothing moved): let the ~30 MB picture go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in if self?.early[did]?.at == now { self?.early[did] = nil } }
        }
    }

    /// The latest picture of each screen, for covering a window that just opened until the glide takes over.
    private var lastShot: [CGDirectDisplayID: (at: CFTimeInterval, image: Pic)] = [:]
    private var covers: [NSPanel] = []
    /// Every overlay panel made, so none can outlive its use: a sweep every 2 s takes down any that nothing holds
    /// (seen unheld twice in a row, so one being handed over mid-capture isn't caught).
    private var made: [NSPanel] = [], unheld: Set<ObjectIdentifier> = []
    private lazy var sweeper: Timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sweep() }

    private func track(_ p: NSPanel) { made.append(p); _ = sweeper }

    private func sweep() {
        let held = Set(overlays.values.map { ObjectIdentifier($0.panel) } + covers.map(ObjectIdentifier.init))
        var keep: [NSPanel] = [], nextUnheld: Set<ObjectIdentifier> = []
        for p in made {
            let id = ObjectIdentifier(p)
            if held.contains(id) || capturing { keep.append(p); continue }
            if !p.isVisible { continue } // already down: forget it
            if unheld.contains(id) { p.orderOut(nil); continue }
            nextUnheld.insert(id); keep.append(p)
        }
        made = keep; unheld = nextUnheld
    }
    /// A glide asked for while a capture was still in flight: run when it lands (the newest wins).
    private var queued: (() -> Void)?

    /// Hides a window that just opened where the app put it: shows what was behind it (from the latest picture of the
    /// screen) on top until the glide's overlay covers the screen. macOS shows a window before announcing it, so the
    /// first frame or two can't be helped; after that, this.
    func cover(_ r: CGRect) {
        guard let s = NSScreen.screens.first(where: { Tiler.topLeftFrame($0).intersects(r) }) else { return }
        let did = s.displayID
        let img = lastShot[did].flatMap { CACurrentMediaTime() - $0.at < 30 ? $0.image : nil } ?? backdrops[did]
        guard let img else { return }
        let scale = CGFloat(img.width) / s.frame.width, l = local(r, s)
        let piece = img.unit(CGRect(x: l.minX * scale, y: l.minY * scale, width: l.width * scale, height: l.height * scale).integral)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let p = NSPanel(contentRect: NSRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        p.ignoresMouseEvents = true; p.hasShadow = false; p.isOpaque = true; p.animationBehavior = .none
        p.collectionBehavior = [.transient, .ignoresCycle]
        let v = NSView(); v.wantsLayer = true; v.layer?.contents = img.contents; v.layer?.contentsRect = piece; v.layer?.contentsScale = scale
        p.contentView = v
        p.orderFrontRegardless()
        covers.append(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.uncover(p) } // never left behind
    }

    private func uncover(_ p: NSPanel? = nil) {
        let gone = p.map { [$0] } ?? covers
        gone.forEach { $0.orderOut(nil) }
        covers.removeAll { gone.contains($0) }
    }

    /// Pictures of windows that just opened, captured on their own (the screen shot leaves them out).
    private var opened: [CGWindowID: Task<Pic?, Never>] = [:]

    /// A window just opened. Captures every screen without it (so the other windows' pictures are clean) and the window
    /// by itself, so the glide can pop it in on its tile. Started the moment it appears; the glide waits on these.
    func opening(_ id: CGWindowID) {
        let lookup = Task { () -> (SCShareableContent?, SCWindow?) in
            // Not just on-screen windows: at the moment it's announced, a new window may not count as on screen yet.
            let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return (all, all?.windows.first { $0.windowID == id })
        }
        let now = CACurrentMediaTime()
        // Every screen, overlay up or not (Chaval's own windows are never in its captures): skipping this while a glide
        // played meant the next capture had the new window in it, drawn into the window behind it at its app's spot.
        for s in NSScreen.screens {
            let did = s.displayID, cfg = config(s)
            early[did] = (now, Task {
                let (all, win) = await lookup.value
                guard let all, let d = all.displays.first(where: { $0.displayID == did }) else { return nil }
                let leave = all.windows.filter { $0.owningApplication?.processID == getpid() } + (win.map { [$0] } ?? [])
                return await Compositor.grab(SCContentFilter(display: d, excludingWindows: leave), cfg)
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in if self?.early[did]?.at == now { self?.early[did] = nil } }
        }
        opened[id] = Task {
            guard let win = await lookup.value.1 else { return nil }
            let cfg = SCStreamConfiguration(), k = NSScreen.main?.backingScaleFactor ?? 2
            cfg.width = Int(win.frame.width * k); cfg.height = Int(win.frame.height * k); cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            return await Compositor.grab(SCContentFilter(desktopIndependentWindow: win), cfg)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.opened[id] = nil }
    }

    private func config(_ s: NSScreen) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = Int(s.frame.width * s.backingScaleFactor); cfg.height = Int(s.frame.height * s.backingScaleFactor)
        cfg.showsCursor = false
        return cfg
    }

    /// Glides `wins` (every tiled window on `screen`, moving or not). `place` writes the real frames; it's called
    /// once the overlay covers the screen, or straight away if capturing isn't possible (then there's no animation).
    func glide(_ wins: [Win], on screen: NSScreen, hide: Set<CGWindowID>, active: CGWindowID?, duration: Double, place: @escaping () -> Void) {
        let did = screen.displayID
        // Mid-glide: the same windows retarget from wherever they are. Different windows (one opened or closed): a fresh
        // capture, but the old overlay stays up until the new one is ready, and every window carries on from where it
        // is on screen right now, so nothing flashes or jumps.
        // A capture in flight: this glide waits its turn. Checked before anything else touches the overlay that's up;
        // the other way round, it was let go of here but never taken down, and stayed on screen as ghost windows.
        if capturing {
            queued = { [weak self] in self?.glide(wins, on: screen, hide: hide, active: active, duration: duration, place: place) }
            return
        }
        var carry: [CGWindowID: CGRect] = [:], retiring: Overlay?
        if let o = overlays[did] {
            if Set(wins.map(\.id)) == Set(o.proxies.keys) {
                for w in wins { if let l = o.proxies[w.id] { spring(l, to: up(local(w.to, screen), screen), duration) } }
                finish(o, did, after: duration)
                return place()
            }
            for (id, l) in o.proxies { let bw = l.borderWidth; carry[id] = global((l.presentation() ?? l).frame.insetBy(dx: bw, dy: bw), screen) }
            o.end?.cancel()
            retiring = o; overlays[did] = nil
        }
        guard let content, let display = content.displays.first(where: { $0.displayID == did }) else {
            retiring?.panel.orderOut(nil); prepare(); uncover(); return place()
        }
        // A window closed and the settled picture (which still has it) is fresh: no capture at all, so the others start
        // filling its space the next frame, and it can shrink away instead of just vanishing.
        if wins.contains(where: \.vanish), let settled = lastShot[did], CACurrentMediaTime() - settled.at < 2.5,
           !wins.contains(where: \.appear), let back = backdrops[did] {
            early[did] = nil
            // Not drawn shrinking away after all: macOS has already taken it off screen by the time it says it's gone
            // (about two frames), so bringing it back to fade out flashed it.
            show(wins.filter { !$0.vanish }, shot: settled.image, backdrop: back, on: screen, hide: hide, active: active, duration: duration)
            if let retiring { DispatchQueue.main.async { retiring.panel.orderOut(nil) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: place)
            return
        }
        let wins = wins.filter { !$0.vanish } // no settled picture to show it in: it just goes
        capturing = true
        let me = content.applications.filter { $0.processID == getpid() }
        let cfg = config(screen)
        // A capture started with the scan, if it's this pass's (recent); else one now.
        let pre = early.removeValue(forKey: did).flatMap { CACurrentMediaTime() - $0.at < 0.4 ? $0.shot : nil }
        // Native feel: the motion starts this frame, from the settled picture, when it shows every window where it really
        // is. The fresh capture (20–60 ms) then swaps in under the moving pictures, and only then do the real windows move
        // (so the capture still sees them in place).
        if !wins.contains(where: \.appear), let settled = lastShot[did], CACurrentMediaTime() - settled.at < 3, let back = backdrops[did],
           wins.allSatisfy({ w in carry[w.id] != nil || settled.image.bounds[w.id].map { abs($0.minX - w.from.minX) < 2 && abs($0.minY - w.from.minY) < 2 && abs($0.width - w.from.width) < 2 && abs($0.height - w.from.height) < 2 } ?? false }) {
            let start = wins.map { w in carry[w.id].map { Win(id: w.id, from: $0, to: w.to, crop: w.crop ?? w.from, carried: true) } ?? w }
            show(start, shot: settled.image, backdrop: back, on: screen, hide: hide, active: active, duration: duration)
            if let retiring { DispatchQueue.main.async { retiring.panel.orderOut(nil) } }
            let o = overlays[did]
            Task {
                let fresh: Pic?
                if let pre { fresh = await pre.value } else {
                    fresh = await Compositor.grab(SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), cfg)
                }
                await MainActor.run {
                    self.capturing = false
                    defer { if let next = self.queued { self.queued = nil; next() } }
                    if let fresh {
                        self.lastShot[did] = (CACurrentMediaTime(), fresh)
                        if let o, self.overlays[did] === o { self.recut(o, start, shot: fresh, on: screen) }
                    }
                    place()
                }
            }
            return
        }
        let newcomers = wins.filter(\.appear).compactMap { w in opened.removeValue(forKey: w.id).map { (w.id, $0) } }
        Task {
            let shot: Pic?
            if let pre { shot = await pre.value } else {
                shot = await Compositor.grab(SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), cfg)
            }
            var pictures: [CGWindowID: Pic] = [:]
            for (id, t) in newcomers { if let img = await t.value { pictures[id] = img } }
            await MainActor.run {
                self.capturing = false
                if let shot { self.lastShot[did] = (CACurrentMediaTime(), shot) }
                defer { if let next = self.queued { self.queued = nil; next() } }
                guard let shot, let back = self.backdrops[did] else { retiring?.panel.orderOut(nil); self.prepare(); self.uncover(); return place() }
                // Each window's picture comes from where it really is; its glide starts where the old overlay shows it.
                let start = wins.map { w in carry[w.id].map { Win(id: w.id, from: $0, to: w.to, crop: w.crop ?? w.from, appear: w.appear, carried: true) } ?? w }
                self.show(start, shot: shot, backdrop: back, on: screen, hide: hide, active: active, duration: duration, pictures: pictures)
                if let retiring { DispatchQueue.main.async { retiring.panel.orderOut(nil) } } // the new overlay is up: swap
                // One frame for the overlay to reach the screen before the windows start moving under it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: place)
            }
        }
    }

    private func show(_ wins: [Win], shot: Pic, backdrop: Pic, on screen: NSScreen, hide: Set<CGWindowID>, active: CGWindowID?, duration: Double,
                      pictures: [CGWindowID: Pic] = [:]) {
        let did = screen.displayID
        let (root, proxies) = scene(wins, shot: shot, backdrop: backdrop, on: screen, hide: hide, active: active, pictures: pictures)
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1) // over every app, under the dock and bar
        p.isOpaque = false // so macOS still counts the windows below as visible and they keep drawing
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.animationBehavior = .none
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.layer = root; v.wantsLayer = true
        p.contentView = v
        p.orderFrontRegardless()
        track(p)
        DispatchQueue.main.async { self.uncover() } // the overlay hides everything now
        let o = Overlay(p)
        o.proxies = proxies
        overlays[did] = o
        for w in wins { if let l = o.proxies[w.id] { w.appear ? (w.from == w.to ? popIn(l, duration) : spring(l, to: up(local(w.to, screen), screen), duration)) : w.vanish ? popOut(l, duration) : spring(l, to: up(local(w.to, screen), screen), duration) } }
        finish(o, did, after: duration)
    }

    /// A window opening: solid from the first frame (a fade showed the wallpaper while the window beside it was already
    /// shrinking away), growing into its tile from just smaller. It's above the others, which shrink under it.
    private func popIn(_ l: CALayer, _ duration: Double) {
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.87; grow.toValue = 1 // Hyprland's "popin 87%"
        grow.duration = Compositor.length(duration) * 1.08; grow.timingFunction = Compositor.easeOutQuint
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        fade.duration = 0.17; fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0.5, 0.75, 1) // Omarchy's almostLinear
        l.add(grow, forKey: "grow"); l.add(fade, forKey: "fadeIn")
    }

    /// Omarchy's curve for every move: (0.23, 1, 0.32, 1). About 90% of the way in the first third, then a long soft
    /// landing, so a change shows at once and you still see where everything went.
    static let easeOutQuint = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// The tiler's speed setting (a spring response, ~0.23 s) as the curve's length (~0.38 s, Omarchy's windows speed).
    static func length(_ response: Double) -> Double { max(0.15, response * 1.65) }

    /// A window closing: it shrinks a little and fades out (Hyprland's "popout"), quicker than it came in.
    private func popOut(_ l: CALayer, _ duration: Double) {
        let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = 1; shrink.toValue = 0.87
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        for a in [shrink, fade] { a.duration = 0.15; a.timingFunction = CAMediaTimingFunction(name: .linear) } // Omarchy: 150 ms, linear
        CATransaction.begin(); CATransaction.setDisableActions(true); l.opacity = 0; l.transform = CATransform3DMakeScale(0.87, 0.87, 1); CATransaction.commit()
        l.add(shrink, forKey: "shrink"); l.add(fade, forKey: "fade")
    }

    /// The overlay's layers: desktop, then each tiled window's picture (with its border) at `from`, then untiled windows.
    private func scene(_ wins: [Win], shot: Pic, backdrop: Pic, on screen: NSScreen, hide: Set<CGWindowID>, active: CGWindowID?,
                       borders: Bool = Store.shared.settings.borders, pictures: [CGWindowID: Pic] = [:]) -> (CALayer, [CGWindowID: CALayer]) {
        let scale = CGFloat(shot.width) / screen.frame.width
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: screen.frame.size)
        var proxies: [CGWindowID: CALayer] = [:]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let back = CALayer()
        back.frame = root.bounds; back.contents = backdrop.contents; back.contentsScale = scale
        root.addSublayer(back)

        // Windows that aren't tiled (floating, panels) stay as they are, above the tiles, cut from the same capture.
        let tiled = Set(wins.map(\.id))
        let others = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w -> CGRect? in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let id = w[kCGWindowNumber as String] as? CGWindowID, !tiled.contains(id), !hide.contains(id),
                  (w[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return up(local(b, screen), screen)
        }

        let st = Store.shared.settings, bw = borders ? CGFloat(st.borderWidth) : 0, radius = CGFloat(st.borderRadius)
        for w in wins {
            // Cut from where it really is in this picture; start there too, unless it pops in on its tile or carries on
            // from the previous overlay.
            let real = shot.bounds[w.id]
            let start = w.appear || w.carried ? w.from : real ?? w.from
            let from = local(start, screen).insetBy(dx: -bw, dy: -bw), src = local(real ?? w.crop ?? w.from, screen).insetBy(dx: -bw, dy: -bw)
            let px = CGRect(x: src.minX * scale, y: src.minY * scale, width: src.width * scale, height: src.height * scale).integral
            let l = CALayer()
            if let own = pictures[w.id] { l.contents = own.contents } // an opening window comes in its own picture
            else { l.contents = shot.contents; l.contentsRect = shot.unit(px) } // its part of the one shared surface
            // Shrinking: the picture keeps its size and is cropped (squashing text looked broken). Growing: it stretches into
            // its new size until the real window takes over.
            l.contentsGravity = w.to.width < start.width - 1 || w.to.height < start.height - 1 ? .topLeft : .resize
            l.contentsScale = scale // pixel for pixel on this screen: no resampling, so at rest it's exactly the window
            l.frame = up(from, screen)
            l.cornerRadius = radius + bw
            l.cornerCurve = .continuous
            l.masksToBounds = true
            l.borderWidth = bw // drawn over the gap the crop includes, exactly where the real border is
            l.borderColor = Borders.colour(focused: w.id == active).cgColor
            root.addSublayer(l)
            proxies[w.id] = l
        }
        if !others.isEmpty {
            let top = CALayer()
            top.frame = root.bounds; top.contents = shot.contents; top.contentsScale = scale
            let mask = CAShapeLayer()
            let path = CGMutablePath(); others.forEach { path.addRect($0) }
            mask.path = path
            top.mask = mask
            root.addSublayer(top)
        }
        CATransaction.commit()
        return (root, proxies)
    }

    /// Diagnostic for `--compositortest FILE`: builds the overlay for the windows on screen, at rest, without showing
    /// it, and writes how far its pixels are from the screen's inside those windows (0 = it lines up exactly).
    static func selfCheck(to path: String) async {
        let me = Compositor()
        await me.refreshBackdrop(NSScreen.screens[0])
        guard let s = NSScreen.screens.first, let content = me.content, let d = content.displays.first(where: { $0.displayID == s.displayID }),
              let back = me.backdrops[s.displayID] else { try? "no capture".write(toFile: path, atomically: true, encoding: .utf8); return }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(s.frame.width * s.backingScaleFactor); cfg.height = Int(s.frame.height * s.backingScaleFactor); cfg.showsCursor = false
        let mine = content.applications.filter { $0.processID == getpid() || $0.bundleIdentifier == "dev.chaval.dock" }
        guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingApplications: mine, exceptingWindows: []), configuration: cfg) else { return }
        let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w -> Win? in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerName as String] as? String) != "Chaval", let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), b.width > 200 else { return nil }
            return Win(id: id, from: b, to: b)
        }
        // A CGImage-backed Pic: the same contentsRect maths as the live overlay's surface, in a form render(in:) can draw.
        let pic = Pic(contents: shot, width: shot.width, height: shot.height)
        let (root, _) = await MainActor.run { me.scene(wins, shot: pic, backdrop: back, on: s, hide: [], active: nil, borders: false) } // pictures only
        let W = shot.width, H = shot.height
        func pixels(_ draw: (CGContext) -> Void) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: W * H * 4)
            let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(ctx); return buf
        }
        let a = pixels { $0.draw(shot, in: CGRect(x: 0, y: 0, width: W, height: H)) }
        let b = pixels { ctx in ctx.scaleBy(x: CGFloat(W) / s.frame.width, y: CGFloat(H) / s.frame.height); root.render(in: ctx) }
        var lines: [String] = []
        let scale = CGFloat(W) / s.frame.width
        // Control: the plain capture in one layer, drawn the same way. Whatever it differs by is the test's, not the overlay's.
        let plain = CALayer(); plain.frame = root.frame; plain.contents = shot
        let c = pixels { ctx in ctx.scaleBy(x: CGFloat(W) / s.frame.width, y: CGFloat(H) / s.frame.height); plain.render(in: ctx) }
        var cd = 0.0, cn = 0
        for i in stride(from: 0, to: a.count - 4, by: 4 * 997) { cd += Double(abs(Int(a[i]) - Int(c[i])) + abs(Int(a[i + 1]) - Int(c[i + 1])) + abs(Int(a[i + 2]) - Int(c[i + 2]))) / 3; cn += 1 }
        lines.append("control (one plain layer): \(String(format: "%.2f", cd / Double(cn))) / 255")
        for w in wins {
            let r = me.local(w.from, s).insetBy(dx: 24, dy: 24) // inside the window, clear of its rounded corners
            func diff(_ dx: Int, _ dy: Int, rows: Bool) -> Double {
                var d = 0.0, n = 0
                for y in stride(from: Int(r.minY * scale), to: Int(r.maxY * scale), by: 7) {
                    for x in stride(from: Int(r.minX * scale), to: Int(r.maxX * scale), by: 7) {
                        let i = ((rows ? H - 1 - y : y) * W + x) * 4, j = ((rows ? H - 1 - (y + dy) : y + dy) * W + x + dx) * 4
                        guard i >= 0, j >= 0, i + 2 < a.count, j + 2 < b.count else { continue }
                        d += Double(abs(Int(a[i]) - Int(b[j])) + abs(Int(a[i + 1]) - Int(b[j + 1])) + abs(Int(a[i + 2]) - Int(b[j + 2]))) / 3; n += 1
                    }
                }
                return d / Double(max(n, 1))
            }
            var best = (0, 0, Double.infinity, true)
            for rows in [true, false] { for dy in -4...4 { for dx in -4...4 { let d = diff(dx, dy, rows: rows); if d < best.2 { best = (dx, dy, d, rows) } } } }
            lines.append("window \(w.id) \(Int(w.from.width))x\(Int(w.from.height)): at rest \(String(format: "%.2f", diff(0, 0, rows: true))) / 255; best \(String(format: "%.2f", best.2)) at offset \(best.0),\(best.1) px rowsBottomUp=\(best.3)")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Swaps a fresher picture into a playing overlay, each window cut from where it really is in it.
    private func recut(_ o: Overlay, _ wins: [Win], shot: Pic, on screen: NSScreen) {
        let scale = CGFloat(shot.width) / screen.frame.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for w in wins {
            guard let l = o.proxies[w.id], let real = shot.bounds[w.id] else { continue }
            let src = local(real, screen).insetBy(dx: -l.borderWidth, dy: -l.borderWidth)
            l.contents = shot.contents
            l.contentsRect = shot.unit(CGRect(x: src.minX * scale, y: src.minY * scale, width: src.width * scale, height: src.height * scale).integral)
        }
        CATransaction.commit()
    }

    /// Moves a window's picture to its tile (with its border) on the render server: no per-frame work here at all.
    /// Interrupted, it carries on from wherever it is on screen, moving fast at once (a spring restarted from a standstill
    /// braked visibly; this is what Hyprland does).
    private func spring(_ l: CALayer, to r: CGRect, _ duration: Double) {
        let bw = l.borderWidth, to = r.insetBy(dx: -bw, dy: -bw)
        let now = l.presentation() ?? l
        for (key, from, end) in [("position", NSValue(point: now.position), NSValue(point: CGPoint(x: to.midX, y: to.midY))),
                                 ("bounds.size", NSValue(size: now.bounds.size), NSValue(size: to.size))] {
            let s = CABasicAnimation(keyPath: key)
            s.fromValue = from; s.toValue = end
            s.duration = Compositor.length(duration); s.timingFunction = Compositor.easeOutQuint
            l.add(s, forKey: key)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.position = CGPoint(x: to.midX, y: to.midY); l.bounds.size = to.size
        CATransaction.commit()
    }

    /// When the springs have settled the real windows have long redrawn: fade the overlay out to show them.
    private func finish(_ o: Overlay, _ did: CGDirectDisplayID, after duration: Double) {
        o.end?.cancel()
        // Faded while the curves' last pixel or two of motion still plays: an overlay left completely still over the whole
        // screen gets shown directly by macOS, and fading out of that blended with black for ~90 ms (a black flash).
        let settle = Compositor.length(duration) * 0.8
        let w = DispatchWorkItem { [weak self] in
            // Where the apps really put their windows (Ghostty snaps to its character grid): steer the pictures exactly
            // there first, so the hand-over to the real windows doesn't jump.
            if let self, !o.landed, let s = NSScreen.screens.first(where: { $0.displayID == did }) {
                o.landed = true
                let real = Compositor.windowBounds()
                var steered = false
                for (id, l) in o.proxies {
                    guard let r = real[id] else { continue }
                    let want = self.up(self.local(r, s), s).insetBy(dx: -l.borderWidth, dy: -l.borderWidth)
                    if abs(want.minX - l.frame.minX) > 1 || abs(want.minY - l.frame.minY) > 1 || abs(want.width - l.frame.width) > 1 || abs(want.height - l.frame.height) > 1 {
                        self.spring(l, to: self.up(self.local(r, s), s), 0.07); steered = true
                    }
                }
                if steered { return self.finish(o, did, after: 0.09) }
            }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.09
                o.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.overlays[did] === o { self?.overlays[did] = nil }
                o.panel.orderOut(nil)
                if let s = NSScreen.screens.first(where: { $0.displayID == did }) { Task { await self?.refreshBackdrop(s); await self?.refreshSettled(s) } }
            })
        }
        o.end = w
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: w)
    }

    /// The screen as it is now (Chaval's own windows left out), for closing glides and covering a new window. Taken after every glide and every 2 s.
    private func refreshSettled(_ s: NSScreen) async {
        guard let content, let d = content.displays.first(where: { $0.displayID == s.displayID }) else { return }
        let me = content.applications.filter { $0.processID == getpid() }
        guard let pic = await Compositor.grab(SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), config(s)) else { return }
        await MainActor.run { if overlays[s.displayID] == nil { lastShot[s.displayID] = (CACurrentMediaTime(), pic) } }
    }
    private var settledTimer: Timer?
    /// ponytail: re-captures the screen every 2 s while tiling is on (~15 ms of GPU each); a freeze shows at most
    /// 2 s-old window contents for its ~70 ms. Event-driven refreshes would need to know when apps redraw, which macOS doesn't say.
    func keepSettled() {
        settledTimer?.invalidate()
        settledTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.capturing, self.overlays.isEmpty else { return }
            for s in NSScreen.screens { Task { await self.refreshSettled(s) } }
        }
    }

    private func remove(_ did: CGDirectDisplayID) {
        guard let o = overlays.removeValue(forKey: did) else { return }
        o.end?.cancel()
        o.panel.orderOut(nil)
    }

    /// The desktop alone (wallpaper and icons): what shows where a window has moved away from.
    private func refreshBackdrop(_ s: NSScreen) async {
        guard let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        content = all
        guard let d = all.displays.first(where: { $0.displayID == s.displayID }) else { return }
        let windows = all.windows.filter { $0.windowLayer >= 0 } // everything above the desktop, Chaval's own included
        let cfg = SCStreamConfiguration()
        cfg.width = Int(s.frame.width * s.backingScaleFactor); cfg.height = Int(s.frame.height * s.backingScaleFactor)
        cfg.showsCursor = false
        if let img = await Compositor.grab(SCContentFilter(display: d, excludingWindows: windows), cfg) {
            await MainActor.run { backdrops[s.displayID] = img }
        }
    }

    /// An overlay layer's frame → global top-left (the inverse of `up(local(...))`).
    private func global(_ f: CGRect, _ s: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: f.minX + s.frame.minX, y: (s.frame.height - f.maxY) + (top - s.frame.maxY), width: f.width, height: f.height)
    }

    /// Overlay layers use AppKit's bottom-left origin (a flipped layer tree draws its pictures upside down).
    private func up(_ r: CGRect, _ s: NSScreen) -> CGRect { CGRect(x: r.minX, y: s.frame.height - r.maxY, width: r.width, height: r.height) }

    /// Global top-left frame → this screen's top-left coordinates (the capture's pixel layout).
    private func local(_ r: CGRect, _ s: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX - s.frame.minX, y: r.minY - (top - s.frame.maxY), width: r.width, height: r.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}

