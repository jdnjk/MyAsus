// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
// ASUS controls for macOS: normalized profiles, battery charge limit and FnLock.
// ABI 5 capabilities gate writes; older drivers are read-only. Only explicitly saved
// settings are replayed at startup and on wake; the driver reconciles power transitions.
// No power-limit, manual fan-curve or lighting controls are exposed.
//
// Inspired by asusctl / rog-control-center (asus-linux.org, Luke Jones and contributors, MPL-2.0); no code is taken from it.
// Talks only to the AsusSMC user client (ABI 5, 36 UInt32 words, no sudo).
// debug.amdcppc.sensors is read only when the driver advertises referenceSensors.
//
// --bench is intentionally refused: this app does not run hardware load tests.
// Build: scripts/build-rogcontrol.sh
import Foundation
#if !ROG_LOGIC_TESTS
import AppKit
import SwiftUI
import Charts
import IOKit
import IOKit.ps
import UserNotifications
import ApplicationServices
#endif

// ---- driver access (AsusSMC ABI 5) -----------------------------------------------------------------------------------------
struct AsusCaps: OptionSet {
    let rawValue: UInt32
    static let profile = AsusCaps(rawValue: 1)
    static let charge = AsusCaps(rawValue: 2)
    static let fnLock = AsusCaps(rawValue: 4)
    static let manual = AsusCaps(rawValue: 8)
    static let keyboard = AsusCaps(rawValue: 16)
    static let slash = AsusCaps(rawValue: 32)
    static let hotkeys = AsusCaps(rawValue: 64)
    static let cpuFan = AsusCaps(rawValue: 128)
    static let gpuFan = AsusCaps(rawValue: 256)
    static let referenceSensors = AsusCaps(rawValue: 512)
    static let keyBindings = AsusCaps(rawValue: 1024)
}

struct AsusState {
    var present = false, ac = false, fanCustom = false
    var powerKnown = false, profileDeferred = false, lowPowerOverrideActive = false
    var lowPowerConfig: UInt32 = 0
    var hotkeysFirmwareValue: UInt32 = 1, keyActionSequence: UInt32 = 0, keyCaptureMask: UInt32 = 0
    var effectiveProfile: Int? {
        lowPowerConfig & 3 == 3 ? LowPowerRule.profile(in: lowPowerConfig) : desiredProfile
    }
    var abiVersion: UInt32 = 0
    var caps: AsusCaps = []
    // word 2 is actual; word 32 is the independently retained user intent.
    var profile: Int? = nil, desiredProfile: Int? = nil, charge: Int? = nil, fnLockLastRequest: Int? = nil
    var powerTransitionSequence: UInt32 = 0, performanceDropSequence: UInt32 = 0
    var lastProfileError: UInt32 = 0
    var lastKey: UInt32 = 0, eventSequence: UInt32 = 0
    var cpuFan = 0, gpuFan = 0
    var gpuMux: UInt32 = ~0, dgpu: UInt32 = ~0, baseTgp = 0
    var backlight: Int? = nil, backlightMax = 0
    var batDesign = 0, batFull = 0, batNow = 0, batState = 0, batRate = 0
    var writable: Bool { present && abiVersion == 5 }
    func supports(_ cap: AsusCaps) -> Bool { writable && caps.contains(cap) }
    func reports(_ cap: AsusCaps) -> Bool { present && (abiVersion < 4 || caps.contains(cap)) }
    var machineName: String { "ASUS notebook" }
    var powerLabel: String { !present ? "Disconnected" : !powerKnown ? "Power unknown" : ac ? "AC" : "Battery" }
    var selectedMode: Mode? { Mode.from(profile: abiVersion >= 5 ? desiredProfile : profile) }
    var actualLabel: String { Mode.from(profile: profile)?.title ?? "Unknown" }
    var profileStatus: String {
        var text = "Desired: \(selectedMode?.title ?? "Unknown") · Actual: \(actualLabel)."
        if lowPowerOverrideActive {
            text += " Low Power Mode override: \(Mode.from(profile: effectiveProfile)?.title ?? "Unknown"); ordinary desired is retained."
        }
        if abiVersion >= 5 && lastProfileError != 0 {
            text += String(format: " Profile reconciliation failed (0x%08X); target not confirmed.", lastProfileError)
        } else if effectiveProfile == 1 && (!powerKnown || !ac || profileDeferred) {
            text += profile == 0 ? " Temporarily running Balanced; Performance restores automatically on AC." :
                " Performance deferred; Balanced is requested but not confirmed. Performance restores automatically on AC."
        }
        return text
    }

    // Shared with the Foundation-only host tests. The old 32-word prefix never moves.
    static func decode(_ words: [UInt32]) -> AsusState {
        var s = AsusState()
        guard let version = words.first, (1...5).contains(version) else { return s }
        let minimum = version == 1 ? 18 : version == 2 ? 24 : version == 3 ? 27 : version == 4 ? 32 : 36
        guard words.count >= minimum else { return s }
        func optional(_ index: Int) -> Int? { words[index] == UInt32.max ? nil : Int(words[index]) }
        s.present = true; s.abiVersion = version
        s.ac = words[1] & 1 != 0; s.fanCustom = words[1] & 2 != 0
        s.powerKnown = version < 5 || words[1] & 8 == 0
        s.profileDeferred = version >= 5 && words[1] & 4 != 0
        s.profile = words[2] <= 2 ? Int(words[2]) : nil; s.charge = optional(3)
        s.cpuFan = Int(words[4]); s.gpuFan = Int(words[5])
        s.gpuMux = words[15]; s.dgpu = words[16]; s.baseTgp = Int(words[17])
        if version >= 2 {
            s.backlight = optional(18); s.backlightMax = Int(words[19])
            s.batDesign = Int(words[20]); s.batFull = Int(words[21]); s.batNow = Int(words[22])
            s.batState = Int(words[23] & 0xff); s.batRate = Int(words[23] >> 8)
        }
        if version >= 4 {
            s.caps = AsusCaps(rawValue: words[27])
            s.fnLockLastRequest = words[28] <= 1 ? Int(words[28]) : nil
            s.lastKey = words[30]; s.eventSequence = words[31]
        }
        if version == 5 {
            s.lowPowerConfig = words[6]
            s.hotkeysFirmwareValue = words[7]; s.keyActionSequence = words[8]; s.keyCaptureMask = words[9]
            s.lowPowerOverrideActive = words[1] & 16 != 0
            s.desiredProfile = words[32] <= 2 ? Int(words[32]) : nil
            s.powerTransitionSequence = words[33]; s.performanceDropSequence = words[34]
            s.lastProfileError = words[35]
        }
        return s
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case balanced, performance, silent
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        self == .silent ? "leaf" : self == .performance ? "flame" : "gauge.with.dots.needle.50percent"
    }
    // Normalized ABI values; the driver owns the firmware-specific mapping.
    var firmwareProfile: Int { self == .silent ? 2 : self == .performance ? 1 : 0 }
    static func from(profile: Int?) -> Mode? { profile == 2 ? .silent : profile == 1 ? .performance : profile == 0 ? .balanced : nil }
}

