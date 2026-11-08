// Foundation-only behavioral tests compiled with the actual production policy.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func fixture(ac: Bool = true, caps: AsusCaps = [.profile, .charge, .fnLock, .hotkeys, .cpuFan]) -> AsusState {
    var words = [UInt32](repeating: 0, count: 36)
    words[0] = 5; words[1] = ac ? 1 : 0
    words[2] = 0; words[3] = UInt32.max
    words[27] = caps.rawValue; words[28] = UInt32.max
    words[29] = 0; words[30] = 0x42; words[31] = 7
    words[32] = 0; words[33] = 10; words[34] = 20; words[35] = 0
    return AsusState.decode(words)
}
func request(_ what: ControlWhat, _ value: Int) -> ControlRequest { ControlRequest(what: what, value: value) }

let suite = "MyASUS.HostTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
let ac = fixture()
let battery = fixture(ac: false)
expect(ac.present && ac.writable, "Only ABI 5 permits capability-gated controls")
expect(ac.machineName == "ASUS 笔记本电脑", "The app must not expose a fixed notebook model")
expect(ac.lastKey == 0x42 && ac.eventSequence == 7, "The old prefix indexes must not move")
expect(ac.desiredProfile == 0 && ac.powerTransitionSequence == 10 && ac.performanceDropSequence == 20 && ac.lastProfileError == 0,
       "ABI 5 tail must decode words 32 through 35")
expect(ac.fnLockLastRequest == nil && ac.charge == nil, "Unknown values must remain unknown")
expect(!ac.supports(.manual) && !ac.supports(.keyboard) && !ac.supports(.slash) && !ac.supports(.referenceSensors),
       "Unsupported controls and AMD reference sensors must not be exposed")
expect(ControlPolicy.restore(state: ac, defaults: defaults).isEmpty, "First startup must not invent settings")
expect(ControlPolicy.restore(state: battery, defaults: defaults, reason: .wake).isEmpty, "Wake must not invent settings")
expect(DesiredSettings.load(defaults: defaults) == nil && defaults.object(forKey: "desired.mode") == nil,
       "Unknown desired must not be adopted from actual readback")
expect(ControlPolicy.visibleModes == [.balanced, .performance, .silent], "Only the three normalized presets are visible")
expect(Mode.balanced.title == "平衡" && Mode.performance.title == "性能" && Mode.silent.title == "静音",
       "Mode titles must use the Chinese UI terminology")
expect(Mode.balanced.rawValue == "balanced" && Mode.performance.rawValue == "performance" && Mode.silent.rawValue == "silent",
       "Localized titles must not change persisted mode raw values")
expect(Mode.balanced.firmwareProfile == 0 && Mode.performance.firmwareProfile == 1 && Mode.silent.firmwareProfile == 2,
       "Frontend must use normalized, not firmware-specific values")
for state in [ac, battery] {
    for mode in ControlPolicy.visibleModes {
        expect(ControlPolicy.canChoose(mode, state: state), "All desired presets must be selectable on either source")
        expect(ControlPolicy.allows(request(.profile, mode.firmwareProfile), state: state), "Write policy must accept desired on battery")
    }
    for value in 50...100 {
        expect(ControlPolicy.allows(request(.charge, value), state: state), "Every integer 50...100 must be valid")
    }
    for value in [-1, 0, 20, 49, 101] {
        expect(!ControlPolicy.allows(request(.charge, value), state: state), "Charge bounds must be enforced at write boundary")
    }
    expect(ControlPolicy.allows(request(.fnLock, 0), state: state) && ControlPolicy.allows(request(.fnLock, 1), state: state),
           "Unknown readback must still permit FnLock Off/On")
    expect(!ControlPolicy.allows(request(.fnLock, -1), state: state) && !ControlPolicy.allows(request(.fnLock, 2), state: state),
           "FnLock must be boolean")
    expect(!ControlPolicy.allows(request(.profile, -1), state: state) && !ControlPolicy.allows(request(.profile, 3), state: state),
           "Profile must be normalized 0...2")
}

