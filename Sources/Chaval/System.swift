import AppKit
import ApplicationServices
import MachO

// MARK: - System Dock (hidden, never removed: it also runs Mission Control, Spaces and the app switcher)

enum SystemDock {
    private static let domain = "com.apple.dock" as CFString
    private static let keys = ["autohide", "autohide-delay", "autohide-time-modifier"]
    private static let none = "__none__"
    private static var saved: [String: Any]? { UserDefaults.standard.dictionary(forKey: "savedDock") }

    static func get(_ k: String) -> Any? { CFPreferencesCopyAppValue(k as CFString, domain) }
    private static func set(_ k: String, _ v: Any?) { CFPreferencesSetAppValue(k as CFString, v as CFPropertyList?, domain) }

    static func hide() {
        if saved == nil {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: keys.map { ($0, get($0) ?? none) }), forKey: "savedDock")
        }
        if get("autohide") as? Bool == true, (get("autohide-delay") as? Double ?? 0) >= 1000 { return }
        set("autohide", true); set("autohide-delay", 1000.0); set("autohide-time-modifier", 0.0)
        relaunch()
    }

    static func restore() {
        guard let saved else { return }
        for (k, v) in saved { set(k, v as? String == none ? nil : v) }
        UserDefaults.standard.removeObject(forKey: "savedDock")
        relaunch()
    }

    private static func relaunch() {
        CFPreferencesAppSynchronize(domain)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").forEach { $0.terminate() }
    }

    /// Pulls the user's current Dock layout and the settings that map onto Chaval's.
    static func importLayout(into store: Store) {
        func tileURL(_ tile: [String: Any]) -> (URL, String?)? {
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let s = file["_CFURLString"] as? String, let url = URL(string: s) else { return nil }
            return (url, data["bundle-identifier"] as? String)
        }
        var apps: [Item] = []
        for tile in get("persistent-apps") as? [[String: Any]] ?? [] {
            if (tile["tile-type"] as? String ?? "").contains("spacer") { apps.append(Item(kind: .spacer)); continue }
            if let (url, bid) = tileURL(tile), bid != "com.apple.finder" {
                apps.append(Item(kind: .app, path: url.path, bundleID: bid))
            }
        }
        var others: [Item] = []
        for tile in get("persistent-others") as? [[String: Any]] ?? [] {
            guard let (url, _) = tileURL(tile) else { continue }
            let data = tile["tile-data"] as? [String: Any] ?? [:]
            var item = Item(kind: tile["tile-type"] as? String == "directory-tile" ? .folder : .file, path: url.path)
            item.sort = [1: .name, 2: .dateAdded, 3: .dateModified, 4: .dateCreated, 5: .kind][data["arrangement"] as? Int ?? 2] ?? .dateAdded
            item.view = [1: .fan, 2: .grid, 3: .list][data["showas"] as? Int ?? 0] ?? .auto
            item.asStack = (data["displayas"] as? Int ?? 0) == 0
            others.append(item)
        }
        if others.isEmpty, let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            others.append(Item(kind: .folder, path: dl.path))
        }
        var s = store.settings
        if let v = get("tilesize") as? Double { s.iconSize = min(max(v, 24), 128) }
        if let v = get("largesize") as? Double { s.magnifiedSize = min(max(v, s.iconSize), 160) }
        if let v = get("magnification") as? Bool { s.magnify = v }
        if let v = get("orientation") as? String, let e = Edge(rawValue: v) { s.edge = e }
        if let v = get("show-recents") as? Bool { s.showRecents = v }
        if let v = get("minimize-to-application") as? Bool { s.minimizeIntoApp = v }
        if let v = get("showhidden") as? Bool { s.dimHidden = v }
        let autohide = saved?["autohide"] ?? get("autohide")
        s.autohide = autohide as? Bool ?? false
        store.settings = s
        store.pinned = [Item(kind: .finder, path: Item.finderPath)] + apps + others + [Item(kind: .trash)]
        UserDefaults.standard.set(true, forKey: "unifiedLayout")
        store.imported = true
    }

    /// Badge text ("3", "•") per app path, read from the hidden system Dock, which still receives every badge.
    static func badges() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var out: [String: String] = [:]
        for list in AX.children(root) where AX.get(list, kAXRoleAttribute) as String? == kAXListRole {
            for item in AX.children(list) {
                guard let label: String = AX.get(item, "AXStatusLabel"), !label.isEmpty,
                      let url: URL = AX.get(item, kAXURLAttribute) else { continue }
                out[url.standardizedFileURL.path] = label
            }
        }
        return out
    }
}