enum DesiredSettings {
    static func load(defaults: SettingsStorage = JSONSettings.shared) -> Mode? {
        if defaults.object(forKey: "desired.mode") != nil {
            return defaults.string(forKey: "desired.mode").flatMap(Mode.init(rawValue:))
        }
        // Old names: performance meant Standard (0), turbo meant Enhanced (1).
        // Prefer an explicit AC preference, otherwise an explicit battery preference.
        for key in ["ac.mode", "battery.mode"] {
            let mode: Mode?
            switch defaults.string(forKey: key) {
            case "performance": mode = .balanced
            case "turbo": mode = .performance
            case "silent": mode = .silent
            default: mode = nil
            }
            if let mode { save(mode, defaults: defaults); return mode }
        }
        return nil // Never invent a default or migrate Manual into a write.
    }
    static func save(_ mode: Mode, defaults: SettingsStorage = JSONSettings.shared) {
        defaults.set(mode.rawValue, forKey: "desired.mode")
        defaults.removeObject(forKey: "ac.mode"); defaults.removeObject(forKey: "battery.mode")
    }
}

struct LowPowerRule: Equatable {
    var enabled = false
    var mode: Mode = .balanced
    func packed(active: Bool) -> Int {
        (enabled ? 1 : 0) | (active ? 2 : 0) | (mode.firmwareProfile << 8)
    }
    static func valid(_ packed: Int) -> Bool {
        packed >= 0 && packed & ~0x303 == 0 && ((packed >> 8) & 3) <= 2
    }
    static func profile(in packed: UInt32) -> Int? {
        valid(Int(packed)) ? Int((packed >> 8) & 3) : nil
    }
    static func load(defaults: SettingsStorage = JSONSettings.shared) -> LowPowerRule {
        LowPowerRule(enabled: defaults.bool(forKey: "lowpower.enabled"),
                     mode: defaults.string(forKey: "lowpower.mode").flatMap(Mode.init(rawValue:)) ?? .balanced)
    }
    func save(defaults: SettingsStorage = JSONSettings.shared) {
        defaults.set(enabled, forKey: "lowpower.enabled"); defaults.set(mode.rawValue, forKey: "lowpower.mode")
    }
}

enum ControlWhat: UInt64 { case profile = 1, charge = 5, fnLock = 9, lowPowerConfig = 10, fnHotkeysValue = 11 }
struct ControlRequest: Equatable {
    let what: ControlWhat
    let value: Int
}
enum RestoreReason { case startup, wake, powerChange }
enum ControlPolicy {
    static let visibleModes: [Mode] = [.balanced, .performance, .silent]
    static let chargeRange = 50...100
    static func canChoose(_ mode: Mode, state: AsusState) -> Bool {
        state.supports(.profile) && visibleModes.contains(mode)
    }
    static func allows(_ request: ControlRequest, state: AsusState) -> Bool {
        switch request.what {
        case .profile:
            guard let mode = Mode.from(profile: request.value) else { return false }
            return canChoose(mode, state: state)
        case .charge: return state.supports(.charge) && chargeRange.contains(request.value)
        case .fnLock, .fnHotkeysValue: return state.supports(.fnLock) && (0...1).contains(request.value)
        case .lowPowerConfig: return state.supports(.profile) && LowPowerRule.valid(request.value)
        }
    }
    static func restore(state: AsusState, defaults: SettingsStorage = JSONSettings.shared, reason: RestoreReason = .startup,
                        lowPowerActive: Bool? = nil) -> [ControlRequest] {
        guard reason != .powerChange else { return [] } // Reconciliation belongs only to AsusSMC.
        func saved(_ key: String) -> Int? {
            guard let value = defaults.object(forKey: key) as? NSNumber,
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  (0...100).contains(value.doubleValue) else { return nil }
            return value.intValue
        }
        let config = lowPowerActive.map { LowPowerRule.load(defaults: defaults).packed(active: $0) }
        let requests = replay(state: state, mode: DesiredSettings.load(defaults: defaults), charge: saved("charge"),
                              fnLock: saved("fnlock"), lowPowerConfig: config)
        if let polarity = saved("fn.hotkeysFirmwareValue") {
            let request = ControlRequest(what: .fnHotkeysValue, value: polarity)
            if allows(request, state: state) { return [request] + requests }
        }
        return requests
    }
    static func replay(state: AsusState, mode: Mode?, charge: Int?, fnLock: Int?, lowPowerConfig: Int? = nil) -> [ControlRequest] {
        var requests: [ControlRequest] = []
        // Apply the temporary rule first, before restoring ordinary desired.
        if let lowPowerConfig { requests.append(ControlRequest(what: .lowPowerConfig, value: lowPowerConfig)) }
        if let mode { requests.append(ControlRequest(what: .profile, value: mode.firmwareProfile)) }
        if let charge { requests.append(ControlRequest(what: .charge, value: charge)) }
        if let fnLock { requests.append(ControlRequest(what: .fnLock, value: fnLock)) }
        return requests.filter { allows($0, state: state) }
    }
}

// Physical hotkeys persist desired (never actual), without sending a second request.
struct DriverEventPolicy {
    private var lastSequence: UInt32?
    private var pendingFnLock = false
    private var pendingProfile = false

    mutating func observe(state: AsusState, defaults: SettingsStorage = JSONSettings.shared) {
        guard state.supports(.hotkeys) else { return }
        defer { lastSequence = state.eventSequence }
        guard let previous = lastSequence, previous != state.eventSequence else { return }
        switch state.lastKey {
        case 0x4e:
            guard state.supports(.fnLock), let value = state.fnLockLastRequest, (0...1).contains(value) else { return }
            defaults.set(value, forKey: "fnlock"); pendingFnLock = true
        case 0x9d, 0xae:
            guard let mode = Mode.from(profile: state.desiredProfile), ControlPolicy.canChoose(mode, state: state) else { return }
            DesiredSettings.save(mode, defaults: defaults); pendingProfile = true
        default:
            if let key = FnAction.functionKey(event: state.lastKey),
               FnAction.load(key: key, defaults: defaults).rawValue >= FnAction.nextProfile.rawValue,
               let mode = Mode.from(profile: state.desiredProfile) {
                DesiredSettings.save(mode, defaults: defaults); pendingProfile = true
            }
        }
    }

    mutating func restore(state: AsusState, defaults: SettingsStorage = JSONSettings.shared, reason: RestoreReason = .startup,
                          lowPowerActive: Bool? = nil) -> [ControlRequest] {
        observe(state: state, defaults: defaults)
        guard reason != .powerChange else { return [] }
        let requests = ControlPolicy.restore(state: state, defaults: defaults, reason: reason,
                                             lowPowerActive: lowPowerActive).filter { request in
            switch request.what {
            case .fnLock: return !pendingFnLock
            case .profile: return !pendingProfile
            case .charge, .lowPowerConfig, .fnHotkeysValue: return true
            }
        }
        pendingFnLock = false; pendingProfile = false
        return requests
    }
}