// Ordinary intent is source-independent; driver-owned fallback never rewrites it.
DesiredSettings.save(.performance, defaults: defaults)
expect(ControlPolicy.restore(state: battery, defaults: defaults) == [request(.profile, 1)],
       "Offline selection/startup must send desired Performance, not fallback Balanced")
expect(ControlPolicy.restore(state: ac, defaults: defaults, reason: .wake) == [request(.profile, 1)],
       "Online wake must retain the exact same intent")
for state in [ac, battery] {
    expect(ControlPolicy.restore(state: state, defaults: defaults, reason: .powerChange).isEmpty,
           "Power changes must not replay any setting; AsusSMC reconciles actual")
}
var deferred = battery
deferred.desiredProfile = 1; deferred.profile = 0; deferred.profileDeferred = true
expect(deferred.selectedMode == .performance && deferred.actualLabel == "平衡", "Selection and actual must remain independent")
expect(deferred.profileStatus.contains("暂时运行平衡模式") && deferred.profileStatus.contains("接通交流电后自动恢复"),
       "Battery Performance must explain temporary Balanced and AC recovery")
expect(DesiredSettings.load(defaults: defaults) == .performance, "Fallback must never replace saved desired")
var online = deferred
online.ac = true; online.profileDeferred = false; online.profile = 1
expect(online.selectedMode == .performance && online.actualLabel == "性能", "AC restores actual without changing desired")
var unknownPower = deferred
unknownPower.powerKnown = false
expect(ControlPolicy.canChoose(.performance, state: unknownPower) && unknownPower.powerLabel == "电源状态未知",
       "Unknown power still allows intent but must not be described as known battery")
deferred.lastProfileError = 0xe00002bc
expect(deferred.profileStatus.contains("失败") && !deferred.profileStatus.contains("暂时运行平衡模式"),
       "An error must not claim a successful fallback, even with stale actual Balanced")
deferred.lastProfileError = 0; deferred.profile = nil
expect(deferred.profileStatus.contains("未确认"), "Unknown actual must not claim Balanced success")

// Only migrate explicit legacy values, with their old meanings. Never migrate Manual.
defaults.removePersistentDomain(forName: suite)
defaults.set("turbo", forKey: "ac.mode"); defaults.set("silent", forKey: "battery.mode")
expect(DesiredSettings.load(defaults: defaults) == .performance, "Explicit AC Enhanced has migration priority")
expect(defaults.string(forKey: "desired.mode") == "performance" && defaults.object(forKey: "ac.mode") == nil && defaults.object(forKey: "battery.mode") == nil,
       "Migration leaves only one desired intent")
defaults.removePersistentDomain(forName: suite)
defaults.set("performance", forKey: "battery.mode")
expect(DesiredSettings.load(defaults: defaults) == .balanced, "Legacy Standard must migrate to Balanced, not new Performance")
defaults.removePersistentDomain(forName: suite)
defaults.set("manual", forKey: "ac.mode"); defaults.set("silent", forKey: "battery.mode")
expect(DesiredSettings.load(defaults: defaults) == .silent, "Invalid AC preference must allow explicit battery migration")
defaults.removePersistentDomain(forName: suite)
defaults.set("manual", forKey: "ac.mode")
expect(ControlPolicy.restore(state: ac, defaults: defaults).isEmpty, "Legacy Manual must not become a default write")
defaults.set("invalid", forKey: "desired.mode"); defaults.set("turbo", forKey: "ac.mode")
expect(DesiredSettings.load(defaults: defaults) == nil, "An invalid explicit new key must fail closed rather than revive old preferences")

