import SwiftUI
import IOKit.ps

/// The small panels that drop out of the bar's status items on hover, like a Linux bar's popouts.
/// It stays while the pointer is over its item or itself, and slides away 0.3 s after it leaves both.
final class BarPopout {
    enum Kind: String { case volume, wifi, bluetooth, battery, keyboard, brightness }

    static let shared = BarPopout()
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private let model = PopoutModel()
    private var anchor = NSRect.zero
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private(set) var kind: Kind?

    var isOpen: Bool { panel?.isVisible == true }
    func owns(_ w: NSWindow?) -> Bool { w != nil && w === panel }

    /// `anchor`: the item's rect on screen.
    func show(_ k: Kind, anchor r: NSRect) {
        closeWork?.cancel(); closeWork = nil
        guard k != kind || !isOpen else { return }
        let first = !isOpen
        kind = k; anchor = r
        model.kind = k
        model.refresh()
        let p = panel ?? make()
        panel = p
        fit(animated: !first)
        if first {
            let reduce = Store.shared.reduceMotion && !Store.shared.settings.animateWithReduceMotion
            let end = p.frame
            p.setFrame(end.offsetBy(dx: 0, dy: reduce ? 0 : 8), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.18
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                p.animator().setFrame(end, display: true)
                p.animator().alphaValue = 1
            }
            model.start()
            let moved: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
            monitors = [NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) as Any,
                        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { moved($0); return $0 } as Any,
                        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() } as Any]
        }
    }

    func toggle(_ k: Kind, anchor r: NSRect) { kind == k && isOpen ? close() : show(k, anchor: r) }

    func close() {
        guard let p = panel, p.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        closeWork?.cancel(); closeWork = nil
        model.stop()
        kind = nil
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.14
            p.animator().alphaValue = 0
        }, completionHandler: { if self.kind == nil { p.orderOut(nil) } })
    }

    private func pointerMoved() {
        guard let p = panel, NSApp.modalWindow == nil else { return }
        let m = NSEvent.mouseLocation
        // The item, the gap down to the panel, the panel, and its own menus (pickers).
        let bridge = NSRect(x: min(anchor.minX, p.frame.minX), y: p.frame.maxY, width: max(anchor.maxX, p.frame.maxX) - min(anchor.minX, p.frame.minX), height: anchor.minY - p.frame.maxY + 1)
        let near = anchor.insetBy(dx: -2, dy: -2).contains(m) || bridge.contains(m) || p.frame.insetBy(dx: -12, dy: -12).contains(m)
            || NSApp.windows.contains { $0 !== p && $0.isVisible && $0.level.rawValue > p.level.rawValue && $0.frame.contains(m) && $0.frame.height < 600 }
        if near { closeWork?.cancel(); closeWork = nil; return }
        guard closeWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Sizes the panel to its content, hanging just under the item and kept on screen.
    fileprivate func fit(animated: Bool = true) {
        guard let p = panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let s = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.screens[0]
        var x = anchor.midX - size.width / 2
        x = min(max(x, s.frame.minX + 6), s.frame.maxX - size.width - 6)
        let r = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
        if animated && p.isVisible {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.16; p.animator().setFrame(r, display: true) }
        } else { p.setFrame(r, display: true) }
    }

    private func make() -> NSPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        let h = NSHostingView(rootView: AnyView(PopoutView(model: model).environmentObject(Store.shared)))
        host = h
        p.contentView = h
        model.resized = { [weak self] in self?.fit() }
        return p
    }

    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } } // the Wi-Fi password field
}

// MARK: - Model

final class PopoutModel: ObservableObject {
    @Published var kind: BarPopout.Kind = .volume
    @Published var tick = 0 // bumped to re-read the system
    @Published var networks: [(ssid: String, bars: Int, secure: Bool)] = []
    @Published var scanning = false
    @Published var devices: [Bluetooth.Device] = []
    @Published var outputs: [Audio.Device] = []
    @Published var inputs: [Audio.Device] = []
    @Published var sources: [InputSources.Source] = []
    var resized: () -> Void = {}
    private var timer: Timer?, scanTimer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil; scanTimer?.invalidate(); scanTimer = nil }

    func refresh() {
        switch kind {
        case .volume: outputs = Audio.devices(input: false); inputs = Audio.devices(input: true)
        case .bluetooth: devices = Bluetooth.devices()
        case .keyboard: sources = InputSources.enabled
        case .wifi:
            WiFi.shared.askLocation()
            if scanTimer == nil { scan(); scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan() } }
        default: break
        }
        if kind != .wifi { scanTimer?.invalidate(); scanTimer = nil }
        tick += 1
        DispatchQueue.main.async { self.resized() }
    }

    func scan() {
        guard WiFi.shared.on, !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = WiFi.shared.scan()
            DispatchQueue.main.async { self.networks = found; self.scanning = false; self.resized() }
        }
    }
}

// MARK: - Views

private struct PopoutView: View {
    @ObservedObject var model: PopoutModel
    @EnvironmentObject var store: Store
    private var s: DashStyle { DashStyle(t: store.bar.theme) }