struct PerformanceDropNotice {
    let sequence: UInt32
    let body: String
}
struct PerformanceDropPolicy {
    private var lastSequence: UInt32?
    mutating func observe(state: AsusState) -> PerformanceDropNotice? {
        guard state.writable else { return nil } // Keep the baseline across transient read failures.
        defer { lastSequence = state.performanceDropSequence }
        guard let previous = lastSequence, previous != state.performanceDropSequence else { return nil }
        // Compare counters, not AC snapshots: even a quick unplug/replug must be observed.
        let detail: String
        if state.lastProfileError != 0 {
            detail = String(format: "Balanced was requested, but the hardware change was not confirmed (0x%08X). Actual: %@. The driver will retry the current effective preset.", state.lastProfileError, state.actualLabel)
        } else if state.effectiveProfile != 1 {
            detail = "The effective preset has since changed to \(Mode.from(profile: state.effectiveProfile)?.title ?? "Unknown"). Actual: \(state.actualLabel)."
        } else if state.powerKnown && state.ac && state.profile == 1 {
            detail = "Performance has already been restored on AC after the temporary Balanced request."
        } else if state.profile == 0 {
            detail = "Temporarily running Balanced. Performance restores automatically when AC power returns."
        } else {
            detail = "Balanced was requested, but the actual mode is not confirmed. Performance restores automatically when AC power returns."
        }
        let context = state.lowPowerOverrideActive ? " Low Power Mode preset is active; ordinary desired is retained." : ""
        return PerformanceDropNotice(sequence: state.performanceDropSequence,
                                     body: "AC power was disconnected while the effective preset was Performance. " + detail + context)
    }
}

#if !ROG_LOGIC_TESTS
@MainActor
enum Asus {
    enum Sel: UInt32 { case state = 0, set = 1, keyActions = 2 }