// MARK: - Window server screen reservation

/// The private call the Dock uses to reserve its strip. Whatever rect is registered here is carved out of every
/// display's visible frame, so zoom, Fill, tiling and window managers all stop at it natively.
enum WindowServer {
    private typealias Conn = @convention(c) () -> Int32
    private typealias Get = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias Set = @convention(c) (Int32, CGRect, Int32) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let cid: Int32? = dlsym(lib, "SLSMainConnectionID").map { unsafeBitCast($0, to: Conn.self)() }
    private static let getFn = dlsym(lib, "SLSGetDockRectWithReason").map { unsafeBitCast($0, to: Get.self) }
    private static let setFn = dlsym(lib, "SLSSetDockRectWithReason").map { unsafeBitCast($0, to: Set.self) }

    /// Global top-left coordinates.
    static var dockRect: (rect: CGRect, reason: Int32)? {
        guard let cid, let getFn else { return nil }
        var r = CGRect.zero, reason: Int32 = 0
        return getFn(cid, &r, &reason) == 0 ? (r, reason) : nil
    }

    /// Returns false if the call is missing or refused (then callers fall back to moving windows).
    @discardableResult
    static func setDockRect(_ r: CGRect) -> Bool {
        guard let cid, let setFn else { return false }
        if dockRect?.rect == r { return true }
        return setFn(cid, r, dockRect?.reason ?? 3) == 0
    }
}

