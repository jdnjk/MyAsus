// SPDX-License-Identifier: BSD-3-Clause-Clear
import Foundation
import CoreFoundation

protocol SettingsStorage {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}
extension UserDefaults: SettingsStorage {}

enum FnAction: Int, CaseIterable, Identifiable {
    case none = 0, mute, volumeDown, volumeUp, brightnessDown, brightnessUp, touchpad,
         displays, lockScreen, cameraPrivacy, screenshot, settings, nextProfile, balanced, performance, silent
    var id: Int { rawValue }
    var title: String {
        ["No action", "Mute", "Volume −", "Volume +", "Brightness −", "Brightness +", "Toggle touchpad",
         "Display settings", "Lock screen", "Camera privacy settings", "Screenshot toolbar", "Open this app's settings",
         "Next fan preset", "Balanced", "Performance", "Silent"][rawValue]
    }
    static let defaults: [FnAction] = [.mute, .volumeDown, .volumeUp, .brightnessDown, .brightnessUp, .touchpad,
                                       .none, .displays, .lockScreen, .cameraPrivacy, .screenshot, .settings]
    static let original = ["Mute", "Volume −", "Volume +", "Brightness −", "Brightness +", "Touchpad", "Unassigned",
                           "Windows projection", "Windows lock", "Camera on/off", "Windows screenshot", "ASUS center"]
    static func functionKey(event: UInt32) -> Int? {
        if (0xf101...0xf10c).contains(event) { return Int(event - 0xf100) }
        return [UInt32(0x32): 1, 0x31: 2, 0x30: 3, 0x6b: 6, 0x33: 9, 0x35: 9, 0x85: 10, 0x86: 12][event]
    }
    static func load(key: Int, defaults: SettingsStorage = JSONSettings.shared) -> FnAction {
        guard (1...12).contains(key) else { return .none }
        return (defaults.object(forKey: "key.F\(key)") as? NSNumber).flatMap { FnAction(rawValue: $0.intValue) } ?? Self.defaults[key - 1]
    }
}

// Human-readable, versioned configuration. Invalid files are preserved and make controls read-only.
final class JSONSettings: SettingsStorage {
    static let shared = JSONSettings(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ASUSControl/config.json"), legacy: .standard)
    let url: URL
    private var values: [String: Any] = [:]
    private(set) var error: String?
    var isWritable: Bool { error == nil }
    enum Failure: Error { case invalid(String) }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded() == n.doubleValue, (-1_000_000...1_000_000).contains(n.doubleValue) else { return nil }
        return n.intValue
    }
    static func defaultValues() -> [String: Any] {
        var result: [String: Any] = ["fnlock": 0, "fn.hotkeysFirmwareValue": 1,
                                    "lowpower.enabled": false, "lowpower.mode": "silent",
                                    "performance.notifications": false, "openAtLogin": true]
        for key in 1...12 { result["key.F\(key)"] = FnAction.defaults[key - 1].rawValue }
        return result
    }
    static func validate(_ settings: [String: Any]) throws {
        for (key, value) in settings {
            let valid: Bool
            switch key {
            case "desired.mode", "lowpower.mode": valid = ["balanced", "performance", "silent"].contains(value as? String ?? "")
            case "charge": valid = integer(value).map { (50...100).contains($0) } ?? false
            case "fnlock", "fn.hotkeysFirmwareValue": valid = integer(value).map { (0...1).contains($0) } ?? false
            case "lowpower.enabled", "performance.notifications", "openAtLogin":
                valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            default:
                if key.hasPrefix("key.F"), let index = Int(key.dropFirst(5)), (1...12).contains(index) {
                    valid = integer(value).flatMap(FnAction.init(rawValue:)) != nil
                } else { valid = false }
            }
            if !valid { throw Failure.invalid("Invalid configuration setting: \(key)") }
        }
    }
    init(url: URL, legacy: UserDefaults? = nil) {
        self.url = url
        do {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.invalid("Configuration symlinks are not supported") }
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count <= 262144,
                      let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(document.keys) == Set(["schemaVersion", "settings"]),
                      Self.integer(document["schemaVersion"]) == 1,
                      let settings = document["settings"] as? [String: Any] else { throw Failure.invalid("Invalid config.json schema") }
                try Self.validate(settings)
                values = Self.defaultValues().merging(settings) { _, explicit in explicit }
            } else {
                values = Self.defaultValues()
                if let legacy {
                    for key in ["charge", "lowpower.enabled", "lowpower.mode", "performance.notifications"] {
                        if let value = legacy.object(forKey: key), (try? Self.validate([key: value])) != nil { values[key] = value }
                    }
                    if let raw = legacy.string(forKey: "desired.mode"), ["balanced", "performance", "silent"].contains(raw) {
                        values["desired.mode"] = raw
                    } else {
                        for key in ["ac.mode", "battery.mode"] {
                            if let old = legacy.string(forKey: key), let mode = ["performance": "balanced", "turbo": "performance", "silent": "silent"][old] {
                                values["desired.mode"] = mode; break
                            }
                        }
                    }
                    // Earlier local drafts stored the firmware-style Fn mode, not the user's logical lock.
                    if let old = Self.integer(legacy.object(forKey: "fnlock")), (0...1).contains(old) { values["fnlock"] = 1 - old }
                }
                try persist(values)
            }
        } catch { self.error = "Configuration not loaded; hardware writes disabled. \(error). File preserved: \(url.path)" }
    }
    private func persist(_ candidate: [String: Any]) throws {
        try Self.validate(candidate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "settings": candidate], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard isWritable else { return }
        var candidate = values
        if let value { candidate[key] = value } else { candidate.removeValue(forKey: key) }
        do { try persist(candidate); values = candidate } catch { self.error = "Configuration save failed; controls disabled: \(error)" }
    }
    func removeObject(forKey key: String) {
        guard values[key] != nil else { return }
        set(nil, forKey: key)
    }
}

struct KeyUIEvent: Equatable { let sequence: UInt32; let key: Int; let action: FnAction }
struct KeyUIQueue {
    var cursor: UInt32?
    mutating func decode(_ words: [UInt32]) -> [KeyUIEvent]? {
        guard words.count >= 2, words[1] <= 64, words.count == 2 + Int(words[1]) * 4 else { return nil }
        guard let after = cursor else { cursor = words[0]; return [] }
        var result: [KeyUIEvent] = []
        var previous = after
        for i in 0..<Int(words[1]) {
            let offset = 2 + i * 4, seq = words[offset]
            guard Int32(bitPattern: seq &- previous) > 0, (1...12).contains(words[offset + 1]),
                  let action = FnAction(rawValue: Int(words[offset + 2])), (7...11).contains(action.rawValue), words[offset + 3] == 0 else { return nil }
            result.append(KeyUIEvent(sequence: seq, key: Int(words[offset + 1]), action: action)); previous = seq
        }
        guard result.isEmpty || previous == words[0] else { return nil }
        cursor = words[0]
        return result
    }
}
