import AppKit
import Carbon
import CoreAudio
import CoreLocation
import CoreWLAN
import IOBluetooth

// The bar's own status items: sound, Wi-Fi, Bluetooth and keyboard layout, read and changed directly
// (not mirrored from the menu bar), so they can have popouts and scroll actions.

// MARK: - Sound (CoreAudio: instant, unlike AppleScript)

enum Audio {
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766d7663 // 'vmvc', AudioToolbox's VirtualMainVolume
    struct Device: Hashable { let id: AudioObjectID; let name: String }

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> T? {
        var a = address(sel, scope), v = zero, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    private static func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: T) {
        var a = address(sel, scope), v = value
        AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        get(AudioObjectID(kAudioObjectSystemObject), input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
    }
    static func setDefault(_ d: Device, input: Bool) {
        set(AudioObjectID(kAudioObjectSystemObject), input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, d.id)
    }

    private static func scope(_ input: Bool) -> AudioObjectPropertyScope { input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput }

    /// 0…1, the volume the volume keys change. nil for devices with no volume (some HDMI outputs).
    static func volume(input: Bool = false) -> Double? {
        guard let d = defaultDevice(input: input) else { return nil }
        return get(d, virtualMainVolume, scope(input), Float32(0)).map(Double.init)
    }
    static func setVolume(_ v: Double, input: Bool = false) {
        guard let d = defaultDevice(input: input) else { return }
        set(d, virtualMainVolume, scope(input), Float32(min(max(v, 0), 1)))
        if !input && v > 0 && muted() { setMuted(false) }
    }
    static func muted(input: Bool = false) -> Bool {
        defaultDevice(input: input).flatMap { get($0, kAudioDevicePropertyMute, scope(input), UInt32(0)) } == 1
    }
    static func setMuted(_ on: Bool, input: Bool = false) {
        guard let d = defaultDevice(input: input) else { return }
        set(d, kAudioDevicePropertyMute, scope(input), UInt32(on ? 1 : 0))
    }

    static func devices(input: Bool) -> [Device] {
        var a = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var sa = address(kAudioDevicePropertyStreams, scope(input)), ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { return nil }
            var na = address(kAudioObjectPropertyName), name: Unmanaged<CFString>?, ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name) == noErr, let n = name?.takeRetainedValue() as String? else { return nil }
            return Device(id: id, name: n)
        }
    }

    static var symbol: String {
        guard let v = volume(), !muted() else { return "speaker.slash.fill" }
        return v < 0.01 ? "speaker.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    /// Calls `f` on main whenever the output device, its volume or mute changes (keys, other apps, us).
    static func watch(_ f: @escaping () -> Void) {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var watched: AudioObjectID?
        func follow() {
            guard let d = defaultDevice(input: false), d != watched else { return }
            watched = d
            for sel in [virtualMainVolume, kAudioDevicePropertyMute] {
                var a = address(sel, kAudioDevicePropertyScopeOutput)
                AudioObjectAddPropertyListenerBlock(d, &a, .main) { _, _ in if watched == d { f() } }
            }
        }
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(sys, &a, .main) { _, _ in follow(); f() }
        follow()
    }
}

// MARK: - Wi-Fi

/// Network names need Location access (macOS hides them otherwise); everything else works without it.
final class WiFi: NSObject, CLLocationManagerDelegate {
    static let shared = WiFi()
    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    var iface: CWInterface? { client.interface() }
    var onChange: () -> Void = {}