    var body: some View {
        let t = store.bar.theme
        VStack(alignment: .leading, spacing: 10) {
            switch model.kind {
            case .volume: VolumePane(s: s, model: model)
            case .wifi: WiFiPane(s: s, model: model)
            case .bluetooth: BluetoothPane(s: s, model: model)
            case .battery: BatteryPane(s: s, model: model)
            case .keyboard: KeyboardPane(s: s, model: model)
            case .brightness: BrightnessPane(s: s, model: model)
            }
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
        .foregroundStyle(s.fg)
        .background(RoundedRectangle(cornerRadius: max(t.pillCorner, 10)).fill(Color(nsColor: NSColor(hex: t.bgHex).withAlphaComponent(max(NSColor(hex: t.bgHex).alphaComponent, 0.95)))))
        .overlay(RoundedRectangle(cornerRadius: max(t.pillCorner, 10)).stroke(Color(nsColor: NSColor(hex: t.borderHex)), lineWidth: t.border ? 1 : 0))
        .clipShape(RoundedRectangle(cornerRadius: max(t.pillCorner, 10)))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Title row: a name and an on/off switch.
private func header(_ s: DashStyle, _ title: String, _ symbol: String, on: Bool? = nil, _ toggle: ((Bool) -> Void)? = nil) -> some View {
    HStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(s.accent).frame(width: 18)
        Text(title).font(s.font(13, .bold))
        Spacer()
        if let on, let toggle {
            Toggle("", isOn: Binding(get: { on }, set: toggle)).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(s.accent)
        }
    }
}

/// A tappable list row; the current one is filled with the accent.
private func row(_ s: DashStyle, _ symbol: String, _ title: String, detail: String = "", on: Bool = false, _ f: @escaping () -> Void) -> some View {
    Button(action: f) {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16)
            Text(title).font(s.font(12, on ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if !detail.isEmpty { Text(detail).font(s.font(10)).opacity(0.6) }
            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? s.accent.opacity(0.18) : s.fg.opacity(0.06)))
        .foregroundStyle(on ? s.accent : s.fg)
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
}

private func slider(_ s: DashStyle, _ symbol: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
    HStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 11)).frame(width: 18).opacity(0.8)
        Slider(value: Binding(get: { value }, set: set), in: 0...1).tint(s.accent).controlSize(.small)
        Text("\(Int((value * 100).rounded()))%").font(s.font(11, .semibold)).monospacedDigit().frame(width: 38, alignment: .trailing)
    }
}

private func settingsLink(_ s: DashStyle, _ title: String, _ pane: String) -> some View {
    Button {
        BarPopout.shared.close()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    } label: {
        Text(title).font(s.font(11)).opacity(0.65).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }.buttonStyle(.plain)
}

private struct VolumePane: View {
    let s: DashStyle
    @ObservedObject var model: PopoutModel
    var body: some View {
        let _ = model.tick
        let out = Audio.defaultDevice(input: false), inp = Audio.defaultDevice(input: true)
        header(s, "Sound", Audio.symbol, on: !Audio.muted()) { Audio.setMuted(!$0); model.tick += 1 }
        slider(s, "speaker.wave.2.fill", Audio.volume() ?? 0) { Audio.setVolume($0); model.tick += 1 }
        VStack(spacing: 3) {
            ForEach(model.outputs, id: \.id) { d in
                row(s, d.name.lowercased().contains("headphone") || d.name.lowercased().contains("airpods") ? "headphones" : "hifispeaker.fill", d.name, on: d.id == out) {
                    Audio.setDefault(d, input: false); model.tick += 1
                }
            }
        }
        s.title("Microphone")
        slider(s, Audio.muted(input: true) ? "mic.slash.fill" : "mic.fill", Audio.volume(input: true) ?? 0) { Audio.setVolume($0, input: true); model.tick += 1 }
        if model.inputs.count > 1 {
            VStack(spacing: 3) {
                ForEach(model.inputs, id: \.id) { d in row(s, "mic", d.name, on: d.id == inp) { Audio.setDefault(d, input: true); model.tick += 1 } }
            }
        }
        settingsLink(s, "Sound Settings…", "com.apple.Sound-Settings.extension")
    }
}

private struct WiFiPane: View {
    let s: DashStyle
    @ObservedObject var model: PopoutModel
    @State private var joining: String?
    @State private var asking: String?   // network waiting for a password
    @State private var password = ""
    @State private var failed: String?