    static func open() -> io_connect_t? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AsusSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        return IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS ? conn : nil
    }

    // Classify why the controls are (un)available without writing anything.
    // state() collapses every failure to present=false; diagnose() reads the service registry
    // so the UI can distinguish "not installed" from an older or unavailable driver.
    enum DriverStatus: Equatable {
        case ready
        case notInstalled                     // no AsusSMC service in the IORegistry
        case loadedReadOnly(abi: UInt32)      // service present, AsusControl-ABI < 5
        case loadedNoControls                 // service present but the required control interface is unavailable
    }
    static func diagnose() -> DriverStatus {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AsusSMC"))
        guard svc != 0 else { return .notInstalled }
        defer { IOObjectRelease(svc) }
        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any] else { return .notInstalled }
        if let abi = (props["AsusControl-ABI"] as? NSNumber)?.uint32Value, abi < 5 { return .loadedReadOnly(abi: abi) }
        var conn: io_connect_t = 0
        let opened = IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS
        if opened { IOServiceClose(conn) }
        return opened ? .ready : .loadedNoControls
    }

    static func call(_ sel: Sel, scalars: [UInt64] = [], input: [UInt8]? = nil, outCount: Int = 0) -> (kern_return_t, [UInt8]) {
        guard let c = open() else { return (kIOReturnNotFound, []) }
        defer { IOServiceClose(c) }
        var out = [UInt8](repeating: 0, count: outCount)
        var outSize = outCount
        var sc = scalars
        let inp = input ?? []
        let kr: kern_return_t = sc.withUnsafeMutableBufferPointer { sb in
            inp.withUnsafeBytes { ib in
                out.withUnsafeMutableBytes { ob in
                    IOConnectCallMethod(c, sel.rawValue, sb.baseAddress, UInt32(sb.count), inp.isEmpty ? nil : ib.baseAddress, ib.count,
                                        nil, nil, outCount > 0 ? ob.baseAddress : nil, &outSize)
                }
            }
        }
        return (kr, Array(out.prefix(outSize)))
    }

    static func state() -> AsusState {
        let (kr, bytes) = call(.state, outCount: 36 * 4)
        guard kr == KERN_SUCCESS, bytes.count % 4 == 0 else { return AsusState() }
        // Decode without assuming the UInt8 buffer has UInt32 alignment.
        let words: [UInt32] = stride(from: 0, to: bytes.count, by: 4).map { i in
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        return AsusState.decode(words)
    }

    @discardableResult static func set(_ request: ControlRequest) -> kern_return_t {
        // Recheck the current ABI, caps and power source at the write boundary as well as in the UI.
        guard JSONSettings.shared.isWritable, ControlPolicy.allows(request, state: state()) else { return kIOReturnUnsupported }
        return call(.set, scalars: [request.what.rawValue, UInt64(request.value)]).0
    }
    static func bind(key: Int, action: FnAction) -> kern_return_t {
        let s = state()
        guard JSONSettings.shared.isWritable, (1...12).contains(key), s.supports(.keyBindings),
              s.keyCaptureMask & (1 << UInt32(key - 1)) != 0 else { return kIOReturnUnsupported }
        return call(.set, scalars: [UInt64(0x100 + key), UInt64(action.rawValue)]).0
    }
    static func keyActions(after: UInt32) -> [UInt32]? {
        let (kr, bytes) = call(.keyActions, scalars: [UInt64(after)], outCount: (2 + 64 * 4) * 4)
        guard kr == KERN_SUCCESS, bytes.count % 4 == 0 else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map { i in
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
    }
}

// AmdCppc: "tctl=<m°C> pkg_mw=<mW>" (power averaged since the previous read) and the per-CPU clock report
enum Sensors {
    static func string(_ name: String) -> String? {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len + 1)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func read() -> (tctl: Double?, watts: Double?) {
        guard let s = string("debug.amdcppc.sensors") else { return (nil, nil) }
        var t: Double?, w: Double?
        for kv in s.split(separator: " ") {
            let p = kv.split(separator: "="); guard p.count == 2, let v = Double(p[1]) else { continue }
            if p[0] == "tctl", v > -1 { t = v / 1000 }
            if p[0] == "pkg_mw", v > 0 { w = v / 1000 }
        }
        return (t, w)
    }
    // average effective MHz of the busy CPUs 0-7 (Zen 5) and 8-23 (Zen 5c) from debug.amdcppc.freq
    static func clocks() -> (big: Int, little: Int)? {
        guard let s = string("debug.amdcppc.freq") else { return nil }
        var big: [Int] = [], little: [Int] = []
        for part in s.split(separator: "|").dropFirst() {
            let f = part.split(separator: " ")
            guard f.count >= 2, let cpu = Int(f[0]) else { continue }
            let v = f[1].split(separator: "/")
            guard v.count >= 2, let mhz = Int(v[0]), let busy = Int(v[1].dropLast()), busy >= 50 else { continue }
            if cpu < 8 { big.append(mhz) } else { little.append(mhz) }
        }
        func avg(_ a: [Int]) -> Int { a.isEmpty ? 0 : a.reduce(0, +) / a.count }
        return (avg(big), avg(little))
    }
}

// ---- login item (a user LaunchAgent; no signing needed) ------------------------------------------------------------------
enum LoginItem {
    static let label = "com.jdnjk.MyAsusControl"
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    static func set(_ on: Bool) {
        if !on { try? FileManager.default.removeItem(at: plist); return }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let d: [String: Any] = ["Label": label, "ProgramArguments": [exe, "--background"], "RunAtLoad": true, "ProcessType": "Interactive",
                                "LimitLoadToSessionType": "Aqua"]
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        (d as NSDictionary).write(to: plist, atomically: true)
    }
}

// Foreground notifications use the same banner presentation as background delivery.
final class PerformanceNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// ---- model -------------------------------------------------------------------------------------------------------------------
@MainActor
final class RogModel: ObservableObject {
    @Published var st = AsusState()
    @Published var tctl: Double?
    @Published var gpuTemperature: Double?
    @Published var temperatureSources = "No temperature sample yet"
    @Published var watts: Double?
    @Published var message = ""
    @Published var selectedPage: RogPage = .overview
    @Published var bindings = (1...12).map { FnAction.load(key: $0) }
    @Published var bindingsError = ""
    var configurationError: String { JSONSettings.shared.error ?? "" }
    @Published var loginEnabled = LoginItem.enabled
    // Retained for the existing reference visualization, which is not exposed or loaded by this app.
    @Published var curve: [UInt8]? = nil
    @Published var gpuCurve: [UInt8]? = nil
    @Published var curveMode: Mode = .performance
    @Published var profileError = ""
    @Published var chargeError = ""
    @Published var fnLockError = ""
    @Published var notificationsEnabled = JSONSettings.shared.bool(forKey: "performance.notifications")
    @Published var notificationStatus = "Checking notification permission…"
    @Published var driverStatus: Asus.DriverStatus = .notInstalled
    var activeMode: Mode? { st.present ? Mode.from(profile: st.profile) : nil }
    var selectedMode: Mode? { st.present ? st.selectedMode : nil }
    var modeLabel: String { activeMode?.title ?? "Unknown" }
    var driverNotice: String {
        st.present && !st.writable ? "AsusSMC ABI \(st.abiVersion): read-only. ABI 5 is required for controls." : ""
    }
    // Concrete reason + remediation for the menu bar / banners. Empty when ready.
    var driverStatusNotice: String {
        switch driverStatus {
        case .ready: return ""
        case .notInstalled:
            return "AsusSMC is not installed or not loaded. Install a compatible AsusSMC.kext through OpenCore with Lilu + VirtualSMC, then reboot."
        case .loadedReadOnly(let abi):
            return "AsusSMC ABI \(abi) is loaded but read-only. ABI 5 is required for controls; install a compatible AsusSMC build."
        case .loadedNoControls:
            return "AsusSMC is loaded but the required ABI 5 control interface is unavailable. Install a compatible AsusSMC build and reboot."
        }
    }
    var driverStatusSymbol: String {
        driverStatus == .ready ? (activeMode ?? .balanced).symbol : "exclamationmark.triangle.fill"
    }
    var fnLockLabel: String {
        st.fnLockLastRequest.map { $0 == 0 ? "Unlocked · direct shortcuts" : "Locked · F1–F12" } ?? "Unknown"
    }
    var eventLabel: String { String(format: "lastKey 0x%08X · sequence %u", st.lastKey, st.eventSequence) }
    var onChange: (() -> Void)?
    @Published var lowPowerRule = LowPowerRule.load()
    @Published var lowPowerError = ""
    @Published var macOSLowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let notificationDelegate = PerformanceNotificationDelegate()
    private var timer: Timer?
    private var driverEvents = DriverEventPolicy()
    private var performanceDrops = PerformanceDropPolicy()
    private var keyUI = KeyUIQueue()
    var visible = false { didSet { schedule() } }

    init() {
        if JSONSettings.shared.isWritable {
            let wanted = JSONSettings.shared.bool(forKey: "openAtLogin")
            if LoginItem.enabled != wanted { LoginItem.set(wanted) }
            loginEnabled = LoginItem.enabled
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        updateNotificationPermission()
        refresh()
        // Do not adopt firmware readback as a saved user preference on first launch.
        applyAll(reason: .startup)
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncLowPowerRule() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let model = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { model.applyAll(reason: .wake) }
            }
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<RogModel>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { m.powerChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        schedule()
    }

    func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common) // Also sample while menu tracking or in the background.
    }

    private func readState() {
        st = Asus.state()
        // state() folds every open failure into present=false; diagnose() reads the registry so the
        // icon/banner can distinguish "not installed" from "old ABI" or an unavailable interface.
        driverStatus = st.present ? (st.writable ? .ready : .loadedReadOnly(abi: st.abiVersion)) : Asus.diagnose()
        driverEvents.observe(state: st)
        if let notice = performanceDrops.observe(state: st), notificationsEnabled { deliver(notice) }
        if st.supports(.keyBindings) {
            if keyUI.cursor == nil || Int32(bitPattern: st.keyActionSequence &- (keyUI.cursor ?? 0)) < 0 {
                keyUI.cursor = st.keyActionSequence // initial/restarted driver baseline; do not replay stale actions
            }
            if let words = Asus.keyActions(after: keyUI.cursor ?? st.keyActionSequence), let events = keyUI.decode(words) {
                for event in events { performKeyAction(event.action) }
            }
        }
    }

    func refresh() {
        readState()
        let sensors = NativeSMCTelemetry.sample()
        tctl = sensors.cpu; gpuTemperature = sensors.gpu; watts = nil
        temperatureSources = "CPU: \(sensors.cpuSource). GPU: \(sensors.gpuSource). Fan RPM: ASUS TACH/WMI."
        if !st.reports(.gpuFan) { temperatureSources += " No separate GPU fan telemetry is available." }
        // Recover a missed system notification without replaying ordinary desired.
        if macOSLowPowerActive != ProcessInfo.processInfo.isLowPowerModeEnabled { syncLowPowerRule() }
        onChange?()
    }

    func powerChanged() {
        // Always sample the counter, even if AC has already returned. Never SET a profile here.
        refresh()
    }

    func applyAll(reason: RestoreReason) {
        readState()
        guard st.present else { message = driverStatusNotice.isEmpty ? "AsusSMC is not loaded" : driverStatusNotice; return }
        macOSLowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
        let requests = driverEvents.restore(state: st, reason: reason, lowPowerActive: macOSLowPowerActive)
        profileError = ""; chargeError = ""; fnLockError = ""; lowPowerError = ""
        for request in requests {
            let error = Asus.set(request) == KERN_SUCCESS ? "" : "Saved \(request.what) request was refused."
            switch request.what {
            case .profile: profileError = error
            case .charge: chargeError = error
            case .fnLock, .fnHotkeysValue: fnLockError = error
            case .lowPowerConfig: lowPowerError = error
            }
        }
        applyBindings()
        readState() // Profile SET success acknowledges intent, NOT hardware reconciliation.
        let errors = [profileError, chargeError, fnLockError, lowPowerError].filter { !$0.isEmpty }
        message = !st.writable ? driverNotice : !errors.isEmpty ? errors.joined(separator: "; ") :
            requests.isEmpty ? "No supported saved settings to restore." : "Saved requests accepted. " + st.profileStatus
        onChange?()
    }

    func choose(_ mode: Mode) {
        readState()
        guard ControlPolicy.canChoose(mode, state: st) else {
            profileError = "Profile unavailable; ABI 5 profile support is required."
            return
        }
        profileError = Asus.set(ControlRequest(what: .profile, value: mode.firmwareProfile)) == KERN_SUCCESS ? "" : "Profile intent was refused."
        if profileError.isEmpty { DesiredSettings.save(mode) }
        readState()
        message = profileError.isEmpty ? "\(mode.title) desired intent accepted. " + st.profileStatus : profileError
        onChange?()
    }
    func setCharge(_ value: Int) {
        // Unknown readback is not evidence that a supported write is unavailable.
        let request = ControlRequest(what: .charge, value: value)
        chargeError = Asus.set(request) == KERN_SUCCESS ? "" : "Charge limit unavailable or refused."
        if chargeError.isEmpty { JSONSettings.shared.set(value, forKey: "charge") }
        message = chargeError.isEmpty ? "Charge limit requested: \(value)%" : chargeError
        readState()
        onChange?()
    }
    func setFnLock(_ value: Int) {
        fnLockError = Asus.set(ControlRequest(what: .fnLock, value: value)) == KERN_SUCCESS ? "" : "FnLock unavailable or refused."
        if fnLockError.isEmpty { JSONSettings.shared.set(value, forKey: "fnlock") }
        message = fnLockError.isEmpty ? "FnLock requested: \(value == 1 ? "On" : "Off") (not hardware readback)" : fnLockError
        readState()
        onChange?()
    }
    func setLowPowerRule(enabled: Bool? = nil, mode: Mode? = nil) {
        if let enabled { lowPowerRule.enabled = enabled }
        if let mode { lowPowerRule.mode = mode }
        lowPowerRule.save() // Never changes desired.mode.
        syncLowPowerRule()
    }
    func syncLowPowerRule() {
        macOSLowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
        let request = ControlRequest(what: .lowPowerConfig, value: lowPowerRule.packed(active: macOSLowPowerActive))
        lowPowerError = Asus.set(request) == KERN_SUCCESS ? "" : "Low Power Mode rule unavailable or refused (ABI 5 profile support required)."
        readState()
        onChange?()
    }
    func clearLowPowerOverride() {
        // A normal app exit restores the driver's ordinary desired, but preserves the saved rule.
        _ = Asus.set(ControlRequest(what: .lowPowerConfig, value: lowPowerRule.packed(active: false)))
    }
    func setNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        JSONSettings.shared.set(enabled, forKey: "performance.notifications")
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    if let error { self?.notificationStatus = "Notification permission error: \(error.localizedDescription)" }
                    else { self?.updateNotificationPermission() }
                }
            }
        } else { updateNotificationPermission() }
    }
    func updateNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: String
            switch settings.authorizationStatus {
            case .denied: status = "Notifications denied. Enable ROG Control in System Settings → Notifications; profile controls still work."
            case .notDetermined: status = "Permission not requested. Turn on notifications to request access."
            case .authorized, .provisional: status = "Notification permission granted."
            @unknown default: status = "Notification permission unknown."
            }
            Task { @MainActor [weak self] in self?.notificationStatus = status }
        }
    }
    private func deliver(_ notice: PerformanceDropNotice) {
        let content = UNMutableNotificationContent()
        content.title = "Performance on battery"
        content.body = notice.body
        content.sound = .default
        // UUID also avoids replacing a prior notification after a full counter wrap.
        let request = UNNotificationRequest(identifier: "performance-drop-\(notice.sequence)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.notificationStatus = "Notification delivery failed: \(error.localizedDescription)" }
        }
    }
    var batteryLine: String {
        guard st.batDesign > 5 else { return "battery data not available from the firmware" }
        var s = ""
        if st.batFull > 0 { s += String(format: "health %.0f %% (%d / %d mAh)", 100.0 * Double(st.batFull) / Double(st.batDesign), st.batFull, st.batDesign) }
        if st.batFull > 0, st.batNow > 0 { s += String(format: " · %.0f %%", 100.0 * Double(st.batNow) / Double(st.batFull)) }
        if st.batState & 2 != 0 { s += " · charging \(st.batRate) mA" } else if st.batState & 1 != 0 { s += " · \(st.batRate) mA" }
        return s
    }
    func setLogin(_ on: Bool) {
        guard JSONSettings.shared.isWritable else { return }
        JSONSettings.shared.set(on, forKey: "openAtLogin")
        LoginItem.set(on); loginEnabled = LoginItem.enabled
    }
    func canBind(_ key: Int) -> Bool {
        (1...12).contains(key) && st.supports(.keyBindings) && st.keyCaptureMask & (1 << UInt32(key - 1)) != 0
    }
    func applyBindings() {
        guard JSONSettings.shared.isWritable else { return }
        for key in 1...12 where canBind(key) {
            if Asus.bind(key: key, action: bindings[key - 1]) != KERN_SUCCESS { bindingsError = "F\(key) binding was refused." }
        }
    }
    func setBinding(_ key: Int, _ action: FnAction) {
        guard canBind(key) else { return }
        guard Asus.bind(key: key, action: action) == KERN_SUCCESS else { bindingsError = "F\(key) binding was refused."; return }
        bindings[key - 1] = action
        JSONSettings.shared.set(action.rawValue, forKey: "key.F\(key)")
        bindingsError = ""
    }
    func resetBindings() {
        guard JSONSettings.shared.isWritable else { return }
        for key in 1...12 {
            bindings[key - 1] = FnAction.defaults[key - 1]
            JSONSettings.shared.set(bindings[key - 1].rawValue, forKey: "key.F\(key)")
        }
        applyBindings()
    }
    func setFnPolarity(_ inverted: Bool) {
        let value = inverted ? 0 : 1
        fnLockError = Asus.set(ControlRequest(what: .fnHotkeysValue, value: value)) == KERN_SUCCESS ? "" : "Firmware Fn polarity request failed."
        if fnLockError.isEmpty { JSONSettings.shared.set(value, forKey: "fn.hotkeysFirmwareValue") }
        readState()
    }
    private func performKeyAction(_ action: FnAction) {
        guard JSONSettings.shared.isWritable else { return }
        switch action {
        case .settings:
            selectedPage = .settings
            (NSApp.delegate as? AppDelegate)?.showWindow()
        case .displays:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(url) }
        case .cameraPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
            message = "Camera privacy settings opened. A global hardware camera on/off toggle is not implemented or verified."
        case .lockScreen, .screenshot:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else {
                message = "This key action needs Accessibility permission for ROG Control; no keystroke was sent."
                NSBeep(); return
            }
            let code: CGKeyCode = action == .lockScreen ? 0x0c : 0x17 // Control+Command+Q / Shift+Command+5
            let flags: CGEventFlags = action == .lockScreen ? [.maskControl, .maskCommand] : [.maskShift, .maskCommand]
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { message = "Could not create shortcut events."; return }
            down.flags = flags; up.flags = flags
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        default: break // Native sound/brightness/touchpad/preset actions belong only to AsusSMC.
        }
    }
}

