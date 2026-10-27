import AppKit
import Carbon.HIToolbox

/// A shortcut that runs a shell command (what skhd's launcher lines did).
struct KeyCommand: Codable, Equatable, Identifiable {
    var id = UUID()
    var keys: String
    var command: String

    init(keys: String, command: String) { self.keys = keys; self.command = command }

    /// An entry without an id (hand-edited) still loads, with a new one.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keys = try c.decode(String.self, forKey: .keys)
        command = try c.decode(String.self, forKey: .command)
    }
}

/// Every global shortcut Chaval owns, written skhd style ("alt + shift - h"). Settings → Keys overrides any of them;
/// an empty shortcut turns one off.
enum HotKeys {
    enum Action: String, CaseIterable {
        case focusLeft, focusDown, focusUp, focusRight, swapLeft, swapDown, swapUp, swapRight
        case newTerminal, focusNext, focusPrevious, promote, narrower, wider, taller, shorter, resetSplit, zoom, float, fullscreen, close
        case toggleTiling, retile, nextLayout, moreMain, fewerMain
        case desktop1, desktop2, desktop3, desktop4, desktop5, desktop6, desktop7, desktop8, desktop9, desktop10, desktopPrevious, desktopNext
        case moveTo1, moveTo2, moveTo3, moveTo4, moveTo5, moveTo6, moveTo7, moveTo8, moveTo9, moveTo10, nextScreen, previousScreen
        case dashboard, dock, topBar, settings, nextWallpaper, launcher

        /// The desktop a "desktopN" or "moveToN" action is about (1–10).
        var desk: Int? { Int(rawValue.drop { !$0.isNumber }) }

        var group: String {
            switch self {
            case .toggleTiling, .retile, .nextLayout, .moreMain, .fewerMain: return "Tiling"
            case .desktop1, .desktop2, .desktop3, .desktop4, .desktop5, .desktop6, .desktop7, .desktop8, .desktop9, .desktop10, .desktopPrevious, .desktopNext,
                 .moveTo1, .moveTo2, .moveTo3, .moveTo4, .moveTo5, .moveTo6, .moveTo7, .moveTo8, .moveTo9, .moveTo10, .nextScreen, .previousScreen: return "Desktops"
            case .dashboard, .dock, .topBar, .settings, .nextWallpaper, .launcher: return "Chaval"
            default: return "Windows"
            }
        }

        var title: String {
            switch self {
            case .focusLeft: return "Focus left"
            case .focusDown: return "Focus down"
            case .focusUp: return "Focus up"
            case .focusRight: return "Focus right"
            case .swapLeft: return "Swap left"
            case .swapDown: return "Swap down"
            case .swapUp: return "Swap up"
            case .swapRight: return "Swap right"
            case .newTerminal: return "New terminal (opens on its tile)"
            case .focusNext: return "Focus next window"
            case .focusPrevious: return "Focus previous window"
            case .promote: return "Make main window"
            case .narrower: return "Main window narrower"
            case .wider: return "Main window wider"
            case .taller: return "Window taller"
            case .shorter: return "Window shorter"
            case .resetSplit: return "Reset split"
            case .zoom: return "Zoom (fill the screen)"
            case .float: return "Float / tile window"
            case .fullscreen: return "Native full screen"
            case .close: return "Close window"
            case .toggleTiling: return "Tiling on / off"
            case .retile: return "Re-tile now"
            case .nextLayout: return "Next layout (main · grid · accordion)"
            case .moreMain: return "One more main window"
            case .fewerMain: return "One fewer main window"
            case .desktop1, .desktop2, .desktop3, .desktop4, .desktop5, .desktop6, .desktop7, .desktop8, .desktop9, .desktop10: return "Desktop \(desk!)"
            case .moveTo1, .moveTo2, .moveTo3, .moveTo4, .moveTo5, .moveTo6, .moveTo7, .moveTo8, .moveTo9, .moveTo10: return "Move window to desktop \(desk!)"
            case .nextScreen: return "Move window to next monitor"
            case .previousScreen: return "Move window to previous monitor"
            case .desktopPrevious: return "Previous desktop"
            case .desktopNext: return "Next desktop"
            case .dashboard: return "Dashboard"
            case .launcher: return "Launcher (search apps)"
            case .dock: return "Hide / show dock"
            case .topBar: return "Hide / show top bar"
            case .settings: return "Chaval settings"
            case .nextWallpaper: return "Next wallpaper"
            }
        }