    var body: some View {
        let _ = model.tick
        let w = WiFi.shared, current = w.ssid
        header(s, "Wi-Fi", w.symbol, on: w.on) { w.setPower($0); model.tick += 1; if $0 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.scan() } } }
        if w.on {
            if w.needsLocation {
                Button { w.askLocation(); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) } label: {
                    Text("macOS hides network names until Chaval is allowed Location. Click to allow it.").font(s.font(10)).opacity(0.7)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain)
            }
            if w.connected { row(s, "wifi", current ?? "Connected", detail: ["", "weak", "good", "strong"][w.bars], on: true) {} }
            HStack { s.title("Networks"); Spacer(); if model.scanning { ProgressView().controlSize(.mini) } }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.networks.filter { $0.ssid != current }, id: \.ssid) { n in
                        row(s, n.secure ? "lock.fill" : "wifi", n.ssid, detail: joining == n.ssid ? "joining…" : failed == n.ssid ? "failed" : String(repeating: "•", count: n.bars)) {
                            join(n.ssid, password: nil, secure: n.secure)
                        }
                        if asking == n.ssid {
                            HStack(spacing: 6) {
                                SecureField("Password", text: $password).textFieldStyle(.plain).font(s.font(12))
                                    .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 7).fill(s.fg.opacity(0.08)))
                                    .onSubmit { join(n.ssid, password: password, secure: true) }
                                s.pill("Join", on: true) { join(n.ssid, password: password, secure: true) }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
        }
        settingsLink(s, "Wi-Fi Settings…", "com.apple.wifi-settings-extension")
    }

    /// Known networks join with the saved password; a secured one that fails asks for one.
    private func join(_ ssid: String, password: String?, secure: Bool) {
        joining = ssid; failed = nil
        WiFi.shared.join(ssid, password: password) { ok in
            joining = nil
            if ok { asking = nil; self.password = "" }
            else if secure && password == nil { asking = ssid; NSApp.activate(); BarPopout.shared.focus() }
            else { failed = ssid }
            model.tick += 1; model.resized()
        }
    }
}

private struct BluetoothPane: View {
    let s: DashStyle
    @ObservedObject var model: PopoutModel
    @State private var busy: String?
    var body: some View {
        let _ = model.tick
        header(s, "Bluetooth", "dot.radiowaves.left.and.right", on: Bluetooth.on) { Bluetooth.setPower($0); model.tick += 1 }
        if Bluetooth.on {
            if model.devices.isEmpty { Text("No paired devices").font(s.font(11)).opacity(0.6) }
            VStack(spacing: 3) {
                ForEach(model.devices) { d in
                    row(s, d.symbol, d.name, detail: busy == d.id ? (d.connected ? "disconnecting…" : "connecting…") : d.connected ? "connected" : "", on: d.connected) {
                        busy = d.id
                        Bluetooth.toggle(d) { busy = nil; model.refresh() }
                    }
                }
            }
        }
        settingsLink(s, "Bluetooth Settings…", "com.apple.BluetoothSettings")
    }
}

private struct BatteryPane: View {
    let s: DashStyle
    @ObservedObject var model: PopoutModel
    var body: some View {
        let _ = model.tick
        let b = Widgets.battery(), left = IOPSGetTimeRemainingEstimate()
        header(s, "Battery", b.plugged ? "battery.100percent.bolt" : "battery.75percent")
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(b.level)%").font(s.font(28, .bold)).foregroundStyle(s.accent)
            Text(b.plugged ? (b.level >= 100 ? "Charged" : "Charging") : "On battery").font(s.font(12)).opacity(0.7)
        }
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(s.fg.opacity(0.12))
                Capsule().fill(s.accent).frame(width: g.size.width * CGFloat(b.level) / 100)
            }
        }.frame(height: 6)
        if left > 0 {
            let m = Int(left / 60)
            Text("\(m / 60)h \(m % 60)m remaining").font(s.font(11)).opacity(0.7)
        }
        settingsLink(s, "Battery Settings…", "com.apple.Battery-Settings.extension")
    }
}

private struct KeyboardPane: View {
    let s: DashStyle
    @ObservedObject var model: PopoutModel
    var body: some View {
        let _ = model.tick
        let cur = InputSources.current.id
        header(s, "Keyboard", "keyboard")
        VStack(spacing: 3) {
            ForEach(model.sources) { src in row(s, "character", src.name, detail: src.short, on: src.id == cur) { InputSources.select(src); model.tick += 1 } }
        }
        settingsLink(s, "Keyboard Settings…", "com.apple.Keyboard-Settings.extension")
    }
}

private struct BrightnessPane: View {
    let s: DashStyle
    @ObservedObject var model: PopoutModel
    var body: some View {
        let _ = model.tick
        header(s, "Display", "sun.max.fill")
        if let b = System.brightness() {
            slider(s, "sun.max.fill", b) { System.setBrightness($0); model.tick += 1 }
        } else {
            Text("This display's brightness can't be set from the Mac.").font(s.font(11)).opacity(0.6)
        }
        settingsLink(s, "Displays Settings…", "com.apple.Displays-Settings.extension")
    }
}

extension BarPopout {
    /// Diagnostic for `--render-popout KIND FILE`: draws one popout off screen.
    static func render(_ kind: String, to path: String) {
        let m = PopoutModel()
        m.kind = Kind(rawValue: kind) ?? .volume
        m.refresh()
        if m.kind == .wifi { m.networks = WiFi.shared.scan() }
        let v = NSHostingView(rootView: PopoutView(model: m).environmentObject(Store.shared))
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 290, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = v
        v.frame.size = v.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        v.frame.size = v.fittingSize
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Lets the password field take typing.
    func focus() { panel?.makeKey() }
}