// ---- views ---------------------------------------------------------------------------------------------------------------------
struct Stat: View {
    let symbol: String, value: String, label: String
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// ABI: eight temperatures followed by eight fan duties. Raw firmware can contain
// 255 endpoints and repeated temperatures; never extrapolate or invent replacements.
struct FanCurvePoint: Identifiable {
    let id: Int
    let temperature: Int
    let duty: Int
    let segment: Int
}
struct FanCurveData {
    let points: [FanCurvePoint]
    let omitted: Int
    init(_ bytes: [UInt8]) {
        guard bytes.count == 16 else { points = []; omitted = bytes.count == 0 ? 0 : 8; return }
        var valid: [FanCurvePoint] = []
        var skipped = 0, segment = 0
        var previous: Int?
        for i in 0..<8 {
            let temperature = Int(bytes[i]), duty = Int(bytes[8 + i])
            guard (20...105).contains(temperature), (0...100).contains(duty),
                  previous == nil || temperature >= previous! else {
                skipped += 1; segment += 1; continue
            }
            valid.append(FanCurvePoint(id: i, temperature: temperature, duty: duty, segment: segment))
            previous = temperature
        }
        points = valid; omitted = skipped
    }
}

struct CurveChart: View {
    let c: [UInt8]
    let compact: Bool
    @State private var hovered: Int?
    private var data: FanCurveData { FanCurveData(c) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fan duty (%)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let point = data.points.first(where: { $0.id == hovered }) {
                    Text("\(point.temperature)°C · \(point.duty)%").font(.caption).monospacedDigit()
                }
            }.frame(height: 16)
            if data.points.isEmpty {
                Text("No valid fan curve data.").font(.callout).foregroundStyle(.secondary).frame(height: 100)
            } else {
                Chart(data.points) { point in
                    LineMark(x: .value("Temperature", point.temperature), y: .value("Fan duty", point.duty),
                             series: .value("Segment", point.segment))
                        .interpolationMethod(.linear).lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Temperature", point.temperature), y: .value("Fan duty", point.duty))
                        .symbolSize(point.id == hovered ? 70 : 24).foregroundStyle(Color.accentColor)
                }
                .chartXScale(domain: 20...105).chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: [20, 40, 60, 80, 100]) { value in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel { if let n = value.as(Int.self) { Text("\(n)°") } }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel { if let n = value.as(Int.self) { Text("\(n)%") } }
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let origin = geometry[proxy.plotAreaFrame].origin
                                    let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                                    hovered = data.points.min { a, b in
                                        distance(a, to: local, proxy: proxy) < distance(b, to: local, proxy: proxy)
                                    }?.id
                                case .ended: hovered = nil
                                }
                            }
                    }
                }
                .frame(height: compact ? 130 : 220)
                Text("Temperature (°C)").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            if data.omitted > 0 {
                Text("\(data.omitted) firmware point(s) outside the valid range or order are not plotted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fan duty by temperature")
        .accessibilityValue(data.points.map { "\($0.temperature) degrees Celsius, \($0.duty) percent" }.joined(separator: "; "))
    }
    private func distance(_ point: FanCurvePoint, to position: CGPoint, proxy: ChartProxy) -> CGFloat {
        guard let x = proxy.position(forX: point.temperature), let y = proxy.position(forY: point.duty) else { return .infinity }
        return pow(x - position.x, 2) + pow(y - position.y, 2)
    }
}

