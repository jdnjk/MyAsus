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
    var machineName: String { "ASUS 笔记本电脑" }
    var powerLabel: String { !present ? "未连接" : !powerKnown ? "电源状态未知" : ac ? "交流电" : "电池" }
    var selectedMode: Mode? { Mode.from(profile: abiVersion >= 5 ? desiredProfile : profile) }
    var actualLabel: String { Mode.from(profile: profile)?.title ?? "未知" }
    var profileStatus: String {
        var text = "期望模式：\(selectedMode?.title ?? "未知") · 实际模式：\(actualLabel)。"
        if lowPowerOverrideActive {
            text += " 低电量模式预设已启用：\(Mode.from(profile: effectiveProfile)?.title ?? "未知")；保留原有期望模式。"
        }
        if abiVersion >= 5 && lastProfileError != 0 {
            text += String(format: " 模式协调失败（0x%08X）；目标尚未确认。", lastProfileError)
        } else if effectiveProfile == 1 && (!powerKnown || !ac || profileDeferred) {
            text += profile == 0 ? " 暂时运行平衡模式；接通交流电后自动恢复性能模式。" :
                " 性能模式已延后；已请求平衡模式但尚未确认。接通交流电后自动恢复性能模式。"
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
    var title: String {
        switch self {
        case .balanced: return "平衡"
        case .performance: return "性能"
        case .silent: return "静音"
        }
    }
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
            detail = String(format: "已请求平衡模式，但硬件变更未确认（0x%08X）。实际模式：%@。驱动将重试当前生效的预设。", state.lastProfileError, state.actualLabel)
        } else if state.effectiveProfile != 1 {
            detail = "生效预设已变为\(Mode.from(profile: state.effectiveProfile)?.title ?? "未知")。实际模式：\(state.actualLabel)。"
        } else if state.powerKnown && state.ac && state.profile == 1 {
            detail = "临时请求平衡模式后，性能模式已在接通交流电后恢复。"
        } else if state.profile == 0 {
            detail = "暂时运行平衡模式。接通交流电后自动恢复性能模式。"
        } else {
            detail = "已请求平衡模式，但实际模式尚未确认。接通交流电后自动恢复性能模式。"
        }
        let context = state.lowPowerOverrideActive ? " 低电量模式预设已启用；保留原有期望模式。" : ""
        return PerformanceDropNotice(sequence: state.performanceDropSequence,
                                     body: "生效预设为性能模式时交流电已断开。" + detail + context)
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
        case loadedNoControls                 // service present but ABI property is unavailable
        case openFailed(code: kern_return_t)
        case stateFailed(code: kern_return_t)
    }
    static func diagnose() -> DriverStatus {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AsusSMC"))
        guard svc != 0 else { return .notInstalled }
        defer { IOObjectRelease(svc) }
        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any] else { return .notInstalled }
        guard let abi = (props["AsusControl-ABI"] as? NSNumber)?.uint32Value else { return .loadedNoControls }
        if abi < 5 { return .loadedReadOnly(abi: abi) }
        var conn: io_connect_t = 0
        let result = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        guard result == KERN_SUCCESS else { return .openFailed(code: result) }
        IOServiceClose(conn)
        let (status, _) = call(.state, outCount: 36 * 4)
        // diagnose() is used only after state() failed. A successful open alone is not readiness.
        return .stateFailed(code: status)
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
    @Published var temperatureSources = "尚无温度采样"
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
    @Published var notificationStatus = "正在检查通知权限…"
    @Published var driverStatus: Asus.DriverStatus = .notInstalled
    var activeMode: Mode? { st.present ? Mode.from(profile: st.profile) : nil }
    var selectedMode: Mode? { st.present ? st.selectedMode : nil }
    var modeLabel: String { activeMode?.title ?? "未知" }
    var driverNotice: String {
        st.present && !st.writable ? "AsusSMC ABI \(st.abiVersion)：只读。控制功能需要 ABI 5。" : ""
    }
    // Concrete reason + remediation for the menu bar / banners. Empty when ready.
    var driverStatusNotice: String {
        switch driverStatus {
        case .ready: return ""
        case .notInstalled:
            return "AsusSMC 未安装或未加载。请通过 OpenCore 安装兼容的 AsusSMC.kext、Lilu 和 VirtualSMC，然后重新启动。"
        case .loadedReadOnly(let abi):
            return "已加载 AsusSMC ABI \(abi)，但仅支持只读。控制功能需要 ABI 5；请安装兼容的 AsusSMC 版本。"
        case .loadedNoControls:
            return "已找到 AsusSMC 服务，但缺少 AsusControl-ABI。请检查是否加载了支持控制功能的兼容驱动。"
        case .openFailed(let code):
            return String(format: "已找到 AsusSMC 服务，但控制连接失败（0x%08X）。请检查驱动版本和用户客户端访问权限。", UInt32(bitPattern: code))
        case .stateFailed(let code):
            return String(format: "AsusSMC 连接已打开，但读取状态失败或返回无效响应（0x%08X）。请检查驱动 ABI 和访问权限。", UInt32(bitPattern: code))
        }
    }
    var driverStatusSymbol: String {
        driverStatus == .ready ? (activeMode ?? .balanced).symbol : "exclamationmark.triangle.fill"
    }
    var fnLockLabel: String {
        st.fnLockLastRequest.map { $0 == 0 ? "未锁定 · 直接使用快捷功能" : "已锁定 · F1–F12" } ?? "未知"
    }
    var eventLabel: String { String(format: "最近按键 0x%08X · 序列号 %u", st.lastKey, st.eventSequence) }
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
            // Refresh the executable path after an app rename or move.
            if wanted || LoginItem.enabled { LoginItem.set(wanted) }
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
        temperatureSources = "CPU: \(sensors.cpuSource). GPU: \(sensors.gpuSource). 风扇转速：ASUS TACH/WMI。"
        if !st.reports(.gpuFan) { temperatureSources += " 无单独的 GPU 风扇遥测数据。" }
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
        guard st.present else { message = driverStatusNotice.isEmpty ? "AsusSMC 未加载" : driverStatusNotice; return }
        macOSLowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
        let requests = driverEvents.restore(state: st, reason: reason, lowPowerActive: macOSLowPowerActive)
        profileError = ""; chargeError = ""; fnLockError = ""; lowPowerError = ""
        for request in requests {
            let error = Asus.set(request) == KERN_SUCCESS ? "" : "已保存的 \(request.what) 请求被拒绝。"
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
            requests.isEmpty ? "没有可恢复的受支持已保存设置。" : "已保存的请求已接受。" + st.profileStatus
        onChange?()
    }

    func choose(_ mode: Mode) {
        readState()
        guard ControlPolicy.canChoose(mode, state: st) else {
            profileError = "模式不可用；需要 ABI 5 模式支持。"
            return
        }
        profileError = Asus.set(ControlRequest(what: .profile, value: mode.firmwareProfile)) == KERN_SUCCESS ? "" : "模式请求被拒绝。"
        if profileError.isEmpty { DesiredSettings.save(mode) }
        readState()
        message = profileError.isEmpty ? "已接受\(mode.title)模式请求。" + st.profileStatus : profileError
        onChange?()
    }
    func setCharge(_ value: Int) {
        // Unknown readback is not evidence that a supported write is unavailable.
        let request = ControlRequest(what: .charge, value: value)
        chargeError = Asus.set(request) == KERN_SUCCESS ? "" : "充电上限不可用或请求被拒绝。"
        if chargeError.isEmpty { JSONSettings.shared.set(value, forKey: "charge") }
        message = chargeError.isEmpty ? "已请求充电上限：\(value)%" : chargeError
        readState()
        onChange?()
    }
    func setFnLock(_ value: Int) {
        fnLockError = Asus.set(ControlRequest(what: .fnLock, value: value)) == KERN_SUCCESS ? "" : "FnLock 不可用或请求被拒绝。"
        if fnLockError.isEmpty { JSONSettings.shared.set(value, forKey: "fnlock") }
        message = fnLockError.isEmpty ? "已请求 FnLock：\(value == 1 ? "开启" : "关闭")（非硬件回读）" : fnLockError
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
        lowPowerError = Asus.set(request) == KERN_SUCCESS ? "" : "低电量模式规则不可用或请求被拒绝（需要 ABI 5 模式支持）。"
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
                    if let error { self?.notificationStatus = "通知权限错误：\(error.localizedDescription)" }
                    else { self?.updateNotificationPermission() }
                }
            }
        } else { updateNotificationPermission() }
    }
    func updateNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: String
            switch settings.authorizationStatus {
            case .denied: status = "通知权限被拒绝。请在“系统设置”→“通知”中启用 MyASUS；模式控制仍可使用。"
            case .notDetermined: status = "尚未请求权限。请开启通知以请求访问权限。"
            case .authorized, .provisional: status = "已获得通知权限。"
            @unknown default: status = "通知权限状态未知。"
            }
            Task { @MainActor [weak self] in self?.notificationStatus = status }
        }
    }
    private func deliver(_ notice: PerformanceDropNotice) {
        let content = UNMutableNotificationContent()
        content.title = "电池供电时的性能模式"
        content.body = notice.body
        content.sound = .default
        // UUID also avoids replacing a prior notification after a full counter wrap.
        let request = UNNotificationRequest(identifier: "performance-drop-\(notice.sequence)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.notificationStatus = "通知发送失败：\(error.localizedDescription)" }
        }
    }
    var batteryLine: String {
        guard st.batDesign > 5 else { return "固件未提供电池数据" }
        var s = ""
        if st.batFull > 0 { s += String(format: "健康度 %.0f %%（%d / %d mAh）", 100.0 * Double(st.batFull) / Double(st.batDesign), st.batFull, st.batDesign) }
        if st.batFull > 0, st.batNow > 0 { s += String(format: " · %.0f %%", 100.0 * Double(st.batNow) / Double(st.batFull)) }
        if st.batState & 2 != 0 { s += " · 正在充电 \(st.batRate) mA" } else if st.batState & 1 != 0 { s += " · \(st.batRate) mA" }
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
            if Asus.bind(key: key, action: bindings[key - 1]) != KERN_SUCCESS { bindingsError = "F\(key) 绑定请求被拒绝。" }
        }
    }
    func setBinding(_ key: Int, _ action: FnAction) {
        guard canBind(key) else { return }
        guard Asus.bind(key: key, action: action) == KERN_SUCCESS else { bindingsError = "F\(key) 绑定请求被拒绝。"; return }
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
        fnLockError = Asus.set(ControlRequest(what: .fnHotkeysValue, value: value)) == KERN_SUCCESS ? "" : "固件 Fn 极性设置请求失败。"
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
            message = "已打开相机隐私设置。尚未实现或验证全局硬件相机开关。"
        case .lockScreen, .screenshot:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else {
                message = "此按键操作需要 MyASUS 的辅助功能权限；未发送按键。"
                NSSound.beep(); return
            }
            let code: CGKeyCode = action == .lockScreen ? 0x0c : 0x17 // Control+Command+Q / Shift+Command+5
            let flags: CGEventFlags = action == .lockScreen ? [.maskControl, .maskCommand] : [.maskShift, .maskCommand]
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { message = "无法创建快捷键事件。"; return }
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
                Text("风扇占空比（%）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let point = data.points.first(where: { $0.id == hovered }) {
                    Text("\(point.temperature)°C · \(point.duty)%").font(.caption).monospacedDigit()
                }
            }.frame(height: 16)
            if data.points.isEmpty {
                Text("没有有效的风扇曲线数据。").font(.callout).foregroundStyle(.secondary).frame(height: 100)
            } else {
                Chart(data.points) { point in
                    LineMark(x: .value("温度", point.temperature), y: .value("风扇占空比", point.duty),
                             series: .value("区段", point.segment))
                        .interpolationMethod(.linear).lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("温度", point.temperature), y: .value("风扇占空比", point.duty))
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
                Text("温度（°C）").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            if data.omitted > 0 {
                Text("有 \(data.omitted) 个固件数据点超出有效范围或顺序，未绘制。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("风扇占空比与温度")
        .accessibilityValue(data.points.map { "\($0.temperature) 摄氏度，\($0.duty) 百分比" }.joined(separator: "; "))
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
                Text("\(m.curveMode.title)模式固件曲线").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("风扇", selection: $fan) { Text("CPU").tag(0); Text("GPU").tag(1) }
                    .pickerStyle(.segmented).frame(width: 105).controlSize(.small)
            }
            if let bytes = fan == 0 ? m.curve : m.gpuCurve { CurveChart(c: bytes, compact: compact) }
            else { Text("固件未提供风扇曲线。").font(.caption).foregroundStyle(.secondary) }
            if !compact {
                Text("固件参考数据，并非实时转速。将指针悬停在数据点上可查看温度和占空比。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum RogPage: String, CaseIterable, Identifiable {
    case overview = "Overview", performance = "Performance", battery = "Battery & Display", settings = "Settings"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .performance: return "性能"
        case .battery: return "电池与显示"
        case .settings: return "设置"
        }
    }
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
                RogSection(title: "实时遥测") {
                    HStack(spacing: 16) {
                        Stat(symbol: "thermometer.medium", value: m.tctl.map { String(format: "%.1f°C", $0) } ?? "不可用", label: "CPU 温度")
                        Stat(symbol: "thermometer.medium", value: m.gpuTemperature.map { String(format: "%.1f°C", $0) } ?? "不可用", label: "GPU 温度")
                        Stat(symbol: "fan", value: m.st.reports(.cpuFan) ? "\(m.st.cpuFan)" : "不可用", label: m.st.reports(.gpuFan) ? "CPU 风扇 · RPM" : "系统风扇 · RPM")
                        Stat(symbol: "fan", value: m.st.reports(.gpuFan) ? "\(m.st.gpuFan)" : "不可用", label: "GPU 风扇 · RPM")
                    }
                    Text(m.temperatureSources).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if page == .overview || page == .performance {
                RogSection(title: "性能模式") { modes }
            }
            if page == .overview || page == .settings {
                RogSection(title: "FnLock") { fnLockControls }
            }
            if page == .overview || page == .battery {
                RogSection(title: "电池保养") {
                    VStack(alignment: .leading, spacing: 12) {
                        batteryControls
                        Text("桌面使用 60% · 日常使用 80% · 旅行使用 100%").font(.callout).foregroundStyle(.secondary)
                    }.disabled(!m.st.present)
                }
            }
            if page == .overview {
                RogSection(title: "显卡") { Text(gpuLine).font(.callout).foregroundStyle(.secondary) }
            }
            if page == .settings {
                RogSection(title: "启动") {
                    Toggle("登录时打开", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) })).toggleStyle(.switch)
                    Text("登录后在菜单栏静默运行。关闭窗口后硬件控制仍保持运行。").font(.callout).foregroundStyle(.secondary)
                }
                RogSection(title: "配置文件") {
                    Text(JSONSettings.shared.url.path).font(.caption).textSelection(.enabled)
                    Text("登录时加载。FnLock 默认为未锁定，即直接使用快捷功能。更改以原子方式保存；格式错误的文件会被保留，控制功能将变为只读。外部编辑文件后请重新启动。").font(.caption).foregroundStyle(.secondary)
                    Button("在 Finder 中显示配置文件") { NSWorkspace.shared.selectFile(JSONSettings.shared.url.path, inFileViewerRootedAtPath: "") }
                }
                RogSection(title: "F1–F12 按键绑定") { keyBindingControls }
                RogSection(title: "低电量模式预设") { lowPowerControls }
                RogSection(title: "性能模式通知") {
                    Toggle("性能模式下断开交流电时通知", isOn: Binding(get: { m.notificationsEnabled }, set: { m.setNotifications($0) }))
                    Text(m.notificationStatus).font(.callout).foregroundStyle(.secondary)
                    Button("刷新权限状态") { m.updateNotificationPermission() }
                }
                RogSection(title: "关于 MyASUS") {
                    Text(m.st.machineName).font(.headline)
                    Text("启动和唤醒时只恢复明确保存的期望模式、充电上限和 FnLock 设置。使用电池或电源状态未知时，AsusSMC 会暂时从性能模式回退到平衡模式，接通交流电后恢复性能模式。低电量模式可临时覆盖预设，不会替换原有期望模式。").foregroundStyle(.secondary)
                    Link("由 thanhnndev 创建 · github.com/thanhnndev", destination: URL(string: "https://github.com/thanhnndev")!)
                    Link("灵感来自 asusctl 和 asus-linux 社区", destination: URL(string: "https://asus-linux.org")!)
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
                ChoiceButton(title: "未锁定 · 快捷功能", selected: m.st.fnLockLastRequest == 0) { m.setFnLock(0) }
                ChoiceButton(title: "已锁定 · F1–F12", selected: m.st.fnLockLastRequest == 1) { m.setFnLock(1) }
                Spacer()
            }.disabled(!m.st.supports(.fnLock))
            Text("上次请求：\(m.fnLockLabel) — 非硬件回读。").font(.caption).foregroundStyle(.secondary)
            Text("默认未锁定，F1–F12 直接执行快捷功能。Fn+Esc 始终用于切换，与锁定状态无关。").font(.caption).foregroundStyle(.secondary)
            Toggle("反转固件 Fn 模式（仅用于校准）", isOn: Binding(get: { m.st.hotkeysFirmwareValue == 0 }, set: { m.setFnPolarity($0) })).disabled(!m.st.supports(.fnLock))
            Text("必须在此 BIOS 上验证固件极性。如果实际行为相反，请使用校准选项；配置仍保留逻辑上的未锁定／锁定含义。").font(.caption).foregroundStyle(.secondary)
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
                    Picker("F\(key) 操作", selection: Binding(get: { m.bindings[key - 1] }, set: { m.setBinding(key, $0) })) {
                        ForEach(FnAction.allCases) { action in Text(action.title).tag(action) }
                    }.labelsHidden().disabled(!m.canBind(key))
                    if !m.canBind(key) { Text("需要桥接／捕获").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button("恢复默认绑定") { m.resetBindings() }
            Text("F12 打开此设置面板。Fn+Esc 为保留按键。F7 没有已知事件；F11 需要 macOS 按键捕获才能验证重映射。可选的 EC 查询桥接可启用其他由固件路由的按键，避免重复的 PS/2 操作。").font(.caption).foregroundStyle(.secondary)
            Text("F10 目前打开相机隐私设置，并非经过验证的全局硬件相机开关。锁屏／截图快捷键需要辅助功能权限。应用操作需要应用在后台运行。").font(.caption).foregroundStyle(.secondary)
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
            Toggle("macOS 进入低电量模式时使用风扇预设", isOn: Binding(
                get: { m.lowPowerRule.enabled }, set: { m.setLowPowerRule(enabled: $0) }))
            Picker("低电量模式预设", selection: Binding(
                get: { m.lowPowerRule.mode }, set: { m.setLowPowerRule(mode: $0) })) {
                ForEach(ControlPolicy.visibleModes) { Text($0.title).tag($0) }
            }
            Text("macOS 低电量模式：\(m.macOSLowPowerActive ? "开启" : "关闭")。自动检测需要应用保持后台运行。禁用规则、退出低电量模式或正常退出应用将恢复原有期望模式；使用电池时性能模式仍会回退。")
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
        s += mux == ~0 ? "MUX 状态未知" : (mux & 1 == 0 ? "仅独立显卡（MUX）" : "混合模式")
        if m.st.dgpu != ~0 && m.st.dgpu & 1 != 0 { s += ", 独立显卡已禁用" }
        if m.st.baseTgp > 0 { s += ", 基础 TGP \(m.st.baseTgp) W" }
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
                .accessibilityLabel(mode.title + (selected ? "，已选择" : ""))
                .help(!state.supports(.profile) ? "需要 ABI 5 模式功能" : mode == .performance ? "电池供电时保留性能模式请求；AsusSMC 暂时使用平衡模式，直到恢复交流电供电" : mode.title)
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
        }.buttonStyle(.plain).accessibilityLabel(title + (selected ? "，已启用" : ""))
    }
}