/// macOS desktops (Spaces), read and changed through SkyLight. Moving another app's window to a desktop goes through
/// the bridged window-management operation macOS itself uses, which needs no SIP changes; the dispatcher is a
/// non-exported symbol, found by walking SkyLight's symbol table. After dinky (MIT, github.com/mikker/Dinky) and
/// yabai. Private API: a macOS update can remove it, and then moving just does nothing.
enum Desktops {
    private typealias Conn = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Perform = @convention(c) (UnsafeMutableRawPointer) -> Int64
    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let cid: Int32 = dlsym(lib, "SLSMainConnectionID").map { unsafeBitCast($0, to: Conn.self)() } ?? 0
    private static let copySpaces = dlsym(lib, "SLSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopySpaces.self) }
    private static let perform: Perform? = symbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation")
        .map { unsafeBitCast($0, to: Perform.self) }

    /// Each display's desktops (user Spaces only, not full-screen apps) in order, and the one showing.
    static var displays: [(id: String, desktops: [UInt64], current: UInt64)] {
        guard let raw = copySpaces?(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return raw.map { d in
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            let cur = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
            return (d["Display Identifier"] as? String ?? "", spaces, cur)
        }
    }

    /// Whether the screen is showing a full-screen app's Space (not one of the desktops), as macOS itself says.
    static func inFullscreenSpace(_ s: NSScreen) -> Bool {
        let all = displays
        guard let d = all.first(where: { $0.id == uuid(s) }) ?? (all.count == 1 ? all.first : nil), d.current != 0 else { return false }
        return !d.desktops.contains(d.current)
    }

    private static func uuid(_ s: NSScreen?) -> String? {
        (s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
    }

    /// The main display's desktops and the one showing.
    /// ponytail: main display only; per-display when the dock follows the cursor across separate Spaces.
    private static var main: (desktops: [UInt64], current: UInt64)? {
        let all = displays, uuid = uuid(NSScreen.main)
        return (all.first { $0.id == uuid } ?? all.first { $0.id == "Main" } ?? all.first).map { ($0.desktops, $0.current) }
    }

    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddToSpace = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private static let spaceCreate = dlsym(lib, "SLSSpaceCreate").map { unsafeBitCast($0, to: SpaceCreate.self) }
    private static let spaceLevel = dlsym(lib, "SLSSpaceSetAbsoluteLevel").map { unsafeBitCast($0, to: SpaceLevel.self) }
    private static let showSpaces = dlsym(lib, "SLSShowSpaces").map { unsafeBitCast($0, to: ShowSpaces.self) }
    private static let addToSpace = dlsym(lib, "SLSSpaceAddWindowsAndRemoveFromSpaces").map { unsafeBitCast($0, to: AddToSpace.self) }

    /// A space of Chaval's own, shown above every desktop (SketchyBar's trick): what's in it stays still while desktops slide.
    private static let above: UInt64? = {
        guard let spaceCreate, let spaceLevel, let showSpaces else { return nil }
        let s = spaceCreate(cid, 1, 0)
        guard s != 0 else { return nil }
        _ = spaceLevel(cid, s, 0)
        _ = showSpaces(cid, [NSNumber(value: s)] as CFArray)
        return s
    }()

    /// Moves a window into that space, so switching desktops leaves it where it is (the bar and the dock).
    /// Call after each orderFront: ordering a window in can put it back on the current desktop.
    static func pinAbove(_ w: NSWindow) {
        guard let above, let addToSpace, w.windowNumber > 0 else { return }
        _ = addToSpace(cid, above, [NSNumber(value: w.windowNumber)] as CFArray, 7)
        // A window just ordered in lands on the current desktop a moment later; take it off again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if w.isVisible { _ = addToSpace(cid, above, [NSNumber(value: w.windowNumber)] as CFArray, 7) } }
    }

    /// The desktops (space IDs) a window is on; for checking `pinAbove`.
    static func spaces(of w: NSWindow) -> [UInt64] {
        (spacesFor?(cid, 7, [NSNumber(value: w.windowNumber)] as CFArray)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
    }
    static var aboveSpace: UInt64? { above }

    /// How many desktops the main display has, and which (0-based) is showing.
    static var current: (count: Int, index: Int) {
        guard let d = main else { return (0, 0) }
        return (d.desktops.count, d.desktops.firstIndex(of: d.current) ?? 0)
    }

    private typealias OrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<DarwinBoolean>) -> Int32
    private static let orderedIn = dlsym(lib, "SLSWindowIsOrderedIn").map { unsafeBitCast($0, to: OrderedIn.self) }

    /// Whether a window is actually shown on some desktop. Apps that only hide a window when you close it (Discord,
    /// WhatsApp) leave it on its desktop, ordered out; the window list can't tell that from one on another desktop.
    static func isShown(_ id: CGWindowID) -> Bool {
        guard let orderedIn else { return true }
        var v: DarwinBoolean = true
        return orderedIn(cid, id, &v) != 0 || v.boolValue // unknown: assume shown
    }

    private typealias SpacesFor = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let spacesFor = dlsym(lib, "SLSCopySpacesForWindows").map { unsafeBitCast($0, to: SpacesFor.self) }

    /// Every display's desktops in order, numbered as Mission Control and ⌃1…⌃9 number them.
    static var allDesktops: [UInt64] { displays.flatMap(\.desktops) }

    /// Which desktop (1-based, in `all`) a window is on; nil when it's on none (closed into its app, say).
    static func desktopNumber(of id: CGWindowID, in all: [UInt64]) -> Int? {
        guard let spaces = spacesFor?(cid, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.lazy.compactMap { all.firstIndex(of: $0.uint64Value) }.first.map { $0 + 1 }
    }

    /// For each desktop of the main display, in order, the apps with a window on it, frontmost first.
    static func apps() -> [[NSRunningApplication]] {
        guard let d = main else { return [] }
        let regular = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.isRegular }
            .map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var out = [[NSRunningApplication]](repeating: [], count: d.desktops.count)
        for w in CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, let app = regular[pid],
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  b.width >= 80, b.height >= 80, // tooltips, popovers and helper slivers
                  isShown(id), // Discord or WhatsApp "closed": hidden, but still on its desktop
                  let spaces = spacesFor?(cid, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { continue }
            for s in spaces { if let i = d.desktops.firstIndex(of: s.uint64Value), !out[i].contains(app) { out[i].append(app) } }
        }
        return out
    }

    /// Desktop `n` (1-based) of the display a window is on.
    static func desktop(_ n: Int, for window: CGWindowID) -> UInt64? {
        let all = displays
        let screen = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]])?.first
            .flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .flatMap { r in NSScreen.screens.first { s in
                let f = s.frame, h = NSScreen.screens[0].frame.maxY
                return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height).contains(CGPoint(x: r.midX, y: r.midY)) } }
        let uuid = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        // With "Displays have separate Spaces" off there is one entry, called "Main".
        let d = all.first { $0.id == uuid } ?? all.first { $0.id == "Main" } ?? all.first
        guard let d, d.desktops.indices.contains(n - 1) else { return nil }
        return d.desktops[n - 1]
    }

    @discardableResult
    static func move(_ window: CGWindowID, toDesktop n: Int) -> Bool {
        guard let perform, let space = desktop(n, for: window),
              let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type else { return false }
        // alloc/init by hand: init consumes the object it's given (+1) and returns one it owns (+1).
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector, NSArray, UInt64) -> UnsafeMutableRawPointer?
        let sel = NSSelectorFromString("initWithWindows:spaceID:")
        guard let m = class_getInstanceMethod(cls, sel), let fresh = class_createInstance(cls, 0) as AnyObject? else { return false }
        let raw = unsafeBitCast(method_getImplementation(m), to: Init.self)(Unmanaged.passRetained(fresh).toOpaque(), sel,
                                                                             [NSNumber(value: Int32(bitPattern: window))] as NSArray, space)
        guard let raw else { return false }
        let op = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        _ = perform(Unmanaged.passUnretained(op).toOpaque())
        return true
    }

    /// A non-exported symbol, by walking SkyLight's Mach-O symbol table.
    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let image = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let i = (0..<_dyld_image_count()).first(where: { _dyld_get_image_name($0).map { String(cString: $0) } == image }),
              let header = _dyld_get_image_header(i) else { return nil }
        let slide = _dyld_get_image_vmaddr_slide(i)
        var linkedit: UnsafePointer<segment_command_64>?, symtab: UnsafePointer<symtab_command>?
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self)
            if lc.pointee.cmd == LC_SEGMENT_64 {
                let seg = cmd.assumingMemoryBound(to: segment_command_64.self)
                if withUnsafeBytes(of: seg.pointee.segname, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == "__LINKEDIT" { linkedit = seg }
            } else if lc.pointee.cmd == LC_SYMTAB { symtab = cmd.assumingMemoryBound(to: symtab_command.self) }
            cmd = cmd.advanced(by: Int(lc.pointee.cmdsize))
        }
        guard let le = linkedit?.pointee, let st = symtab?.pointee,
              let base = UnsafeRawPointer(bitPattern: Int(le.vmaddr) - Int(le.fileoff) + slide) else { return nil }
        let strings = base.advanced(by: Int(st.stroff)).assumingMemoryBound(to: CChar.self)
        let syms = base.advanced(by: Int(st.symoff)).assumingMemoryBound(to: nlist_64.self)
        for k in 0..<Int(st.nsyms) where strcmp(strings.advanced(by: Int(syms[k].n_un.n_strx)), name) == 0 {
            return UnsafeMutableRawPointer(bitPattern: Int(syms[k].n_value) + slide)
        }
        return nil
    }

    static func selfTest() {
        assert(perform != nil, "the bridged dispatcher is still in SkyLight")
        assert(NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") != nil, "the move operation class exists")
        let ds = displays
        assert(!ds.isEmpty && ds.allSatisfy { !$0.desktops.isEmpty }, "desktops can be listed")
        assert(apps().count == current.count, "apps are listed per desktop")
        assert(spacesFor != nil, "the window-to-desktop lookup is still in SkyLight")
        assert(orderedIn != nil, "the shown-or-hidden lookup is still in SkyLight")
        // An invisible window of our own goes into the space above the desktops.
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
        w.alphaValue = 0; w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let before = spaces(of: w)
        pinAbove(w)
        // Our own space isn't a desktop, so the lookup no longer finds the window on any.
        assert(aboveSpace != nil && !before.isEmpty && spaces(of: w).isEmpty, "windows can be pinned above the desktops")
        w.orderOut(nil)
        print("desktops selftest ok (\(ds.map { "\($0.desktops.count) desktops" }.joined(separator: ", ")))")
    }
}

