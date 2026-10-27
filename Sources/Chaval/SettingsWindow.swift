import SwiftUI

enum SettingsWindow {
    enum Tab: Hashable { case dock, appearance, animation, widgets, topBar, tiling, launcher, keys, behavior, system }
    final class Nav: ObservableObject { @Published var tab = Tab.dock }
    static let nav = Nav()

    /// Settings live on the dashboard's Settings page.
    static func show(tab: Tab? = nil) {
        if let tab { nav.tab = tab }
        Dashboard.shared.open(page: .settings)
    }
}

/// The Settings page of the dashboard: a row of categories over the chosen one's options.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: SettingsWindow.Nav
    @State private var trusted = AXIsProcessTrusted()
    @State private var agent = LaunchAgent.isOn

    private static let tabs: [(SettingsWindow.Tab, String, String)] = [
        (.dock, "Dock", "dock.rectangle"), (.appearance, "Appearance", "paintbrush"), (.animation, "Animation", "wand.and.stars"),
        (.widgets, "Widgets", "square.grid.2x2"), (.topBar, "Top Bar", "menubar.rectangle"), (.tiling, "Tiling", "rectangle.split.3x1"),
        (.launcher, "Launcher", "magnifyingglass"), (.keys, "Keys", "keyboard"), (.behavior, "Behavior", "cursorarrow.click"), (.system, "System", "gearshape"),
    ]

    var body: some View {
        let accent = Color(nsColor: NSColor(hex: store.bar.theme.accentHex))
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Self.tabs, id: \.0) { tab, name, symbol in
                    let on = nav.tab == tab
                    Button { nav.tab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: symbol).font(.system(size: 13))
                            Text(name).font(.system(size: 10, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundStyle(on ? accent : .primary.opacity(0.75))
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? accent.opacity(0.16) : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Group {
                switch nav.tab {
                case .dock: form { layout }
                case .appearance: form { appearance }
                case .animation: form { animation }
                case .widgets: form { widgets }
                case .topBar: form { topBar }
                case .tiling: form { tiling }
                case .launcher: form { launcher }
                case .keys: form { keys }
                case .behavior: form { behavior }
                case .system: form { system }
                }
            }
            .id(nav.tab) // each category starts scrolled to the top
        }
        .onAppear { trusted = AXIsProcessTrusted(); agent = LaunchAgent.isOn }
    }

    private func form<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        Form { c() }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -12) // the page has its own padding
    }

    private var s: Binding<Chaval.Settings> { $store.settings }

    private func has(_ kind: Item.Kind, _ path: String = "") -> Binding<Bool> {
        Binding(get: { store.contains(kind, path) }, set: { $0 ? store.add(kind, path) : store.remove(kind, path) })
    }

    private func applyLauncher(width: Double, rows: Int, row: Double, font: Double, field: Double, padding: Double, corner: Double, subtitles: Bool) {
        var x = store.settings
        x.launcherWidth = width; x.launcherRows = rows; x.launcherRowHeight = row; x.launcherFontSize = font
        x.launcherFieldScale = field; x.launcherPadding = padding; x.launcherCorner = corner; x.launcherSubtitles = subtitles
        store.settings = x
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double = 1, unit: String = "") -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: v, in: r, step: step)
                Text(step < 1 ? String(format: "%.2f\(unit)", v.wrappedValue) : "\(Int(v.wrappedValue))\(unit)")
                    .monospacedDigit().frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: hex.wrappedValue)) }, set: { hex.wrappedValue = NSColor($0).hex })
    }

    @ViewBuilder private var layout: some View {
        Section("Position") {
            Picker("Position on screen", selection: s.edge) { ForEach(Edge.allCases, id: \.self) { Text($0.rawValue.capitalized) } }
            Picker("Display", selection: s.displayMode) {
                Text("Follow the cursor").tag(DisplayMode.followCursor)
                Text("Main display").tag(DisplayMode.main)
                Text("Specific display").tag(DisplayMode.fixed)
            }
            if store.settings.displayMode == .fixed {
                Picker("Show on", selection: s.fixedDisplay) {
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0) }
                }
            }
        }
        Section("Shape") {
            Toggle("Taskbar mode (span the whole edge)", isOn: Binding(get: { store.settings.taskbar }, set: { store.setTaskbar($0) }))
            Toggle("Show windows instead of apps", isOn: s.windowsOnly)
            if store.settings.windowsOnly { Toggle("Show the window icons", isOn: s.dockWindows) }
            Text("Each open window on this desktop gets its own tile; running apps you haven't kept in the Dock are left out.")
                .font(.caption).foregroundStyle(.secondary)
            Text("A flexible space fills the gap, so whatever comes after it sits at the far end. One is added before your first widget; drag it anywhere, or add more from the dock's right-click menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Size") {
            slider("Icon size", s.iconSize, 24...128)
            slider("Spacing", s.spacing, 0...24)
            slider("Padding", s.padding, 2...24)
            slider("Gap from edge", s.edgeGap, 0...24)
        }
        Section("Magnification") {
            Toggle("Magnify icons on hover", isOn: s.magnify)
            if store.settings.magnify {
                slider("Magnified size", s.magnifiedSize, store.settings.iconSize...192)
                slider("Spread (icons)", s.magnifySpread, 1...7)
            }
        }
        Section("Hiding") {
            Toggle("Automatically hide and show (⌃⌥D)", isOn: s.autohide)
            slider("Reveal delay", s.autohideDelay, 0...2, step: 0.05, unit: "s")
            Toggle("Reveal from the edge in full-screen apps", isOn: s.showInFullscreen)
            Toggle("Reserve the dock's space when it's always shown", isOn: s.reserveSpace)
            Text("Windows can't use the bar's strip, like the menu bar: maximize, Fill, tiling and window managers all stop at it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var tiling: some View {
        Section {
            Toggle("Tile windows", isOn: s.tiling)
            Text("Master and stack on each display, animated. Turn off yabai, paneru or AeroSpace first so they don't fight over windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Layout") {
            slider("Gap between windows", s.tileGap, 0...40)
            slider("Gap from screen edges", s.tileOuterGap, 0...40)
            Picker("Layout", selection: s.tileLayout) {
                Text("Main + stack").tag(TileLayout.main); Text("Dwindle").tag(TileLayout.dwindle); Text("Grid").tag(TileLayout.grid); Text("Accordion").tag(TileLayout.accordion)
            }
            slider("Main window width", s.tileRatio, 0.15...0.85, step: 0.05)
            Stepper("Main windows: \(store.settings.tileMasters)", value: s.tileMasters, in: 1...6)
            slider("Accordion peek", s.tileAccordionPeek, 8...80)
        }
        Section("Focus") {
            Toggle("Focus follows the mouse", isOn: s.focusFollowsMouse)
            Text("Rest the pointer on a window and it takes focus. Menus, pop-ups, the bar and the dock are left alone, and nothing changes mid-drag.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Animation") {
            Toggle("Animate", isOn: s.tileAnimate)
            Picker("Style", selection: s.tileStyle) {
                Text("Smooth (like a Linux compositor)").tag(TileStyle.smooth); Text("Live windows").tag(TileStyle.live)
            }
            Text(store.settings.tileStyle == .smooth
                 ? "Windows glide as pictures on the GPU, every frame, then the real ones appear in place. Contents pause during the glide."
                 : "The real windows move through Accessibility. Contents stay live, but each app moves at its own pace, so it can stutter.")
                .font(.caption).foregroundStyle(.secondary)
            slider("Speed", s.tileSpeed, 0.25...2, step: 0.05, unit: "×") // 0.33× ≈ a 1 s glide, 60 frames at 60 Hz
        }
        Section("Borders") {
            Toggle("Draw window borders", isOn: s.borders)
            slider("Width", s.borderWidth, 1...12)
            slider("Corner radius", s.borderRadius, 0...30)
            Toggle("Unfocused windows get one too", isOn: s.borderInactive)
            Toggle("Use the theme's accent colour", isOn: s.borderThemed)
            if !store.settings.borderThemed {
                ColorPicker("Focused window", selection: color(s.borderActiveHex))
                if store.settings.borderInactive { ColorPicker("Other windows", selection: color(s.borderInactiveHex)) }
            }
            Text("Drawn by Chaval, not a separate app: they move on the same frame as their window, glides included, so they never lag behind.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Don't tile") {
            TextField("Apps", text: Binding(get: { store.settings.tileFloat.joined(separator: ", ") },
                                             set: { store.settings.tileFloat = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
            Text("App names or bundle IDs, separated by commas. Dialogs, fixed-size and full-screen windows are never tiled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Text("Shortcuts are in the Keys tab. Drag a window onto another to swap them; drag its edge to resize the split.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static let engines = [("DuckDuckGo", "https://duckduckgo.com/?q=%s"), ("Google", "https://www.google.com/search?q=%s"),
                                  ("Kagi", "https://kagi.com/search?q=%s"), ("Brave", "https://search.brave.com/search?q=%s"),
                                  ("Perplexity", "https://www.perplexity.ai/search?q=%s"), ("Off", "")]

    @ViewBuilder private var launcher: some View {
        Section {
            LabeledContent("Shortcut") {
                HStack {
                    Text(HotKeys.symbols(HotKeys.Action.launcher.keys).joined(separator: " ")).foregroundStyle(.secondary)
                    Button("Try it") { Launcher.shared.open() }
                }
            }
            Text("Change the shortcut in the Keys tab. Return opens, ⌘1–⌘9 opens that result, ⌘Return shows a file in Finder, ↑↓ or ⌃N / ⌃P move, Esc closes. Type theme or wallpaper to change them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Appearance") {
            LabeledContent("Presets") {
                HStack {
                    Button("Compact") { applyLauncher(width: 480, rows: 7, row: 28, font: 14, field: 2.4, padding: 3, corner: 10, subtitles: false) }
                    Button("Comfortable") { applyLauncher(width: 640, rows: 8, row: 44, font: 18, field: 3, padding: 6, corner: 14, subtitles: true) }
                }
            }
            slider("Width", s.launcherWidth, 280...1000, step: 10)
            Stepper("Rows: \(store.settings.launcherRows)", value: s.launcherRows, in: 1...14)
            slider("Row height", s.launcherRowHeight, 20...64)
            slider("Text size", s.launcherFontSize, 10...28)
            slider("Search bar height", s.launcherFieldScale, 1.6...4, step: 0.1, unit: "×")
            slider("Space around results", s.launcherPadding, 0...14)
            slider("Distance from the top", Binding(get: { store.settings.launcherTop * 100 }, set: { store.settings.launcherTop = $0 / 100 }), 4...50, unit: "%")
            slider("Corner radius", s.launcherCorner, 0...32)
            slider("Opacity", s.launcherOpacity, 0.5...1, step: 0.05)
            Toggle("Border", isOn: s.launcherBorder)
            Toggle("Icons", isOn: s.launcherIcons)
            Toggle("Magnifying glass", isOn: s.launcherSearchIcon)
            Toggle("Line under the search bar", isOn: s.launcherDivider)
            Toggle("Show subtitles (kind, folder, shortcut)", isOn: s.launcherSubtitles)
            Toggle("Show ⌘1–⌘9 beside results", isOn: s.launcherNumbers)
            Toggle("Faint highlight instead of the accent", isOn: s.launcherSubtleHighlight)
            Toggle("Animate opening and closing", isOn: s.launcherAnimate)
            Text("Colours and font follow the top bar's theme.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Search") {
            Toggle("Apps", isOn: s.launcherApps)
            Toggle("Chaval actions and commands", isOn: s.launcherActions)
            Toggle("Sums (2*(3+4) → 14)", isOn: s.launcherCalc)
            Toggle("Emoji (type : first)", isOn: s.launcherEmoji)
        }
        Section("Files") {
            Toggle("Files", isOn: s.launcherFiles)
            if store.settings.launcherFiles {
                Toggle("Mix files into every search", isOn: s.launcherFilesInline)
                TextField("Folders", text: Binding(get: { store.settings.launcherFileFolders.joined(separator: ", ") },
                                                   set: { store.settings.launcherFileFolders = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                          prompt: Text("your home folder"))
            }
            Text("Found by name through Spotlight's index; Library folders and hidden files are left out. Start with / or ~ to search only files. Separate folders with commas, e.g. ~/Documents, ~/Downloads.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Web") {
            Picker("Search engine", selection: s.launcherWeb) {
                ForEach(Self.engines, id: \.1) { Text($0.0).tag($0.1) }
                if !Self.engines.contains(where: { $0.1 == store.settings.launcherWeb }) { Text("Custom").tag(store.settings.launcherWeb) }
            }
            TextField("Search URL", text: s.launcherWeb, prompt: Text("https://…?q=%s")).font(.callout.monospaced())
            Text("%s is replaced by what you typed.").font(.caption).foregroundStyle(.secondary)
        }
        Section("History") {
            Toggle("Reopen with the last search", isOn: s.launcherKeepQuery)
            Button("Forget what I use most") { Launcher.shared.clearUses() }
            Text("Things you open often rise to the top, and with nothing typed the launcher lists them.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func keyField(_ keys: Binding<String>) -> some View {
        let bad = !keys.wrappedValue.isEmpty && HotKeys.parse(keys.wrappedValue) == nil
        let clash = HotKeys.clashes(keys.wrappedValue)
        return TextField("off", text: keys).font(.callout.monospaced()).frame(width: 150)
            .foregroundStyle(bad ? .red : clash ? .orange : .primary)
            .help(bad ? "Not a shortcut Chaval understands" : clash ? "Another shortcut uses these keys" : "")
    }

    @ViewBuilder private var keys: some View {
        Section {
            Text("Written like skhd: modifiers (alt, shift, ctrl, cmd, hyper) joined with +, then - and the key, e.g. alt + shift - h. Leave one empty to turn it off. Red: not understood; orange: used twice.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(["Windows", "Tiling", "Desktops", "Chaval"], id: \.self) { group in
            Section(group) {
                ForEach(HotKeys.Action.allCases.filter { $0.group == group }, id: \.self) { a in
                    LabeledContent(a.title) {
                        keyField(Binding(get: { a.keys }, set: { store.settings.keys[a.rawValue] = $0 == a.defaultKeys ? nil : $0 }))
                    }
                }
                if group == "Desktops" {
                    Text("Uses macOS's own desktop shortcuts (System Settings → Keyboard → Shortcuts → Mission Control → Switch to Desktop N must be on).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Commands") {
            ForEach($store.settings.keyCommands) { $c in
                HStack {
                    keyField($c.keys)
                    TextField("shell command", text: $c.command).font(.callout.monospaced())
                    Button(role: .destructive) { store.settings.keyCommands.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add command") { store.settings.keyCommands.append(KeyCommand(keys: "", command: "")) }
        }
        Section { Button("Reset all shortcuts") { store.settings.keys = [:] } }
    }

    @ViewBuilder private var appearance: some View {
        Section("Background") {
            Picker("Material", selection: s.material) {
                Text("Liquid Glass").tag(Material.glass); Text("Blur").tag(Material.blur)
                Text("Solid").tag(Material.solid); Text("None").tag(Material.clear)
            }
            Picker("Appearance", selection: s.look) {
                Text("Dark").tag(Look.dark); Text("Light").tag(Look.light); Text("Match system").tag(Look.system)
            }
            ColorPicker("Tint", selection: color(s.tintHex))
            slider("Opacity", s.opacity, 0...1, step: 0.05)
            slider("Corner radius", s.cornerRadius, 0...40)
            Toggle("Border", isOn: s.border)
            if store.settings.border {
                slider("Border width", s.dockBorderWidth, 0.5...6, step: 0.5)
                Toggle("Border in the theme's accent", isOn: s.dockBorderAccent)
            }
            Toggle("Shadow", isOn: s.shadow)
        }
        Section("Icons") {
            Picker("Running indicator", selection: s.indicator) {
                Text("Dot").tag(IndicatorStyle.dot); Text("Bar").tag(IndicatorStyle.bar)
                Text("Glow").tag(IndicatorStyle.glow); Text("None").tag(IndicatorStyle.none)
            }
            ColorPicker("Indicator color", selection: color(s.indicatorHex))
            Picker("Labels", selection: s.labels) {
                Text("On hover").tag(LabelMode.hover); Text("Always, beside the icon").tag(LabelMode.always); Text("Never").tag(LabelMode.never)
            }
            Picker("Font", selection: s.fontName) {
                ForEach(Fonts.families, id: \.self) { Text($0.isEmpty ? "System" : $0).tag($0) }
            }
            slider("Label size", s.labelSize, 9...24)
            Toggle("Dim icons of hidden apps", isOn: s.dimHidden)
        }
        Section("Icon tint") {
            Toggle("Tint all icons (including custom ones)", isOn: s.iconTint)
            ColorPicker("Color", selection: color(s.iconTintHex), supportsOpacity: false)
            Picker("Style", selection: s.iconTintMode) {
                Text("Colorize (keeps shading)").tag(TintMode.colorize); Text("Wash (color overlay)").tag(TintMode.wash)
            }
            slider("Strength", s.iconTintStrength, 0.05...1, step: 0.05)
            Text("Right-click any icon → Icon to change its image or give it its own tint, even with the dock-wide tint off.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var animation: some View {
        Section("Showing and hiding") {
            Picker("Reveal", selection: s.revealAnim) {
                Text("Slide").tag(RevealAnim.slide); Text("Fade").tag(RevealAnim.fade)
                Text("Zoom").tag(RevealAnim.zoom); Text("None").tag(RevealAnim.none)
            }
            slider("Duration", s.animationSpeed, 0...1, step: 0.05, unit: "s")
        }
        Section("Icons") {
            Picker("When an app opens", selection: s.launchAnim) {
                Text("Bounce").tag(LaunchAnim.bounce); Text("Pulse").tag(LaunchAnim.pulse)
                Text("Wiggle").tag(LaunchAnim.wiggle); Text("None").tag(LaunchAnim.none)
            }
            Picker("When clicked", selection: s.clickEffect) {
                Text("Darken").tag(ClickEffect.darken); Text("Shrink").tag(ClickEffect.shrink); Text("None").tag(ClickEffect.none)
            }
            Toggle("Lift the icon under the cursor", isOn: s.hoverLift)
        }
        Section("Magnification") {
            Picker("Curve", selection: s.magnifyCurve) {
                Text("Smooth").tag(Curve.smooth); Text("Wide").tag(Curve.wide)
                Text("Sharp").tag(Curve.sharp); Text("Linear").tag(Curve.linear)
            }
            Text("Turn on magnification and set its size in the Dock tab.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Accessibility") {
            Toggle("Animate even when Reduce Motion is on", isOn: s.animateWithReduceMotion)
            Text("Reduce Motion (System Settings → Accessibility → Display) normally turns Chaval's animations off: the dock's, and the dashboard sliding down.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var widgets: some View {
        Section("Add to the dock") {
            ForEach(WidgetKind.allCases, id: \.self) { k in
                LabeledContent(k.name) { Button("Add") { store.pinned.append(Item(kind: .widget, widget: k)) } }
            }
            Text("Drag anything — apps, widgets, folders, Finder, the Trash — to rearrange it; drag it off the dock to remove it. Right-click → Icon to tint one.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Default style") {
            ColorPicker("Background", selection: color(s.widgetBgHex))
            ColorPicker("Text", selection: color(s.widgetTextHex))
            slider("Corner roundness", Binding(get: { store.settings.widgetCorner * 100 }, set: { store.settings.widgetCorner = $0 / 100 }), 0...50, unit: "%")
        }
        ForEach(store.pinned.filter { $0.kind == .widget }) { w in
            widgetSection(w.id)
        }
    }

    /// Bindings by id, not index, so removing a widget can't leave a stale index behind.
    private func widget(_ id: UUID) -> Binding<Item> {
        Binding(get: { store.pinned.first { $0.id == id } ?? Item(kind: .widget) },
                set: { new in if let i = store.pinned.firstIndex(where: { $0.id == id }) { store.pinned[i] = new } })
    }

    @ViewBuilder private func widgetSection(_ id: UUID) -> some View {
        let w = widget(id)
        let kind = w.wrappedValue.widget ?? .clock
        Section(kind.name) {
            Picker("Size", selection: Binding(get: { w.wrappedValue.spanCount }, set: { w.wrappedValue.spanCount = $0 })) {
                Text("Small").tag(1); Text("Wide").tag(2); Text("Extra wide").tag(3); Text("Huge").tag(4)
            }
            slider("Text size", Binding(get: { (w.wrappedValue.textScale ?? 1) * 100 }, set: { w.wrappedValue.textScale = $0 == 100 ? nil : $0 / 100 }),
                   70...160, step: 5, unit: "%")
            ForEach(kind.options, id: \.0) { key, label in
                Toggle(label, isOn: Binding(get: { w.wrappedValue.opt(key) }, set: { w.wrappedValue.setOpt(key, $0) }))
            }
            override("Background", w.bgHex, fallback: store.settings.widgetBgHex)
            override("Text", w.fgHex, fallback: store.settings.widgetTextHex)
            Button("Remove from Dock", role: .destructive) { store.pinned.removeAll { $0.id == id } }
        }
    }

    /// A colour that's either the dock-wide default or this widget's own.
    @ViewBuilder private func override(_ title: String, _ hex: Binding<String?>, fallback: String) -> some View {
        LabeledContent(title) {
            HStack {
                if hex.wrappedValue != nil {
                    ColorPicker("", selection: color(Binding(get: { hex.wrappedValue ?? fallback }, set: { hex.wrappedValue = $0 }))).labelsHidden()
                    Button("Default") { hex.wrappedValue = nil }
                } else {
                    Text("Default").foregroundStyle(.secondary)
                    Button("Customize") { hex.wrappedValue = fallback }
                }
            }
        }
    }

    // MARK: Top bar

    private var b: Binding<BarConfig> { $store.bar }

    @ViewBuilder private var topBar: some View {
        Section("Top bar") {
            Toggle("Show the top bar", isOn: b.enabled)
            Toggle("App menus in Chaval's theme", isOn: s.chavalMenus)
            Text("Sits over the menu bar, so windows already stop below it. App menus, every app's menu bar icon and Control Center are mirrored; clicking one opens its real menu. Right-click the bar for themes or to hide an icon.")
                .font(.caption).foregroundStyle(.secondary)
            if !trusted { Text("Needs Accessibility (System tab) to show menus and icons.").font(.caption).foregroundStyle(.orange) }
        }
        Section("Theme") {
            Picker("Theme", selection: Binding(get: { Themes.current ?? "" }, set: { n in Palette.all.first { $0.name == n }.map(Themes.apply) })) {
                if Themes.current == nil { Text("Custom").tag("") }
                ForEach(Palette.families, id: \.self) { f in
                    Section(f) { ForEach(Palette.all.filter { $0.family == f }) { Text($0.name).tag($0.name) } }
                }
            }
            Text("A theme also restyles the dock, window borders, Ghostty and tmux. Browse them with previews in the dashboard (top centre of the screen).")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Material", selection: b.theme.material) {
                Text("Liquid Glass").tag(Material.glass); Text("Blur").tag(Material.blur)
                Text("Solid").tag(Material.solid); Text("None (sections only)").tag(Material.clear)
            }
            ColorPicker("Background", selection: color(b.theme.bgHex))
            ColorPicker("Text and icons", selection: color(b.theme.fgHex))
            ColorPicker("Accent", selection: color(b.theme.accentHex))
            ColorPicker("Section background", selection: color(b.theme.pillHex))
            Toggle("Border", isOn: b.theme.border)
            if store.bar.theme.border {
                slider("Border width", b.theme.borderWidth, 0.5...6, step: 0.5)
                Toggle("Border in the theme's accent", isOn: b.theme.borderAccent)
                if !store.bar.theme.borderAccent { ColorPicker("Border color", selection: color(b.theme.borderHex)) }
            }
            Toggle("Icons in the theme's accent", isOn: b.theme.accentIcons)
            Toggle("App icons in color", isOn: b.theme.colorIcons)
        }
        Section("Shape and text") {
            slider("Bar corner radius", b.theme.corner, 0...20)
            slider("Section corner radius", b.theme.pillCorner, 0...16)
            slider("Float (gap around the bar)", b.theme.inset, 0...12)
            Picker("Font", selection: b.theme.fontName) {
                ForEach(Fonts.families, id: \.self) { Text($0.isEmpty ? "System" : $0).tag($0) }
            }
            slider("Text size", b.theme.fontSize, 9...16)
            slider("Item spacing", b.theme.spacing, 4...24)
        }
        ForEach(store.bar.sections) { sec in barSectionEditor(sec.id) }
        Section {
            Button("Add section") { store.bar.sections.append(BarSection(name: "Section \(store.bar.sections.count + 1)")) }
            Text("Sections sit left, center or right (on a notched screen, center sections go just right of the notch). Text and shell items take any SF Symbol name; a shell item shows its command's first line of output.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !store.bar.hidden.isEmpty {
            Section("Hidden icons") {
                ForEach(store.bar.hidden, id: \.self) { key in
                    LabeledContent(key) { Button("Show") { store.bar.hidden.removeAll { $0 == key } } }
                }
            }
        }
    }

    private func barSection(_ id: UUID) -> Binding<BarSection> {
        Binding(get: { store.bar.sections.first { $0.id == id } ?? BarSection() },
                set: { new in if let i = store.bar.sections.firstIndex(where: { $0.id == id }) { store.bar.sections[i] = new } })
    }

    private func move<T: Identifiable>(_ list: inout [T], _ id: T.ID, by d: Int) {
        guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + d) else { return }
        list.swapAt(i, i + d)
    }

    @ViewBuilder private func barSectionEditor(_ id: UUID) -> some View {
        let s = barSection(id)
        Section(s.wrappedValue.name) {
            TextField("Name", text: s.name)
            Picker("Side", selection: s.side) { Text("Left").tag(BarSide.left); Text("Center").tag(BarSide.center); Text("Right").tag(BarSide.right) }
            Toggle("Background", isOn: s.pill)
            if s.wrappedValue.pill { override("Background color", s.bgHex, fallback: store.bar.theme.pillHex) }
            override("Text color", s.fgHex, fallback: store.bar.theme.fgHex)
            ForEach(s.wrappedValue.items) { item in barItemRow(s, item.id) }
            HStack {
                SwiftUI.Menu("Add item") {
                    ForEach(BarModule.allCases, id: \.self) { m in
                        Button(m.name) {
                            var item = BarItem(module: m)
                            if m == .text { item.text = "Hello"; item.icon = "sparkles" }
                            if m == .script { item.text = "date +%H:%M"; item.icon = "terminal"; item.interval = 30 }
                            s.wrappedValue.items.append(item)
                        }
                    }
                }.fixedSize()
                Spacer()
                Button { move(&store.bar.sections, id, by: -1) } label: { Image(systemName: "arrow.up") }
                Button { move(&store.bar.sections, id, by: 1) } label: { Image(systemName: "arrow.down") }
                Button("Remove section", role: .destructive) { store.bar.sections.removeAll { $0.id == id } }
            }
        }
    }

    @ViewBuilder private func barItemRow(_ s: Binding<BarSection>, _ id: UUID) -> some View {
        let i = Binding<BarItem>(get: { s.wrappedValue.items.first { $0.id == id } ?? BarItem(module: .spacer) },
                                 set: { new in if let k = s.wrappedValue.items.firstIndex(where: { $0.id == id }) { s.wrappedValue.items[k] = new } })
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(i.wrappedValue.module.name).fontWeight(.medium)
                Spacer()
                Button { move(&s.wrappedValue.items, id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                Button { move(&s.wrappedValue.items, id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                Button { s.wrappedValue.items.removeAll { $0.id == id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            switch i.wrappedValue.module {
            case .text:
                TextField("Text", text: i.text)
                TextField("SF Symbol (optional)", text: i.icon)
                TextField("Shell command on click (optional)", text: i.click)
            case .script:
                TextField("Command", text: i.text).font(.system(.body, design: .monospaced))
                Stepper("Every \(Int(i.wrappedValue.interval)) s", value: i.interval, in: 1...3600, step: 5)
                TextField("SF Symbol (optional)", text: i.icon)
                TextField("Shell command on click (optional)", text: i.click)
            case .clock, .date:
                TextField("Format, e.g. EEE d MMM HH:mm (empty = automatic)", text: i.text)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var behavior: some View {
        Section("Clicking") {
            Toggle("Clicking the active app hides it", isOn: s.clickHides)
            Toggle("Scroll on an app icon to cycle its windows", isOn: s.scrollCycles)
        }
        Section("Awake") {
            Toggle("Keep the Mac awake", isOn: Binding(get: { KeepAwake.on }, set: { KeepAwake.set($0) }))
            Toggle("Let the display sleep", isOn: Binding(get: { KeepAwake.displaySleep }, set: { KeepAwake.displaySleep = $0 }))
            if KeepAwake.lidReady {
                Toggle("Also with the lid closed", isOn: Binding(get: { KeepAwake.lidClosed }, set: { KeepAwake.lidClosed = $0 }))
            } else {
                Button("Set up lid-closed awake (asks for your password once)") { KeepAwake.setUpLid { ok in if ok { KeepAwake.lidClosed = true } } }
            }
            Text("Lid closed lets go by itself below \(KeepAwake.batteryFloor)% battery, when Awake ends, and when Chaval quits. Right-click Awake in the dashboard for timed sessions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Windows") {
            Toggle("Minimize windows into application icon", isOn: s.minimizeIntoApp)
            Toggle("Wallpaper stays still when switching desktops", isOn: s.stillWallpaper)
            Toggle("Show only desktops in use (with windows, or the one you're on)", isOn: s.desktopsInUse)
            slider("Current desktop corner radius", Binding(get: { store.settings.deskCorner * 100 }, set: { store.settings.deskCorner = $0 / 100 }), 0...50, unit: "%")
            Toggle("Chaval's ⌘Tab switcher (this desktop's windows, in the theme)", isOn: s.cmdTab)
            Text("Hold ⌘ and press Tab to move, ⇧ to go back, let go to switch. Esc cancels, Q quits the app, W closes the window. Off: macOS's own switcher comes back.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Extra icons") {
            Toggle("Show recent apps", isOn: s.showRecents)
            if store.settings.showRecents { Stepper("Recent apps: \(store.settings.recentCount)", value: s.recentCount, in: 1...10) }
            Toggle("Finder", isOn: has(.finder))
            Toggle("Trash", isOn: has(.trash))
            Toggle("Apps launcher", isOn: has(.launcher, Item.appsPath))
            Toggle("Mission Control", isOn: has(.launcher, Item.missionControlPath))
            Button("Add spacer") { store.pinned.append(Item(kind: .spacer)) }
        }
    }

    @ViewBuilder private var system: some View {
        Section("Permissions") {
            LabeledContent("Accessibility") {
                if trusted { Text("Granted").foregroundStyle(.green) } else {
                    Button("Grant…") {
                        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Text("Needed for window lists, minimized windows, scroll-to-cycle and badges.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Startup") {
            Toggle("Open at login (relaunches if Chaval ever crashes)", isOn: Binding(get: { agent }, set: { agent = $0; LaunchAgent.set($0) }))
        }
        Section("Layout") {
            Button("Re-import layout from the system Dock") { SystemDock.importLayout(into: store) }
            Button("Reset all custom icons and tints") {
                Store.shared.iconStyles.keys.forEach { Store.shared.setIcon($0, from: nil) }
                Store.shared.iconStyles = [:]
            }
            Button("Quit Chaval and restore the system Dock") { NSApp.terminate(nil) }
        }
    }
}