        /// The same keys skhd + yabai used here, so nothing has to be relearned.
        var defaultKeys: String {
            switch self {
            case .focusLeft: return "alt - h"
            case .focusDown: return "alt - j"
            case .focusUp: return "alt - k"
            case .focusRight: return "alt - l"
            case .swapLeft: return "alt + shift - h"
            case .swapDown: return "alt + shift - j"
            case .swapUp: return "alt + shift - k"
            case .swapRight: return "alt + shift - l"
            case .newTerminal: return "cmd - return"
            case .focusNext: return "alt - ]"
            case .focusPrevious: return "alt - ["
            case .promote: return "alt + shift - return"
            case .narrower: return "alt + ctrl - h"
            case .wider: return "alt + ctrl - l"
            case .taller: return "alt + ctrl - j"
            case .shorter: return "alt + ctrl - k"
            case .resetSplit: return "alt + ctrl - 0"
            case .zoom: return "alt - f"
            case .float: return "alt - t"
            case .fullscreen: return "alt + shift - f"
            case .close: return "alt - q"
            case .toggleTiling: return "alt + shift - t"
            case .retile: return "alt + shift - r"
            case .nextLayout: return "alt + shift - space"
            case .moreMain: return "alt + shift - equal"
            case .fewerMain: return "alt + shift - minus"
            case .desktop1, .desktop2, .desktop3, .desktop4, .desktop5, .desktop6, .desktop7, .desktop8, .desktop9, .desktop10: return "alt - \(desk! % 10)"
            case .moveTo1, .moveTo2, .moveTo3, .moveTo4, .moveTo5, .moveTo6, .moveTo7, .moveTo8, .moveTo9, .moveTo10: return "alt + shift - \(desk! % 10)"
            case .nextScreen: return "alt + shift - period"
            case .previousScreen: return "alt + shift - comma"
            case .desktopPrevious: return "alt + ctrl - left"
            case .desktopNext: return "alt + ctrl - right"
            case .dashboard: return "alt - d"
            case .launcher: return "cmd - space"
            case .dock: return "ctrl + alt - d"
            case .topBar: return "alt + shift - b"
            case .settings: return "alt - comma"
            case .nextWallpaper: return "alt + shift - w"
            }
        }

        var keys: String { Store.shared.settings.keys[rawValue] ?? defaultKeys }