// Independently saved charge/FnLock, capabilities and legacy read-only behavior.
defaults.removePersistentDomain(forName: suite)
defaults.set(50, forKey: "charge")
expect(ControlPolicy.restore(state: ac, defaults: defaults) == [request(.charge, 50)], "Saved minimum must not invent a profile")
defaults.set(100, forKey: "charge"); defaults.set(1, forKey: "fnlock")
expect(ControlPolicy.restore(state: ac, defaults: defaults) == [request(.charge, 100), request(.fnLock, 1)], "Saved maximum and explicit FnLock restore")
for value in [49, 101] {
    defaults.set(value, forKey: "charge")
    expect(!ControlPolicy.restore(state: ac, defaults: defaults).contains { $0.what == .charge }, "Invalid saved charge must not write")
}
defaults.set(50.5, forKey: "charge")
expect(!ControlPolicy.restore(state: ac, defaults: defaults).contains { $0.what == .charge }, "Fractional preferences must not be truncated into EC writes")
defaults.set(80, forKey: "charge"); DesiredSettings.save(.silent, defaults: defaults)
let unsupported = fixture(caps: [])
expect(ControlPolicy.restore(state: unsupported, defaults: defaults, lowPowerActive: true).isEmpty, "No capabilities means no writes, including low-power config")
for req in [request(.profile, 0), request(.charge, 80), request(.fnLock, 1), request(.lowPowerConfig, 0)] {
    expect(!ControlPolicy.allows(req, state: unsupported), "Capability checks must also reject direct writes")
}
expect(ControlPolicy.visibleModes.allSatisfy { !ControlPolicy.canChoose($0, state: unsupported) }, "Missing profile cap disables choices")
expect(unsupported.machineName == "ASUS 笔记本电脑", "Missing profile cap keeps generic identity")
expect(ControlPolicy.restore(state: fixture(caps: [.charge]), defaults: defaults, lowPowerActive: true) == [request(.charge, 80)], "Charge-only cap never writes profile or rule")
expect(ControlPolicy.restore(state: fixture(caps: [.fnLock]), defaults: defaults) == [request(.fnLock, 1)], "FnLock-only cap restores only FnLock")
expect(ControlPolicy.restore(state: fixture(caps: [.profile]), defaults: defaults) == [request(.profile, 2)], "Profile-only cap restores only desired")
for (version, count) in [(UInt32(1), 18), (UInt32(2), 24), (UInt32(3), 27), (UInt32(4), 32)] {
    var words = [UInt32](repeating: 0, count: count)
    words[0] = version; words[1] = 1; words[2] = 2; words[3] = 80
    if version == 4 { words[27] = ac.caps.rawValue; words[28] = 1 }
    let legacy = AsusState.decode(words)
    expect(legacy.present && legacy.profile == 2 && legacy.charge == 80 && legacy.selectedMode == .silent, "Old ABIs remain displayable")
    expect(!legacy.writable && !legacy.supports(.profile), "Even ABI 4 capabilities cannot enable writes")
    expect(ControlPolicy.restore(state: legacy, defaults: defaults, lowPowerActive: true).isEmpty, "Legacy ABI cannot replay any setting")
    for req in [request(.profile, 0), request(.charge, 80), request(.fnLock, 1), request(.lowPowerConfig, 0)] {
        expect(!ControlPolicy.allows(req, state: legacy), "All legacy ABI writes must be blocked")
    }
    expect(!AsusState.decode(Array(words.dropLast())).present, "Truncated legacy replies must be rejected")
}
var words = [UInt32](repeating: 0, count: 36)
words[0] = 5; words[1] = 2 | 4 | 8 | 16; words[2] = UInt32.max; words[32] = UInt32.max
words[6] = 0x203; words[27] = ac.caps.rawValue; words[28] = 1; words[35] = 0xe00002bc
let decoded = AsusState.decode(words)
expect(decoded.fanCustom && decoded.profileDeferred && !decoded.powerKnown && decoded.lowPowerOverrideActive,
       "New flags must not move the existing fan/AC bits")