// Draft changes never write EC; only an explicit Apply sends what 5.
struct ChargeLimitControls: View {
    @ObservedObject var m: RogModel
    @State private var draft = 50
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Stepper("充电上限：\(draft)%", value: $draft, in: ControlPolicy.chargeRange, step: 1)
                Button("应用") { m.setCharge(draft) }
            }
            HStack(spacing: 6) {
                ForEach([50, 60, 80, 100], id: \.self) { value in
                    ChoiceButton(title: "\(value)%", selected: draft == value) { draft = value }
                }
                Spacer(minLength: 0)
            }
            Text(m.st.charge.map { "报告的上限：\($0)% · 点击应用以保存更改" } ?? "报告的上限：未知 · 点击应用以保存更改")
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
                Text("MyASUS").font(.system(size: 13, weight: .semibold))
                Spacer()
                Label(m.st.powerLabel,
                      systemImage: m.st.powerKnown && m.st.ac ? "powerplug" : "battery.75")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                quickStat(m.tctl.map { String(format: "%.0f°C", $0) } ?? "–", "CPU")
                quickStat(m.watts.map { String(format: "%.1f W", $0) } ?? "–", "功率")
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
                    Text("电池 \(min(100, max(0, m.st.batNow * 100 / m.st.batFull)))%")
                    Spacer()
                    Text(m.st.batState & 2 != 0 ? "充电中" : !m.st.powerKnown ? "电源状态未知" : m.st.ac ? "交流电供电" : "放电中")
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
                Menu("设置") {
                    Toggle("登录时打开", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) }))
                    Toggle("性能模式通知", isOn: Binding(get: { m.notificationsEnabled }, set: { m.setNotifications($0) }))
                    Text(m.notificationStatus)
                    Button("刷新通知权限") { m.updateNotificationPermission() }
                    Menu("低电量模式预设") {
                        Toggle("启用自动预设", isOn: Binding(get: { m.lowPowerRule.enabled }, set: { m.setLowPowerRule(enabled: $0) }))
                        ForEach(ControlPolicy.visibleModes) { mode in
                            Button((m.lowPowerRule.mode == mode ? "已选择：" : "") + mode.title) { m.setLowPowerRule(mode: mode) }
                        }
                        Text("自动检测需要应用在后台运行。")
                        Text(m.lowPowerError)
                    }.disabled(!m.st.supports(.profile))
                    Text(m.batteryLine)
                    Text(controls.gpuLine)
                    Button("由 thanhnndev 创建（GitHub）") { NSWorkspace.shared.open(URL(string: "https://github.com/thanhnndev")!) }
                    Button("退出 MyASUS") { NSApp.terminate(nil) }
                }.menuStyle(.borderlessButton).fixedSize().font(.caption)
                Spacer()
                Button("打开应用", action: openWindow).buttonStyle(.borderless).font(.caption)
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
                    Text("MyASUS").font(.system(size: 21, weight: .semibold))
                    Text(m.st.machineName).font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.top, 20)
                VStack(spacing: 4) {
                    ForEach(RogPage.allCases) { destination in
                        Button { m.selectedPage = destination } label: {
                            Label(destination.title, systemImage: destination.symbol)
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
                        Text(page.title).font(.system(size: 24, weight: .semibold))
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
            w.title = "MyASUS"
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
        let credits = NSMutableAttributedString(string: "由 thanhnndev 创建\ngithub.com/thanhnndev\n\n灵感来自 asusctl 和 asus-linux 社区。",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.addAttribute(.link, value: URL(string: "https://github.com/thanhnndev")!, range: (credits.string as NSString).range(of: "github.com/thanhnndev"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    func setupMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "关于 MyASUS", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 MyASUS", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 MyASUS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口"); windowItem.submenu = windowMenu
        let open = windowMenu.addItem(withTitle: "打开 MyASUS", action: #selector(showWindow), keyEquivalent: "0"); open.target = self
        let refresh = windowMenu.addItem(withTitle: "刷新", action: #selector(refreshNow), keyEquivalent: "r"); refresh.target = self
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    func updateIcon() {
        guard let b = item.button else { return }
        let ready = model.driverStatus == .ready
        let symbol = ready ? (model.activeMode ?? .balanced).symbol : model.driverStatusSymbol
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: ready ? "MyASUS:\(model.modeLabel)" : "MyASUS：AsusSMC 不可用")
        img?.isTemplate = true
        b.image = img
        var tip = ready ? "MyASUS:\(model.modeLabel)" : "MyASUS：AsusSMC 不可用"
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
    print("ASUS 控制功能已禁用 RogControl --bench；未启动负载测试。")
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
