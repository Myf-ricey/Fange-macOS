// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Foundation

@main
struct AppInstanceLockProbe {
    static func main() {
        guard CommandLine.arguments.count == 3,
              let holdMilliseconds = UInt32(CommandLine.arguments[2])
        else {
            fputs("usage: AppInstanceLockProbe <lock-path> <hold-ms>\n", stderr)
            exit(64)
        }

        let lockURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let instanceLock = AppInstanceLock(lockURL: lockURL)
        guard instanceLock.acquire() else {
            print("BUSY")
            exit(23)
        }

        print("ACQUIRED")
        fflush(stdout)
        usleep(holdMilliseconds * 1_000)
    }
}