expect(decoded.profile == nil && decoded.desiredProfile == nil && decoded.fnLockLastRequest == 1 && decoded.lastProfileError == 0xe00002bc,
       "Unknown normalized profiles, known FnLock and raw IOReturn must decode")
expect(decoded.lowPowerConfig == 0x203 && decoded.effectiveProfile == 2, "Word 6 is the independent low-power rule")
expect(!AsusState.decode(Array(words.prefix(35))).present, "ABI 5 needs all 36 words")
words[28] = 2
expect(AsusState.decode(words).fnLockLastRequest == nil, "Invalid FnLock remains unknown")
words[0] = 6
expect(!AsusState.decode(words).present, "Unknown ABI fails closed")
expect(ControlWhat.profile.rawValue == 1 && ControlWhat.charge.rawValue == 5 && ControlWhat.fnLock.rawValue == 9 && ControlWhat.lowPowerConfig.rawValue == 10,
       "SET operation numbers must match the contract")

// Physical events save desired, never a driver's automatic actual fallback.
defaults.removePersistentDomain(forName: suite)
var events = DriverEventPolicy()
var eventState = battery
eventState.lastKey = 0x4e; eventState.eventSequence = 10; eventState.fnLockLastRequest = 1
events.observe(state: eventState, defaults: defaults)
expect(defaults.object(forKey: "fnlock") == nil, "First event sample is only a baseline")
defaults.set(0, forKey: "fnlock")
events.observe(state: eventState, defaults: defaults)
expect(defaults.integer(forKey: "fnlock") == 0, "Unchanged sequence must not adopt readback")
eventState.eventSequence = 11
events.observe(state: eventState, defaults: defaults)
expect(defaults.integer(forKey: "fnlock") == 1, "New Fn+Esc persists last request")
expect(events.restore(state: eventState, defaults: defaults).isEmpty, "Observed Fn+Esc must not generate duplicate SET")
expect(events.restore(state: eventState, defaults: defaults) == [request(.fnLock, 1)], "Later lifecycle restores the explicit FnLock")
eventState.eventSequence = 12; eventState.fnLockLastRequest = nil
events.observe(state: eventState, defaults: defaults)
expect(defaults.integer(forKey: "fnlock") == 1, "Unknown FnLock event must not erase saved request")
eventState.fnLockLastRequest = 0
events.observe(state: eventState, defaults: defaults)
expect(defaults.integer(forKey: "fnlock") == 1, "Readback without a new event must not overwrite FnLock")
eventState.eventSequence = 13; eventState.lastKey = 0x9d; eventState.desiredProfile = 1; eventState.profile = 0
events.observe(state: eventState, defaults: defaults)
expect(DesiredSettings.load(defaults: defaults) == .performance, "Battery physical mode event must save word32 Performance, not word2 Balanced")
expect(!events.restore(state: eventState, defaults: defaults, reason: .wake).contains { $0.what == .profile }, "Physical profile event must not cause duplicate SET")
eventState.ac = true; eventState.profile = 1
events.observe(state: eventState, defaults: defaults)
expect(DesiredSettings.load(defaults: defaults) == .performance, "Automatic online reconciliation cannot replace desired")
eventState.eventSequence = 14; eventState.lastKey = 0xae; eventState.desiredProfile = 2; eventState.profile = 0
let wakeRequests = events.restore(state: eventState, defaults: defaults, reason: .wake)
expect(DesiredSettings.load(defaults: defaults) == .silent && !wakeRequests.contains { $0.what == .profile }, "Wake observes unseen desired event before restoring")
eventState.eventSequence = 15; eventState.desiredProfile = nil
events.observe(state: eventState, defaults: defaults)
expect(DesiredSettings.load(defaults: defaults) == .silent, "Unknown desired event cannot save actual")
eventState.eventSequence = 16; eventState.lastKey = 0x42; eventState.desiredProfile = 0
events.observe(state: eventState, defaults: defaults)
expect(DesiredSettings.load(defaults: defaults) == .silent, "Unrelated keys cannot change desired")
eventState.eventSequence = 17; eventState.lastKey = 0x4e; eventState.caps = [.profile, .fnLock]
events.observe(state: eventState, defaults: defaults)
expect(defaults.integer(forKey: "fnlock") == 1, "Without hotkey cap no event changes preferences")
var wrappedEvents = DriverEventPolicy()
eventState = ac; eventState.lastKey = 0x4e; eventState.fnLockLastRequest = 0; eventState.eventSequence = UInt32.max
wrappedEvents.observe(state: eventState, defaults: defaults)
eventState.eventSequence = 0; eventState.fnLockLastRequest = 1
expect(!wrappedEvents.restore(state: eventState, defaults: defaults).contains { $0.what == .fnLock }, "Wrapped event counter is a new action without duplicate SET")

