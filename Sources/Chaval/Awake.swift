import AppKit
import IOKit.pwr_mgt
import IOKit.ps

/// Keeps the Mac awake, Amphetamine style: for a while or until turned off, optionally letting the display sleep, and
/// optionally with the lid closed.
///
/// - Idle sleep: power assertions held by Chaval itself, so macOS drops them the moment Chaval quits or crashes; the
///   setting is remembered, so they come back when Chaval starts again.
/// - Lid closed: only root may turn sleep off entirely (`pmset disablesleep`). A one-time setup, with the user's
///   password, installs a sudoers rule allowing exactly `pmset -a disablesleep 1` and `… 0` without one. Chaval turns it
///   back off when Awake ends, when the battery falls below `batteryFloor` %, when Chaval quits, and when it starts with
///   Awake off (which covers a crash).
enum KeepAwake {
    static let changed = Notification.Name("chavalAwakeChanged")
    private static var held: [IOPMAssertionID] = []
    private static var timer: Timer?
    private static var sleepDisabled = false
    private static let d = UserDefaults.standard
    static let batteryFloor = 20
    private static let rule = "/etc/sudoers.d/chaval-awake"

    static var on: Bool { d.bool(forKey: "keepAwake") }
    /// When a timed session ends; nil = until turned off.
    static var until: Date? { d.object(forKey: "keepAwakeUntil") as? Date }
    static var displaySleep: Bool {
        get { d.bool(forKey: "keepAwakeDisplaySleep") }
        set { d.set(newValue, forKey: "keepAwakeDisplaySleep"); apply() }
    }
    static var lidClosed: Bool {
        get { d.bool(forKey: "keepAwakeLidClosed") }
        set { d.set(newValue, forKey: "keepAwakeLidClosed"); apply() }
    }
    /// The one-time setup is done.
    static var lidReady: Bool { FileManager.default.fileExists(atPath: rule) }

    /// Turns it on (for `minutes`, or until turned off) or off.
    static func set(_ on: Bool, minutes: Int? = nil) {
        d.set(on, forKey: "keepAwake")
        if on, let minutes { d.set(Date().addingTimeInterval(Double(minutes) * 60), forKey: "keepAwakeUntil") }
        else { d.removeObject(forKey: "keepAwakeUntil") }
        apply()
    }

    /// At launch, and after every change.
    static func apply() {
        held.forEach { IOPMAssertionRelease($0) }; held = []
        if on, let until, until <= Date() { d.set(false, forKey: "keepAwake"); d.removeObject(forKey: "keepAwakeUntil") } // ran out while Chaval was away
        if on {
            var types = [kIOPMAssertionTypePreventUserIdleSystemSleep]
            if !displaySleep { types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep) }
            for type in types {
                var id = IOPMAssertionID(0)
                if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Chaval: Awake" as CFString, &id) == kIOReturnSuccess { held.append(id) }
            }
        }
        setLid(on && lidClosed && batteryOK())
        // Checks the clock (timed sessions) and the battery (lid-closed safety) while on.
        timer?.invalidate(); timer = nil
        if on { timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in tick() } }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func tick() {
        if let until, until <= Date() { return set(false) }
        if sleepDisabled && !batteryOK() { setLid(false); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// On battery below the floor, the lid-closed hold lets go: a Mac that can't sleep in a bag is a hot, flat Mac.
    private static func batteryOK() -> Bool {
        let b = Widgets.battery()
        return !b.present || b.plugged || b.level > batteryFloor
    }

    /// Sleep fully off (lid closed too) or back to normal. Always resets to normal when not wanted, so a crash with it
    /// on is undone by the next launch.
    private static func setLid(_ disable: Bool) {
        guard lidReady else { sleepDisabled = false; return }
        guard disable != sleepDisabled || !disable else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            Script.shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disable ? "1" : "0"])
        }
        sleepDisabled = disable
    }

    /// Chaval quitting: everything back to normal.
    static func release() {
        held.forEach { IOPMAssertionRelease($0) }; held = []
        if lidReady { Script.shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]) }
        sleepDisabled = false
    }

    /// The one-time setup for lid-closed awake: macOS asks for the password, a rule allowing only the two `pmset`
    /// commands is checked with visudo and installed. Calls back on main with whether it worked.
    static func setUpLid(done: @escaping (Bool) -> Void) {
        let user = NSUserName()
        let line = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let tmp = "/tmp/chaval-awake-\(UUID().uuidString)"
        let sh = "printf '%s\\\\n' '\(line)' > \(tmp) && /usr/sbin/visudo -cf \(tmp) && /usr/bin/install -m 0440 -o root -g wheel \(tmp) \(rule); rm -f \(tmp)"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Script.run("do shell script \"\(sh)\" with administrator privileges with prompt \"Chaval needs your password once to keep your Mac awake with the lid closed.\"")
            DispatchQueue.main.async { done(lidReady); apply() }
        }
    }

    /// "42m left", "1h 05m left", or "" when on until turned off.
    static var remaining: String {
        guard on, let until else { return "" }
        let m = max(0, Int(until.timeIntervalSinceNow / 60) + 1)
        return m >= 60 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(m)m"
    }
}
