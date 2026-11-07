// SPDX-License-Identifier: BSD-3-Clause-Clear
import Foundation

enum SMCScalar {
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        guard bytes.count == 2 else { return nil }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        switch type {
        case "sp78": return Double(Int16(bitPattern: raw)) / 256
        case "fpe2": return Double(raw) / 4
        default: return nil // unknown type/endianness must not be guessed
        }
    }
    static func temperature(type: String, bytes: [UInt8]) -> Double? {
        guard let value = decode(type: type, bytes: bytes), value > 0, value <= 150 else { return nil }
        return value
    }
}

#if !ROG_LOGIC_TESTS
import IOKit

// Read-only AppleSMC user client. Commands 9 (metadata) and 5 (read bytes) only; never command 6 (write).
@MainActor
enum NativeSMCTelemetry {
    struct Sample {
        var cpu: Double?, gpu: Double?
        var cpuSource = "不可用——需要可工作的 CPU SMC 传感器（例如 SMCProcessor）"
        var gpuSource = "不可用——没有经过验证的 GPU SMC 温度键"
    }
    private static var connection: io_connect_t = 0
    private static func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }
    private static func call(_ input: [UInt8]) -> [UInt8]? {
        guard input.count == 80, open() else { return nil }
        var output = [UInt8](repeating: 0, count: 80), size = 80
        let result = input.withUnsafeBytes { src in output.withUnsafeMutableBytes { dst in
            IOConnectCallStructMethod(connection, 2, src.baseAddress, 80, dst.baseAddress, &size)
        } }
        guard result == KERN_SUCCESS, size == 80, output[40] == 0 else {
            if result != KERN_SUCCESS { IOServiceClose(connection); connection = 0 }
            return nil
        }
        return output
    }
    private static func put32(_ value: UInt32, _ offset: Int, into bytes: inout [UInt8]) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    private static func get32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func readTemperature(_ key: String) -> Double? {
        let chars = Array(key.utf8)
        guard chars.count == 4 else { return nil }
        let code = chars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // x86_64 SMCKeyData wire layout: key@0, keyInfo@28, result@40, command@42, bytes@48; size 80.
        var input = [UInt8](repeating: 0, count: 80)
        put32(code, 0, into: &input); input[42] = 9
        guard let info = call(input), get32(info, 28) == 2 else { return nil }
        let typeCode = get32(info, 32)
        let type = String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: typeCode >> (24 - $0 * 8)) }, encoding: .ascii) ?? ""
        guard type == "sp78" || type == "fpe2" else { return nil }
        put32(2, 28, into: &input); input[42] = 5
        guard let value = call(input) else { return nil }
        return SMCScalar.temperature(type: type, bytes: Array(value[48..<50]))
    }
    static func sample() -> Sample {
        var result = Sample()
        for key in ["TC0D", "TC0P", "TC0E", "TC0C"] {
            if let value = readTemperature(key) { result.cpu = value; result.cpuSource = "SMC \(key)"; break }
        }
        for key in ["TG0D", "TG0P", "TG1D", "TG1P"] {
            if let value = readTemperature(key) { result.gpu = value; result.gpuSource = "SMC \(key) — GPU 的具体身份取决于传感器提供程序"; break }
        }
        return result
    }
}
#endif