// Notification counters: initial battery/old events, dedup, wrap and rapid unplug/replug.
var drops = PerformanceDropPolicy()
var dropState = battery
dropState.desiredProfile = 1; dropState.profile = 0; dropState.profileDeferred = true
expect(drops.observe(state: dropState) == nil, "First battery sample never delivers historical notifications")
expect(drops.observe(state: dropState) == nil, "Unchanged drop counter must deduplicate")
dropState.powerTransitionSequence &+= 1
expect(drops.observe(state: dropState) == nil, "Power transitions alone never notify")
dropState.performanceDropSequence &+= 1
let notice = drops.observe(state: dropState)
expect(notice?.body.contains("暂时运行平衡模式") == true && notice?.body.contains("接通交流电后自动恢复") == true, "New drop reports successful temporary fallback")
expect(drops.observe(state: dropState) == nil, "A delivered counter must not deliver twice")
dropState.ac = true; dropState.profile = 1; dropState.profileDeferred = false; dropState.performanceDropSequence &+= 2
expect(drops.observe(state: dropState)?.body.contains("已在接通交流电后恢复") == true, "Counter delta must catch quick cycles even if AC snapshot never changed")
dropState.ac = false; dropState.profile = 0; dropState.lastProfileError = 0xe00002bc; dropState.performanceDropSequence &+= 1
let failedNotice = drops.observe(state: dropState)
expect(failedNotice?.body.contains("未确认") == true && failedNotice?.body.contains("暂时运行平衡模式") == false,
       "Failed reconciliation notice must distinguish request from actual success")
dropState.lastProfileError = 0; dropState.profile = nil; dropState.performanceDropSequence &+= 1
expect(drops.observe(state: dropState)?.body.contains("实际模式尚未确认") == true, "Unknown actual must not imply success")
expect(drops.observe(state: AsusState()) == nil, "Transient read failure never notifies or forgets baseline")
dropState.performanceDropSequence &+= 1
expect(drops.observe(state: dropState) != nil, "Counter changes across read failure must still be observed")
var wrappedDrops = PerformanceDropPolicy()
dropState.performanceDropSequence = UInt32.max
expect(wrappedDrops.observe(state: dropState) == nil, "Initial max counter remains baseline")
dropState.performanceDropSequence = 0
expect(wrappedDrops.observe(state: dropState) != nil && wrappedDrops.observe(state: dropState) == nil, "UInt32 wrap is one new notification, then deduplicated")

// Low Power Mode is a temporary independent target, never ordinary desired.
defaults.removePersistentDomain(forName: suite)
let offRule = LowPowerRule.load(defaults: defaults)
expect(!offRule.enabled && offRule.mode == .balanced, "Low-power rule defaults off")
expect(ControlPolicy.restore(state: ac, defaults: defaults, lowPowerActive: true) == [request(.lowPowerConfig, 2)],
       "Initial low-power sync may clear a stale override, but must never invent a default profile")
