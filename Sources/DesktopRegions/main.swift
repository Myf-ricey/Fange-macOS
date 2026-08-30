// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

let instanceCoordinator = AppInstanceCoordinator()
guard instanceCoordinator.claimPrimaryInstance() else {
    instanceCoordinator.activatePrimaryInstance()
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
withExtendedLifetime(instanceCoordinator) {
    application.run()
}
