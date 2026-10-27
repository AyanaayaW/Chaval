import SwiftUI

/// The dashboard's cheat sheet: every shortcut Chaval owns, shown as keys and editable in place (click one, type it
/// skhd style, Return), the launchers with their commands, and the keys that work inside Chaval's own panels.
struct ShortcutsPage: View {
    let s: DashStyle
    @EnvironmentObject var store: Store
    @State private var editing: String?   // the row being edited
    @State private var draft = ""

    private let groups = ["Windows", "Tiling", "Desktops", "Chaval"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Click a shortcut to change it: modifiers (alt, shift, ctrl, cmd, hyper) joined with +, then - and the key, e.g. alt + shift - h. Empty turns it off.")
                    .font(s.font(10)).opacity(0.6)
                // Windows (the long list) on the left; the other groups stacked on the right, so the columns come out even.
                HStack(alignment: .top, spacing: 10) {
                    group("Windows")
                    VStack(spacing: 10) { ForEach(groups.dropFirst(), id: \.self) { group($0) } }
                }
                s.card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            s.title("Launchers")
                            Spacer()
                            s.pill("Add", symbol: "plus") { store.settings.keyCommands.append(KeyCommand(keys: "", command: "")) }
                        }
                        ForEach($store.settings.keyCommands) { $c in
                            HStack(spacing: 8) {
                                keyCaps(id: "cmd:\(c.id)", keys: c.keys) { c.keys = $0 }.frame(width: 150, alignment: .leading)
                                TextField("shell command", text: $c.command).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 6).frame(height: 22).background(RoundedRectangle(cornerRadius: 6).fill(s.fg.opacity(0.06)))
                                Button { store.settings.keyCommands.removeAll { $0.id == c.id } } label: {
                                    Image(systemName: "minus.circle").font(.system(size: 11))
                                }.buttonStyle(.plain).opacity(0.6).help("Remove")
                            }
                        }
                    }
                }
                s.card {
                    VStack(alignment: .leading, spacing: 3) {
                        s.title("Built in")
                        fixed("Switch windows (this desktop)", ["⌘", "⇥"], note: "hold ⌘: ⇥ next · ⇧ back · Q quit · W close · Esc cancel")
                        fixed("Dashboard", ["↑"], note: "push the pointer to the top centre of the screen")
                        fixed("App menus in the bar", ["↑", "↓", "←", "→", "↩"], note: "move · open submenu · back · choose; Esc closes")
                        fixed("Scroll on the bar", ["⇅"], note: "over desktops: switch · over sound/brightness: change · elsewhere: left brightness, right volume")
                        fixed("Swap two windows", ["drag"], note: "drop a window on another; drag a window's edge to resize the split")
                    }
                }
                HStack {
                    Spacer()
                    s.pill("Reset all shortcuts", symbol: "arrow.counterclockwise") { store.settings.keys = [:]; editing = nil }
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func group(_ g: String) -> some View {
        s.card {
            VStack(alignment: .leading, spacing: 3) {
                s.title(g)
                ForEach(HotKeys.Action.allCases.filter { $0.group == g }, id: \.self) { a in
                    row(a.title, id: a.rawValue, keys: a.keys) { store.settings.keys[a.rawValue] = $0 == a.defaultKeys ? nil : $0 }
                }
            }
        }
    }

    private func row(_ title: String, id: String, keys: String, set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(s.font(11)).lineLimit(1)
            Spacer(minLength: 6)
            keyCaps(id: id, keys: keys, set: set)
        }
        .frame(height: 22)
    }

    /// The shortcut as key caps, or a field while it's being edited (red: not understood; orange: used twice).
    @ViewBuilder private func keyCaps(id: String, keys: String, set: @escaping (String) -> Void) -> some View {
        if editing == id {
            let bad = !draft.trimmingCharacters(in: .whitespaces).isEmpty && HotKeys.parse(draft) == nil
            let clash = !bad && !draft.isEmpty && clashes(draft, except: id)
            TextField("alt - x", text: $draft, onCommit: { set(draft.trimmingCharacters(in: .whitespaces)); editing = nil })
                .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).frame(width: 130)
                .padding(.horizontal, 6).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).stroke(bad ? Color.red : clash ? Color.orange : s.accent, lineWidth: 1))
                .onExitCommand { editing = nil }
        } else {
            Button { draft = keys; editing = id } label: {
                HStack(spacing: 3) {
                    let caps = HotKeys.symbols(keys)
                    if caps.isEmpty { Text("off").font(s.font(10)).opacity(0.4) }
                    ForEach(Array(caps.enumerated()), id: \.offset) { cap($0.element) }
                }
            }.buttonStyle(.plain).help("Click to change")
        }
    }

    private func cap(_ k: String) -> some View {
        Text(k).font(s.font(10, .semibold)).padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(s.fg.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(s.fg.opacity(0.15), lineWidth: 1))
    }

    private func fixed(_ title: String, _ caps: [String], note: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(s.font(11)).lineLimit(1).frame(width: 190, alignment: .leading)
            HStack(spacing: 3) { ForEach(Array(caps.enumerated()), id: \.offset) { cap($0.element) } }
            Text(note).font(s.font(10)).opacity(0.5).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    /// Whether another shortcut (action or launcher) already uses these keys.
    private func clashes(_ keys: String, except id: String) -> Bool {
        guard let k = HotKeys.parse(keys) else { return false }
        let actions = HotKeys.Action.allCases.filter { $0.rawValue != id }.map(\.keys)
        let commands = store.settings.keyCommands.filter { "cmd:\($0.id)" != id }.map(\.keys)
        return (actions + commands).contains { HotKeys.parse($0).map { $0 == k } ?? false }
    }
}

extension HotKeys {
    /// "alt + shift - h" → ["⌥", "⇧", "H"], for showing a shortcut as keys. Empty if it's off or unreadable.
    static func symbols(_ s: String) -> [String] {
        guard parse(s) != nil else { return [] }
        let t = s.lowercased()
        guard let dash = t.range(of: " - ", options: .backwards) ?? t.range(of: "-", options: .backwards) else { return [] }
        let names: [String: String] = ["ctrl": "⌃", "control": "⌃", "alt": "⌥", "option": "⌥", "opt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘",
                                       "hyper": "✦", "meh": "◆", "lalt": "⌥", "ralt": "⌥", "lshift": "⇧", "rshift": "⇧", "lctrl": "⌃", "rctrl": "⌃", "lcmd": "⌘", "rcmd": "⌘"]
        let mods = t[..<dash.lowerBound].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { names[$0] }
        let key = t[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        let keyNames: [String: String] = ["return": "↩", "enter": "↩", "tab": "⇥", "space": "Space", "escape": "⎋", "delete": "⌫", "backspace": "⌫",
                                          "left": "←", "right": "→", "up": "↑", "down": "↓", "comma": ",", "period": ".", "slash": "/", "semicolon": ";",
                                          "quote": "'", "minus": "−", "equal": "=", "grave": "`"]
        return mods + [keyNames[key] ?? key.uppercased()]
    }
}