struct FanCurveView: View {
    @ObservedObject var m: RogModel
    var compact = false
    @State private var fan = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(m.curveMode.title) firmware curve").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("Fan", selection: $fan) { Text("CPU").tag(0); Text("GPU").tag(1) }
                    .pickerStyle(.segmented).frame(width: 105).controlSize(.small)
            }
            if let bytes = fan == 0 ? m.curve : m.gpuCurve { CurveChart(c: bytes, compact: compact) }
            else { Text("Fan curve unavailable from firmware.").font(.caption).foregroundStyle(.secondary) }
            if !compact {
                Text("Firmware reference, not live RPM. Hover a point to read its temperature and duty.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum RogPage: String, CaseIterable, Identifiable {
    case overview = "Overview", performance = "Performance", battery = "Battery & Display", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .performance: return "gauge.with.dots.needle.50percent"
        case .battery: return "battery.75"
        case .settings: return "gearshape"
        }
    }
}

struct RogSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct RogControls: View {
    @ObservedObject var m: RogModel
    let page: RogPage
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if m.driverStatus != .ready {
                Label(m.driverStatusNotice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !m.configurationError.isEmpty { Label(m.configurationError, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            if page == .overview {
                RogSection(title: "Live telemetry") {
                    HStack(spacing: 16) {
                        Stat(symbol: "thermometer.medium", value: m.tctl.map { String(format: "%.1f°C", $0) } ?? "Unavailable", label: "CPU temperature")
                        Stat(symbol: "thermometer.medium", value: m.gpuTemperature.map { String(format: "%.1f°C", $0) } ?? "Unavailable", label: "GPU temperature")
                        Stat(symbol: "fan", value: m.st.reports(.cpuFan) ? "\(m.st.cpuFan)" : "Unavailable", label: m.st.reports(.gpuFan) ? "CPU fan · RPM" : "System fan · RPM")
                        Stat(symbol: "fan", value: m.st.reports(.gpuFan) ? "\(m.st.gpuFan)" : "Unavailable", label: "GPU fan · RPM")
                    }
                    Text(m.temperatureSources).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if page == .overview || page == .performance {
                RogSection(title: "Performance mode") { modes }
            }
            if page == .overview || page == .settings {
                RogSection(title: "FnLock") { fnLockControls }
            }
            if page == .overview || page == .battery {
                RogSection(title: "Battery care") {
                    VStack(alignment: .leading, spacing: 12) {
                        batteryControls
                        Text("60% for desk use · 80% for everyday use · 100% for travel").font(.callout).foregroundStyle(.secondary)
                    }.disabled(!m.st.present)
                }
            }
            if page == .overview {
                RogSection(title: "Graphics") { Text(gpuLine).font(.callout).foregroundStyle(.secondary) }
            }
            if page == .settings {
                RogSection(title: "Startup") {
                    Toggle("Open at Login", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) })).toggleStyle(.switch)
                    Text("Runs quietly in the menu bar at login. Closing the window keeps hardware control active.").font(.callout).foregroundStyle(.secondary)
                }
                RogSection(title: "Configuration file") {
                    Text(JSONSettings.shared.url.path).font(.caption).textSelection(.enabled)
                    Text("Loaded at login. Fn Lock defaults to unlocked/direct shortcuts. Changes are saved atomically; malformed files are preserved and make controls read-only. Restart after editing the file externally.").font(.caption).foregroundStyle(.secondary)
                    Button("Show configuration in Finder") { NSWorkspace.shared.selectFile(JSONSettings.shared.url.path, inFileViewerRootedAtPath: "") }
                }
                RogSection(title: "F1–F12 bindings") { keyBindingControls }
                RogSection(title: "Low Power Mode preset") { lowPowerControls }
                RogSection(title: "Performance notifications") {
                    Toggle("Notify when Performance loses AC power", isOn: Binding(get: { m.notificationsEnabled }, set: { m.setNotifications($0) }))
                    Text(m.notificationStatus).font(.callout).foregroundStyle(.secondary)
                    Button("Refresh permission status") { m.updateNotificationPermission() }
                }
                RogSection(title: "About ROG Control") {
                    Text(m.st.machineName).font(.headline)
                    Text("Only explicitly saved desired, charge and FnLock settings are restored at startup and on wake. AsusSMC temporarily falls back from Performance to Balanced on battery or unknown power, then restores Performance on AC. Low Power Mode can temporarily override the preset without replacing ordinary desired.").foregroundStyle(.secondary)
                    Link("Created by thanhnndev · github.com/thanhnndev", destination: URL(string: "https://github.com/thanhnndev")!)
                    Link("Inspired by asusctl and the asus-linux community", destination: URL(string: "https://asus-linux.org")!)
                }
            }
            if !m.message.isEmpty {
                Label(m.message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    var fnLockControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("FnLock").font(.system(size: 12))
                ChoiceButton(title: "Unlocked · shortcuts", selected: m.st.fnLockLastRequest == 0) { m.setFnLock(0) }
                ChoiceButton(title: "Locked · F1–F12", selected: m.st.fnLockLastRequest == 1) { m.setFnLock(1) }
                Spacer()
            }.disabled(!m.st.supports(.fnLock))
            Text("Last request: \(m.fnLockLabel) — not hardware readback.").font(.caption).foregroundStyle(.secondary)
            Text("Default: unlocked, F1–F12 directly perform shortcuts. Fn+Esc always toggles, independent of the lock state.").font(.caption).foregroundStyle(.secondary)
            Toggle("Invert firmware Fn mode (calibration only)", isOn: Binding(get: { m.st.hotkeysFirmwareValue == 0 }, set: { m.setFnPolarity($0) })).disabled(!m.st.supports(.fnLock))
            Text("Firmware polarity must be verified on this BIOS. If the physical behavior is reversed, use the calibration option; the configuration keeps the logical unlocked/locked meaning.").font(.caption).foregroundStyle(.secondary)
            if m.st.supports(.hotkeys) { Text(m.eventLabel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !m.fnLockError.isEmpty { Text(m.fnLockError).font(.caption).foregroundStyle(.secondary) }
        }
    }
    var keyBindingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(1...12, id: \.self) { key in
                HStack {
                    Text("F\(key)").frame(width: 35, alignment: .leading)
                    Text(FnAction.original[key - 1]).font(.caption).foregroundStyle(.secondary).frame(width: 145, alignment: .leading)
                    Picker("F\(key) action", selection: Binding(get: { m.bindings[key - 1] }, set: { m.setBinding(key, $0) })) {
                        ForEach(FnAction.allCases) { action in Text(action.title).tag(action) }
                    }.labelsHidden().disabled(!m.canBind(key))
                    if !m.canBind(key) { Text("Needs bridge / capture").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button("Restore default bindings") { m.resetBindings() }
            Text("F12 opens this settings panel. Fn+Esc is reserved. F7 has no known event; F11 needs macOS key capture before remapping can be verified. The optional EC query bridge enables other firmware-routed keys without duplicate PS/2 actions.").font(.caption).foregroundStyle(.secondary)
            Text("F10 currently opens camera privacy settings, not a verified global hardware camera switch. Lock/screenshot shortcuts require Accessibility permission. App actions need the app running in the background.").font(.caption).foregroundStyle(.secondary)
            if !m.bindingsError.isEmpty { Text(m.bindingsError).font(.caption) }
        }
    }
    var batteryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChargeLimitControls(m: m)
            Text(m.batteryLine).font(.system(size: 11)).foregroundStyle(.secondary)
            if !m.chargeError.isEmpty { Text(m.chargeError).font(.caption).foregroundStyle(.red) }
        }
    }
    var lowPowerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use a fan preset when macOS enters Low Power Mode", isOn: Binding(
                get: { m.lowPowerRule.enabled }, set: { m.setLowPowerRule(enabled: $0) }))
            Picker("Low Power Mode preset", selection: Binding(
                get: { m.lowPowerRule.mode }, set: { m.setLowPowerRule(mode: $0) })) {
                ForEach(ControlPolicy.visibleModes) { Text($0.title).tag($0) }
            }
            Text("macOS Low Power Mode: \(m.macOSLowPowerActive ? "On" : "Off"). Automatic detection requires the app to remain running in the background. Disabling the rule, leaving Low Power Mode or quitting normally restores ordinary desired; Performance still falls back on battery.")
                .font(.caption).foregroundStyle(.secondary)
            if !m.lowPowerError.isEmpty { Text(m.lowPowerError).font(.caption).foregroundStyle(.red) }
        }.disabled(!m.st.supports(.profile))
    }
    var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModeRow(active: m.selectedMode, state: m.st, compact: compact) { m.choose($0) }
            Text(m.st.profileStatus).font(.caption).foregroundStyle(.secondary)
            if !m.profileError.isEmpty { Text(m.profileError).font(.caption).foregroundStyle(.red) }
        }
    }
    var gpuLine: String {
        var s = "GPU: "
        let mux = m.st.gpuMux
        s += mux == ~0 ? "MUX unknown" : (mux & 1 == 0 ? "dGPU only (MUX)" : "Hybrid")
        if m.st.dgpu != ~0 && m.st.dgpu & 1 != 0 { s += ", dGPU disabled" }
        if m.st.baseTgp > 0 { s += ", base TGP \(m.st.baseTgp) W" }
        return s
    }
}


