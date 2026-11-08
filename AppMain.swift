// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
import AppKit

#if !MYASUS_LOGIC_TESTS
@main
struct MyASUSMain {
    @MainActor
    static func main() {
        // Refuse before opening a driver connection, changing profiles or starting load threads.
        if CommandLine.arguments.dropFirst().contains("--bench") {
            print("ASUS 控制功能已禁用 MyASUS --bench；未启动负载测试。")
            exit(1)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
