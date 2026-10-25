// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

if let index = CommandLine.arguments.firstIndex(of: "--install-update"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(UpdateInstaller.runHelper(manifestPath: CommandLine.arguments[index + 1]))
}

let instanceCoordinator = AppInstanceCoordinator()
guard instanceCoordinator.claimPrimaryInstance() else {
    instanceCoordinator.activatePrimaryInstance()
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Activity Monitor and launch agents may request exit with SIGTERM rather
// than an AppKit Quit event. Route it through the same file-restoration path.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler { application.terminate(nil) }
terminationSource.resume()
withExtendedLifetime((instanceCoordinator, terminationSource)) {
    application.run()
}