// Plain state values keep the mode row's selection and capability gating synchronized.
struct ModeRow: View {
    let active: Mode?
    let state: AsusState
    let compact: Bool
    let choose: (Mode) -> Void
    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            ForEach(ControlPolicy.visibleModes) { mode in
                let selected = active == mode
                let unavailable = !ControlPolicy.canChoose(mode, state: state)
                Button { choose(mode) } label: {
                    VStack(spacing: compact ? 5 : 8) {
                        Image(systemName: mode.symbol).font(.system(size: compact ? 16 : 20))
                        Text(mode.title).font(.system(size: compact ? 11 : 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, compact ? 6 : 16)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.clear))
                }
                .buttonStyle(.plain).disabled(unavailable).opacity(unavailable ? 0.4 : 1)
                .accessibilityLabel(mode.title + (selected ? ", selected" : ""))
                .help(!state.supports(.profile) ? "ABI 5 profile capability required" : mode == .performance ? "Retains Performance intent on battery; AsusSMC temporarily uses Balanced until AC returns" : mode.title)
            }
        }
        .id("mode-\(active?.rawValue ?? "none")-\(state.ac)-\(state.supports(.profile))")
    }
}

struct ChoiceButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .fixedSize().padding(.horizontal, 8).padding(.vertical, 5)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.clear))
        }.buttonStyle(.plain).accessibilityLabel(title + (selected ? ", active" : ""))
    }
}

// Draft changes never write EC; only an explicit Apply sends what 5.
struct ChargeLimitControls: View {
    @ObservedObject var m: RogModel
    @State private var draft = 50
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Stepper("Charge limit: \(draft)%", value: $draft, in: ControlPolicy.chargeRange, step: 1)
                Button("Apply") { m.setCharge(draft) }
            }
            HStack(spacing: 6) {
                ForEach([50, 60, 80, 100], id: \.self) { value in
                    ChoiceButton(title: "\(value)%", selected: draft == value) { draft = value }
                }
                Spacer(minLength: 0)
            }
            Text(m.st.charge.map { "Reported limit: \($0)% · Apply to save draft" } ?? "Reported limit: unknown · Apply to save draft")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!m.st.supports(.charge))
        .onAppear { if let value = m.st.charge, ControlPolicy.chargeRange.contains(value) { draft = value } }
    }
}