        func run() {
            let t = Tiler.shared
            switch self {
            case .focusLeft: t.run(.focus(.west))
            case .focusDown: t.run(.focus(.south))
            case .focusUp: t.run(.focus(.north))
            case .focusRight: t.run(.focus(.east))
            case .swapLeft: t.run(.swap(.west))
            case .swapDown: t.run(.swap(.south))
            case .swapUp: t.run(.swap(.north))
            case .swapRight: t.run(.swap(.east))
            case .newTerminal: NewTerminal.open()
            case .focusNext: t.run(.next)
            case .focusPrevious: t.run(.previous)
            case .promote: t.run(.promote)
            case .narrower: t.run(.narrower)
            case .wider: t.run(.wider)
            case .taller: t.run(.taller)
            case .shorter: t.run(.shorter)
            case .resetSplit: t.run(.resetSplit)
            case .zoom: t.run(.zoom)
            case .float: t.run(.float)
            case .fullscreen: t.run(.fullscreen)
            case .close: t.run(.close)
            case .toggleTiling: Store.shared.settings.tiling.toggle()
            case .retile: t.retile()
            case .nextLayout: t.run(.nextLayout)
            case .moreMain: t.run(.moreMain)
            case .fewerMain: t.run(.fewerMain)
            // macOS's own "Switch to Desktop N" (⌃N) and ⌃←/⌃→ shortcuts, sent as keys: no private APIs, no cursor.
            case .desktop1, .desktop2, .desktop3, .desktop4, .desktop5, .desktop6, .desktop7, .desktop8, .desktop9, .desktop10:
                let n = desk!, key = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0][n - 1]
                HotKeys.lastDesk = n
                HotKeys.send(key, .maskControl)
                // macOS's Dock (which owns these shortcuts) sometimes stops honouring all but ⌃1 until it restarts. If nothing
                // moved, restart it (once a minute at most) and ask again once it's back.
                // Only for the latest press: switching on quickly isn't a failure (it restarted the Dock and pulled you back).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let c = Desktops.current, now = CACurrentMediaTime()
                    guard HotKeys.lastDesk == n, n <= c.count, c.index + 1 != n, now - HotKeys.lastDockRestart > 60 else { return }
                    HotKeys.lastDockRestart = now
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").forEach { $0.terminate() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if HotKeys.lastDesk == n { HotKeys.send(key, .maskControl) } }
                }
            // Moves the window, then follows it there, as yabai's `--space N; space --focus N` did.
            case .moveTo1, .moveTo2, .moveTo3, .moveTo4, .moveTo5, .moveTo6, .moveTo7, .moveTo8, .moveTo9, .moveTo10:
                let n = desk!
                guard let w = Tiler.focusedWindow(), Desktops.move(w, toDesktop: n) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Action(rawValue: "desktop\(n)")?.run() }
            case .nextScreen: t.run(.toScreen(1))
            case .previousScreen: t.run(.toScreen(-1))
            case .desktopPrevious, .desktopNext:
                let c = Desktops.current, n = c.index + (self == .desktopNext ? 2 : 0) // the neighbour, 1-based
                let key = self == .desktopNext ? kVK_RightArrow : kVK_LeftArrow
                HotKeys.lastDesk = n
                HotKeys.send(key, [.maskControl, .maskSecondaryFn])
            case .dashboard: Dashboard.shared.toggle()
            case .launcher: Launcher.shared.toggle()
            case .dock: Store.shared.settings.autohide.toggle()
            case .topBar: Store.shared.bar.enabled.toggle()
            case .settings: SettingsWindow.show()
            case .nextWallpaper:
                let files = Themes.wallpapers(Themes.palette)
                guard !files.isEmpty else { return }
                let cur = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
                Themes.setWallpaper(files[((files.firstIndex { $0 == cur } ?? -1) + 1) % files.count], for: Themes.palette)
            }
        }
    }

    private static var refs: [EventHotKeyRef] = []
    private static var last: (keys: [String: String], commands: [KeyCommand])?

    /// (Re)registers everything; cheap enough to run on every settings change, and skipped when keys didn't change.
    static func register() {
        let s = Store.shared.settings
        guard last == nil || last!.keys != s.keys || last!.commands != s.keyCommands else { return }
        last = (s.keys, s.keyCommands)
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        let all = Action.allCases.enumerated().map { (UInt32(100 + $0.offset), $0.element.keys) }
            + s.keyCommands.enumerated().map { (UInt32(1000 + $0.offset), $0.element.keys) }
        // ⌘Space is Spotlight's while its system shortcut is on: off while one of ours uses it, back on otherwise (and on quit).
        let spot = parse("cmd - space")!
        _ = Switcher.setSymbolic?(spotlight, !all.contains { parse($0.1).map { $0.code == spot.code && $0.mods == spot.mods } ?? false })
        for (id, keys) in all {
            guard let k = parse(keys) else { continue }
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(k.code, k.mods, EventHotKeyID(signature: 0x50495252, id: id), GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
    }

    static var lastDockRestart: CFTimeInterval = -999
    static var lastDesk = 0 // the desktop most recently asked for
    static let spotlight: Int32 = 64 // macOS's "Show Spotlight search" shortcut
    private static var lastFired: [UInt32: CFTimeInterval] = [:]

    static func fire(_ id: UInt32) {
        if id == Switcher.tabID || id == Switcher.backID { return Switcher.shared.tab(back: id == Switcher.backID) }
        if id >= 1000 {
            let cmds = Store.shared.settings.keyCommands
            guard cmds.indices.contains(Int(id - 1000)) else { return }
            // At most every 0.15 s each: fast enough to open windows as quickly as you can press, too slow for a held key's repeat.
            let now = CACurrentMediaTime()
            guard now - (lastFired[id] ?? 0) > 0.15 else { return }
            lastFired[id] = now
            let p = Process() // a login shell, so PATH and the user's tools are there; not waited on
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmds[Int(id - 1000)].command]
            try? p.run()
        } else if id >= 100, Action.allCases.indices.contains(Int(id - 100)) {
            Action.allCases[Int(id - 100)].run()
        }
    }

    static func send(_ key: Int, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private static let names: [String: Int] = {
        var m: [String: Int] = ["return": kVK_Return, "enter": kVK_Return, "space": kVK_Space, "tab": kVK_Tab,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "comma": kVK_ANSI_Comma, ",": kVK_ANSI_Comma, "period": kVK_ANSI_Period, ".": kVK_ANSI_Period,
            "slash": kVK_ANSI_Slash, "/": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon, ";": kVK_ANSI_Semicolon,
            "quote": kVK_ANSI_Quote, "'": kVK_ANSI_Quote, "minus": kVK_ANSI_Minus, "-": kVK_ANSI_Minus,
            "equal": kVK_ANSI_Equal, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "lbracket": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "rbracket": kVK_ANSI_RightBracket, "`": kVK_ANSI_Grave, "backtick": kVK_ANSI_Grave,
            "\\": kVK_ANSI_Backslash, "backslash": kVK_ANSI_Backslash]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
                       kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                       kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[String(c)] = letters[i] }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, k) in digits.enumerated() { m[String(i)] = k }
        let fs = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, k) in fs.enumerated() { m["f\(i + 1)"] = k }
        return m
    }()

    /// "alt + shift - h" → key code and Carbon modifiers. Nil for an empty or unreadable shortcut.
    static func parse(_ s: String) -> (code: UInt32, mods: UInt32)? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        guard let dash = t.range(of: " - ", options: .backwards) ?? t.range(of: "-", options: .backwards), dash.lowerBound > t.startIndex else { return nil }
        let key = t[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        var mods: UInt32 = 0
        for m in t[..<dash.lowerBound].split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch m {
            case "alt", "option", "opt", "lalt", "ralt": mods |= UInt32(optionKey)
            case "shift", "lshift", "rshift": mods |= UInt32(shiftKey)
            case "ctrl", "control", "lctrl", "rctrl": mods |= UInt32(controlKey)
            case "cmd", "command", "lcmd", "rcmd": mods |= UInt32(cmdKey)
            case "hyper": mods |= UInt32(optionKey | shiftKey | controlKey | cmdKey)
            case "meh": mods |= UInt32(optionKey | shiftKey | controlKey)
            default: return nil
            }
        }
        if let code = names[key] { return (UInt32(code), mods) }
        if key.hasPrefix("0x"), let code = UInt32(key.dropFirst(2), radix: 16) { return (code, mods) }
        return nil
    }

    /// Two actions or commands on the same shortcut: only one of them can win.
    static var clashes: Set<String> {
        let all = Action.allCases.map(\.keys) + Store.shared.settings.keyCommands.map(\.keys)
        let parsed = all.compactMap { parse($0).map { "\($0.code)/\($0.mods)" } }
        return Set(Dictionary(grouping: parsed) { $0 }.filter { $0.value.count > 1 }.keys)
    }

    static func clashes(_ keys: String) -> Bool { parse(keys).map { clashes.contains("\($0.code)/\($0.mods)") } ?? false }

    static func selfTest() {
        assert(parse("alt + shift - h")! == (UInt32(kVK_ANSI_H), UInt32(optionKey | shiftKey)), "skhd syntax")
        assert(parse("ctrl + alt - d")! == (UInt32(kVK_ANSI_D), UInt32(optionKey | controlKey)), "modifier order doesn't matter")
        assert(parse("alt - ]")!.code == UInt32(kVK_ANSI_RightBracket) && parse("alt - return")!.code == UInt32(kVK_Return), "named keys")
        assert(parse("") == nil && parse("alt - nope") == nil && parse("super - h") == nil, "bad shortcuts are rejected")
        let defaults = Action.allCases.map(\.defaultKeys)
        assert(defaults.allSatisfy { parse($0) != nil }, "every default parses")
        assert(Set(defaults.map { "\(parse($0)!)" }).count == defaults.count, "no two defaults share a shortcut")
        print("hotkeys selftest ok (\(defaults.count) actions)")
    }
}