expect(defaults.object(forKey: "desired.mode") == nil, "Low-power defaults must not save ordinary desired")
for mode in ControlPolicy.visibleModes {
    for enabled in [false, true] {
        for active in [false, true] {
            let rule = LowPowerRule(enabled: enabled, mode: mode)
            let packed = rule.packed(active: active)
            expect(LowPowerRule.valid(packed) && ControlPolicy.allows(request(.lowPowerConfig, packed), state: battery), "All legal rule configs allowed even on battery")
            var state = battery
            state.desiredProfile = 2; state.lowPowerConfig = UInt32(packed)
            expect(state.effectiveProfile == (enabled && active ? mode.firmwareProfile : 2), "Rule target has priority only while both enabled and active")
        }
    }
}
for invalid in [-1, 4, 0x10, 0x300, 0x303, 0x400, 0x10000] {
    expect(!LowPowerRule.valid(invalid) && !ControlPolicy.allows(request(.lowPowerConfig, invalid), state: ac), "Reserved bits and profile 3 must be rejected")
}
DesiredSettings.save(.silent, defaults: defaults)
let onRule = LowPowerRule(enabled: true, mode: .performance)
onRule.save(defaults: defaults)
expect(LowPowerRule.load(defaults: defaults) == onRule && DesiredSettings.load(defaults: defaults) == .silent, "Rule persistence cannot overwrite ordinary desired")
let ordered = ControlPolicy.restore(state: battery, defaults: defaults, reason: .wake, lowPowerActive: true)
expect(ordered == [request(.lowPowerConfig, 0x103), request(.profile, 2)], "Startup/wake must set rule before ordinary desired")
var overrideState = battery
overrideState.desiredProfile = 2; overrideState.lowPowerConfig = 0x103; overrideState.lowPowerOverrideActive = true
overrideState.profile = 0; overrideState.profileDeferred = true
expect(overrideState.effectiveProfile == 1 && overrideState.selectedMode == .silent && overrideState.actualLabel == "平衡", "Performance override on battery preserves ordinary Silent while actual is Balanced")
expect(overrideState.profileStatus.contains("低电量模式预设已启用") && overrideState.profileStatus.contains("性能") && overrideState.profileStatus.contains("暂时运行平衡模式"), "UI must explain override and fallback")
overrideState.ac = true; overrideState.profile = 1; overrideState.profileDeferred = false
expect(overrideState.effectiveProfile == 1 && overrideState.selectedMode == .silent, "AC can restore override Performance without changing ordinary desired")
overrideState.lowPowerConfig = UInt32(onRule.packed(active: false)); overrideState.lowPowerOverrideActive = false
expect(overrideState.effectiveProfile == 2 && DesiredSettings.load(defaults: defaults) == .silent, "Leaving Low Power Mode or normal app exit restores ordinary desired")
overrideState.lowPowerConfig = UInt32(LowPowerRule(enabled: false, mode: .performance).packed(active: true))
expect(overrideState.effectiveProfile == 2, "Disabling rule while low power remains active restores ordinary desired")
var overrideDrops = PerformanceDropPolicy()
overrideState.lowPowerConfig = 0x103; overrideState.lowPowerOverrideActive = true; overrideState.ac = false; overrideState.profile = 0
expect(overrideDrops.observe(state: overrideState) == nil, "First override sample must not notify")
overrideState.performanceDropSequence &+= 1
expect(overrideDrops.observe(state: overrideState)?.body.contains("低电量模式预设已启用") == true, "Notifications must identify effective override rather than overwrite ordinary desired")
expect(ControlPolicy.restore(state: battery, defaults: defaults, reason: .powerChange, lowPowerActive: true).isEmpty,
       "Power-change path must not replay lowpower config or desired")
defaults.removePersistentDomain(forName: suite)
print("MyASUS Foundation behavior tests passed")