    override init() {
        super.init()
        location.delegate = self
        client.delegate = self
        for e in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange, .linkQualityDidChange] { try? client.startMonitoringEvent(with: e) }
        changed()
    }

    /// What the bar shows, read off the main thread when Wi-Fi changes: every question to the Wi-Fi chip is a
    /// round trip that blocked the bar's drawing.
    private(set) var bar = (symbol: "wifi", tip: "Wi-Fi")
    private func changed() {
        DispatchQueue.global(qos: .utility).async {
            let b = (symbol: self.symbol, tip: self.ssid ?? (self.on ? "Wi-Fi" : "Wi-Fi off"))
            DispatchQueue.main.async { self.bar = b; self.onChange() }
        }
    }

    var on: Bool { iface?.powerOn() ?? false }
    var ssid: String? { iface?.ssid() }
    var connected: Bool { iface?.wlanChannel() != nil && on }
    /// 0…3 bars from the signal strength.
    var bars: Int { guard let r = iface?.rssiValue(), connected else { return 0 }; return r > -60 ? 3 : r > -70 ? 2 : 1 }
    var symbol: String { !on ? "wifi.slash" : !connected ? "wifi.exclamationmark" : "wifi" }
    var needsLocation: Bool { location.authorizationStatus != .authorizedAlways && location.authorizationStatus != .authorized }

    func askLocation() { if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() } }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { changed() }

    func setPower(_ on: Bool) { try? iface?.setPower(on) }

    /// Nearby networks, strongest first, one per name. Takes a second or two; call off the main thread.
    func scan() -> [(ssid: String, bars: Int, secure: Bool)] {
        let found = (try? iface?.scanForNetworks(withName: nil)) ?? []
        var best: [String: CWNetwork] = [:]
        for n in found { guard let s = n.ssid, !s.isEmpty else { continue }; if (best[s]?.rssiValue ?? -999) < n.rssiValue { best[s] = n } }
        return best.values.sorted { $0.rssiValue > $1.rssiValue }.map { n in
            (n.ssid!, n.rssiValue > -60 ? 3 : n.rssiValue > -70 ? 2 : 1, !n.supportsSecurity(.none))
        }
    }

    /// Joins with the password from the keychain when there is one (networksetup reads it), else `password`
    /// through CoreWLAN, so a typed password never shows up in another process's arguments.
    func join(_ ssid: String, password: String?, done: @escaping (Bool) -> Void) {
        let iface = iface, dev = iface?.interfaceName ?? "en0"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            if let password {
                let net = (try? iface?.scanForNetworks(withName: ssid))?.max { $0.rssiValue < $1.rssiValue }
                ok = net.map { (try? iface?.associate(to: $0, password: password)) != nil } ?? false
            } else {
                let out = Script.shell("/usr/sbin/networksetup", ["-setairportnetwork", dev, ssid]).lowercased()
                ok = !out.contains("could not") && !out.contains("error")
            }
            DispatchQueue.main.async { done(ok) }
        }
    }
}

extension WiFi: CWEventDelegate {
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {}
}

// MARK: - Bluetooth

enum Bluetooth {
    // The calls System Settings and blueutil use for the radio itself; IOBluetooth has no public one.
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void
    private static let lib = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
    private static let getPower = dlsym(lib, "IOBluetoothPreferenceGetControllerPowerState").map { unsafeBitCast($0, to: GetPower.self) }
    private static let setPowerFn = dlsym(lib, "IOBluetoothPreferenceSetControllerPowerState").map { unsafeBitCast($0, to: SetPower.self) }

    static var on: Bool { (getPower?() ?? 0) != 0 }
    static func setPower(_ on: Bool) { setPowerFn?(on ? 1 : 0) }

    struct Device: Identifiable { let id: String; let name: String; let connected: Bool; let symbol: String; let device: IOBluetoothDevice }

    static func devices() -> [Device] {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).map { d in
            let major = d.deviceClassMajor, minor = d.deviceClassMinor
            let symbol = major == UInt32(kBluetoothDeviceClassMajorAudio) ? "headphones"
                : major == UInt32(kBluetoothDeviceClassMajorPeripheral) ? (minor & 0x10 != 0 ? "keyboard" : minor & 0x20 != 0 ? "computermouse" : "gamecontroller")
                : major == UInt32(kBluetoothDeviceClassMajorPhone) ? "iphone" : "dot.radiowaves.left.and.right"
            return Device(id: d.addressString ?? d.name ?? "?", name: d.name ?? d.addressString ?? "Device", connected: d.isConnected(), symbol: symbol, device: d)
        }.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    static var connectedCount: Int { devices().filter(\.connected).count }

    static func toggle(_ d: Device, done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if d.connected { d.device.closeConnection() } else { d.device.openConnection() }
            DispatchQueue.main.async(execute: done)
        }
    }
}

// MARK: - Keyboard layout

enum InputSources {
    struct Source: Identifiable { let id: String; let name: String; let short: String; let ref: TISInputSource }

    private static func prop<T>(_ s: TISInputSource, _ key: CFString) -> T? {
        TISGetInputSourceProperty(s, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! T }
    }
    private static func make(_ s: TISInputSource) -> Source {
        let lang = (prop(s, kTISPropertyInputSourceLanguages) as [String]?)?.first ?? "?"
        let id: String = prop(s, kTISPropertyInputSourceID) ?? ""
        // "com.apple.keylayout.US" → US, "…ABC-India" → ABC: two English layouts would both be "EN" by language.
        let tail = id.split(separator: ".").last.map { String($0.split(separator: "-").first ?? $0) } ?? lang
        return Source(id: id, name: prop(s, kTISPropertyLocalizedName) ?? lang, short: String(tail.prefix(3)).uppercased(), ref: s)
    }

    static var current: Source { make(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }

    /// The layouts and input methods enabled in System Settings → Keyboard.
    static var enabled: [Source] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String, kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        return ((TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []).map(make)
    }

    static func select(_ s: Source) { TISSelectInputSource(s.ref) }

    static func watch(_ f: @escaping () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in f() }
    }
}