// Keep the popover FnLock section on its own observation path, like the window controls.
struct FnLockPopover: View {
    @ObservedObject var m: RogModel
    var body: some View { RogControls(m: m, page: .overview, compact: true).fnLockControls }
}

// Primary surface: stable compact rows, immediate controls, optional details.
struct ContentView: View {
    @ObservedObject var m: RogModel
    let openWindow: () -> Void
    private var controls: RogControls { RogControls(m: m, page: .overview, compact: true) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROG Control").font(.system(size: 13, weight: .semibold))
                Spacer()
                Label(m.st.powerLabel,
                      systemImage: m.st.powerKnown && m.st.ac ? "powerplug" : "battery.75")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                quickStat(m.tctl.map { String(format: "%.0f°C", $0) } ?? "–", "CPU")
                quickStat(m.watts.map { String(format: "%.1f W", $0) } ?? "–", "Power")
                quickStat(m.st.reports(.cpuFan) ? "\(m.st.cpuFan)" : "–", "CPU RPM")
                quickStat(m.st.reports(.gpuFan) ? "\(m.st.gpuFan)" : "–", "GPU RPM")
            }
            ModeRow(active: m.selectedMode, state: m.st, compact: true) { m.choose($0) }.disabled(!m.st.present)
            Text(m.st.profileStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            inlineError(m.profileError)
            Divider()
            ChargeLimitControls(m: m)
            inlineError(m.chargeError)
            if m.st.batFull > 0 {
                HStack {
                    Text("Battery \(min(100, max(0, m.st.batNow * 100 / m.st.batFull)))%")
                    Spacer()
                    Text(m.st.batState & 2 != 0 ? "Charging" : !m.st.powerKnown ? "Power unknown" : m.st.ac ? "On AC" : "Discharging")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            FnLockPopover(m: m)
            if m.driverStatus != .ready {
                Label(m.driverStatusNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Menu("Settings") {
                    Toggle("Open at Login", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) }))
                    Toggle("Performance notifications", isOn: Binding(get: { m.notificationsEnabled }, set: { m.setNotifications($0) }))
                    Text(m.notificationStatus)
                    Button("Refresh notification permission") { m.updateNotificationPermission() }
                    Menu("Low Power Mode preset") {
                        Toggle("Enable automatic preset", isOn: Binding(get: { m.lowPowerRule.enabled }, set: { m.setLowPowerRule(enabled: $0) }))
                        ForEach(ControlPolicy.visibleModes) { mode in
                            Button((m.lowPowerRule.mode == mode ? "Selected: " : "") + mode.title) { m.setLowPowerRule(mode: mode) }
                        }
                        Text("Automatic detection requires the app running in background.")
                        Text(m.lowPowerError)
                    }.disabled(!m.st.supports(.profile))
                    Text(m.batteryLine)
                    Text(controls.gpuLine)
                    Button("Created by thanhnndev (GitHub)") { NSWorkspace.shared.open(URL(string: "https://github.com/thanhnndev")!) }
                    Button("Quit ROG Control") { NSApp.terminate(nil) }
                }.menuStyle(.borderlessButton).fixedSize().font(.caption)
                Spacer()
                Button("Open app", action: openWindow).buttonStyle(.borderless).font(.caption)
            }
        }.padding(14).frame(width: 350)
    }
    private func inlineError(_ text: String) -> some View {
        Group {
            if !text.isEmpty {
                Label(text, systemImage: "exclamationmark.triangle").font(.caption)
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func quickStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RogWindowView: View {
    @ObservedObject var m: RogModel
    private var page: RogPage { m.selectedPage }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ROG Control").font(.system(size: 21, weight: .semibold))
                    Text(m.st.machineName).font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.top, 20)
                VStack(spacing: 4) {
                    ForEach(RogPage.allCases) { destination in
                        Button { m.selectedPage = destination } label: {
                            Label(destination.rawValue, systemImage: destination.symbol)
                                .font(.system(size: 13, weight: page == destination ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .foregroundStyle(page == destination ? Color.accentColor : Color.primary)
                                .background(page == destination ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Label(m.st.powerLabel, systemImage: m.st.powerKnown && m.st.ac ? "powerplug" : "battery.75")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }.padding(12).frame(width: 210).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(page.rawValue).font(.system(size: 24, weight: .semibold))
                        Text("\(m.st.powerLabel) · \(m.st.profileStatus)").font(.callout).foregroundStyle(.secondary)
                    }
                    RogControls(m: m, page: page)
                }.padding(32).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .underPageBackgroundColor))
        }.frame(minWidth: 800, minHeight: 600)
    }
}

// ---- status item -------------------------------------------------------------------------------------------------------------
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    var model: RogModel!
    var window: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        model = RogModel()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView(m: model, openWindow: { [weak self] in self?.showWindow() }))
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        setupMenus()
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.clearLowPowerOverride()
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        model.refresh()
        model.visible = true
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ n: Notification) { updateVisibility() }
    func updateVisibility() { model.visible = popover.isShown || window?.isVisible == true }
    func windowWillClose(_ n: Notification) {
        model.visible = popover.isShown
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    @objc func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "ROG Control"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 800, height: 640)
            w.contentViewController = NSHostingController(rootView: RogWindowView(m: model))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("RogControl.MainWindow")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh(); updateVisibility()
    }
    @objc func refreshNow() { model.refresh() }
    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: "Created by thanhnndev\ngithub.com/thanhnndev\n\nInspired by asusctl and the asus-linux community.",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.addAttribute(.link, value: URL(string: "https://github.com/thanhnndev")!, range: (credits.string as NSString).range(of: "github.com/thanhnndev"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    func setupMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About ROG Control", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ROG Control", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ROG Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        let open = windowMenu.addItem(withTitle: "Open ROG Control", action: #selector(showWindow), keyEquivalent: "0"); open.target = self
        let refresh = windowMenu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r"); refresh.target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    func updateIcon() {
        guard let b = item.button else { return }
        let ready = model.driverStatus == .ready
        let symbol = ready ? (model.activeMode ?? .balanced).symbol : model.driverStatusSymbol
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: ready ? "ROG: \(model.modeLabel)" : "ROG: AsusSMC unavailable")
        img?.isTemplate = true
        b.image = img
        var tip = ready ? "ROG: \(model.modeLabel)" : "ROG: AsusSMC unavailable"
        if ready {
            if let t = model.tctl { tip += String(format: " · CPU %.0f°C", t) }
            if let w = model.watts { tip += String(format: " · %.1f W", w) }
        } else {
            tip += " — " + model.driverStatusNotice
        }
        b.toolTip = tip
    }
}

// Refuse before opening a driver connection, changing profiles or starting load threads.
if CommandLine.arguments.dropFirst().contains("--bench") {
    print("RogControl --bench is disabled for ASUS controls; no load test was started.")
    exit(1)
}

MainActor.assumeIsolated {                     // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
#endif