// MARK: - Accessibility

enum AX {
    static func get<T>(_ e: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] { get(e, kAXChildrenAttribute) ?? [] }

    static func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        guard AXIsProcessTrusted() else { return [] }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.3) // a hung app must not freeze the dock
        return (get(el, kAXWindowsAttribute) as [AXUIElement]? ?? [])
            .filter { get($0, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole }
    }

    static func title(_ w: AXUIElement) -> String { get(w, kAXTitleAttribute) ?? "" }

    /// Window frame in global top-left-origin coordinates (the same space CGWindowList uses).
    static func frame(_ w: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = value(w, kAXPositionAttribute), let sv = value(w, kAXSizeAttribute),
              AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    private static func value(_ e: AXUIElement, _ attr: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }
    static func isMinimized(_ w: AXUIElement) -> Bool { get(w, kAXMinimizedAttribute) ?? false }

    static func focus(_ w: AXUIElement, of app: NSRunningApplication) {
        if isMinimized(w) { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        bringForward(app, reopen: false)
    }
}

/// Focuses one window instantly, the way yabai does (no SIP changes needed): bring its process to the front for that
/// window, make the window key, raise it. Going through LaunchServices instead (all a background app may do publicly)
/// takes a few hundred milliseconds, too slow for focus that follows the mouse.
enum FastFocus {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let setFront = dlsym(sky, "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFront.self) }
    private static let post = dlsym(sky, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: PostRecord.self) }
    private static let psnFor = dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW), "GetProcessForPID")
        .map { unsafeBitCast($0, to: GetPSN.self) }

    static var available: Bool { setFront != nil && post != nil && psnFor != nil }

    /// False if it couldn't (then use AX.focus).
    @discardableResult
    static func focus(_ w: AXUIElement, id: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront, let post, let psnFor else { return false }
        var psn = [UInt32](repeating: 0, count: 2) // a ProcessSerialNumber
        guard psn.withUnsafeMutableBytes({ psnFor(pid, $0.baseAddress!) }) == 0 else { return false }
        _ = psn.withUnsafeMutableBytes { setFront($0.baseAddress!, id, 0x200) } // kCPSUserGenerated
        // Two event records that make the window key (the layout yabai uses).
        for kind: UInt8 in [1, 2] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8; bytes[0x08] = kind; bytes[0x3a] = 0x10
            withUnsafeBytes(of: id.littleEndian) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
            for i in 0x20..<0x30 { bytes[i] = 0xff }
            _ = psn.withUnsafeMutableBytes { p in bytes.withUnsafeMutableBytes { post(p.baseAddress!, $0.baseAddress!) } }
        }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        return true
    }
}

/// Activates an app the way the Dock does. Going through LaunchServices works from a background app
/// (plain activate() is refused under cooperative activation) and sends the reopen event, so an app
/// with no windows opens one.
func bringForward(_ app: NSRunningApplication, reopen: Bool = true) {
    guard reopen || !app.activate(options: .activateAllWindows), let url = app.bundleURL else { return }
    launch(url)
}

func launch(_ appURL: URL, then: ((NSRunningApplication?) -> Void)? = nil) {
    let c = NSWorkspace.OpenConfiguration()
    c.activates = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: c) { app, _ in
        if let then { DispatchQueue.main.async { then(app) } }
    }
}

/// Posts .chavalWindowsChanged when any app minimizes or restores a window (or, listing every window, opens, closes or retitles one). Event-driven; no polling.
final class WindowWatcher {
    private var observers: [pid_t: AXObserver] = [:]

    func sync(_ apps: [NSRunningApplication]) {
        guard AXIsProcessTrusted() else { return }
        let pids = Set(apps.map(\.processIdentifier))
        for (pid, obs) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observers[pid] = nil
        }
        for pid in pids where observers[pid] == nil {
            var obs: AXObserver?
            guard AXObserverCreate(pid, { _, element, name, _ in
                let n = name as String
                if [kAXWindowResizedNotification, kAXWindowCreatedNotification].contains(n) {
                    NotificationCenter.default.post(name: .chavalWindowFrame, object: element)
                }
                // Opening, closing, retitling and focus only matter to a dock that lists every window.
                if [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification].contains(n)
                    || Store.shared.settings.windowsOnly && n != kAXWindowResizedNotification {
                    NotificationCenter.default.post(name: .chavalWindowsChanged, object: element)
                }
            }, &obs) == .success, let obs else { continue }
            let el = AXUIElementCreateApplication(pid)
            for n in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXWindowResizedNotification,
                      kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                      kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(obs, el, n as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observers[pid] = obs
        }
    }
}

// MARK: - Trash, login items, scripting

enum Trash {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    /// Calls back on main with whether the Trash has items.
    static func isFull(_ done: @escaping (Bool) -> Void) {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            return done(items.contains { $0 != ".DS_Store" })
        }
        DispatchQueue.global(qos: .utility).async { // no Full Disk Access: ask Finder instead
            let n = Int(Script.shell("/usr/bin/osascript", ["-e", "tell application \"Finder\" to count items of trash"])) ?? 0
            DispatchQueue.main.async { done(n > 0) }
        }
    }

    static func empty() {
        let a = NSAlert()
        a.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        a.informativeText = "You can't undo this action."
        a.addButton(withTitle: "Empty Trash"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { Script.run("tell application \"Finder\" to empty trash") }
    }
}

enum Script {
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.standardOutput = out; p.standardError = nil
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LoginItems {
    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    static func contains(_ url: URL) -> Bool {
        let names = Script.run("tell application \"System Events\" to get the path of every login item")
        return (0..<(names?.numberOfItems ?? 0)).contains { names?.atIndex($0 + 1)?.stringValue == url.path }
            || names?.stringValue == url.path
    }

    static func set(_ url: URL, _ on: Bool) {
        Script.run(on
            ? "tell application \"System Events\" to make login item at end with properties {path:\"\(esc(url.path))\", hidden:false}"
            : "tell application \"System Events\" to delete (every login item whose path is \"\(esc(url.path))\")")
    }
}

/// LaunchAgent with KeepAlive-on-crash, so a crash never leaves you without a dock.
enum LaunchAgent {
    static let label = "dev.chaval.dock"
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var isOn: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func set(_ on: Bool) {
        // Off only deletes the plist: booting the job out would kill this very process.
        guard on else { try? FileManager.default.removeItem(at: url); return }
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [exe], "RunAtLoad": true,
                                    "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive",
                                    "LimitLoadToSessionType": "Aqua"]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        (plist as NSDictionary).write(to: url, atomically: true)
        let target = "gui/\(getuid())"
        Script.shell("/bin/launchctl", ["bootstrap", target, url.path])
        Script.shell("/bin/launchctl", ["kickstart", "\(target)/\(label)"]) // the launchd copy replaces this one
    }
}

extension NSRunningApplication {
    private static let lock = NSLock()
    private static var policies: [pid_t: (regular: Bool, at: CFTimeInterval)] = [:]

    /// `activationPolicy == .regular`, remembered for 30 s per process: asking is a round trip to LaunchServices that
    /// cost ~38 ms per re-tile on main. An app that changes policy (a menu bar app opening its window) is seen within 30 s.
    var isRegular: Bool {
        let pid = processIdentifier, now = CACurrentMediaTime()
        if let c = Self.lock.withLock({ Self.policies[pid] }), now - c.at < 30 { return c.regular }
        let r = activationPolicy == .regular
        Self.lock.withLock { Self.policies[pid] = (r, now) }
        return r
    }
}
