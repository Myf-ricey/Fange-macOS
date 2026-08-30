// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

/// Owns an advisory process lock for one running copy of the app. The lock is
/// released automatically by the kernel if the process crashes or is killed,
/// so an old lock file cannot permanently block future launches.
final class AppInstanceLock {
    private let lockURL: URL
    private var fileDescriptor: Int32 = -1

    init(lockURL: URL) {
        self.lockURL = lockURL
    }

    convenience init(bundleIdentifier: String) {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(bundleIdentifier)-\(getuid()).lock")
        self.init(lockURL: lockURL)
    }

    @discardableResult
    func acquire() -> Bool {
        if fileDescriptor >= 0 { return true }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }

        fileDescriptor = descriptor
        return true
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}

final class AppInstanceCoordinator {
    static let bundleIdentifier = "com.ricey.desktop-regions"
    static let activationNotification = Notification.Name(
        "com.ricey.desktop-regions.activate-existing-instance"
    )

    private let instanceLock: AppInstanceLock
    private let bundleIdentifier: String

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? AppInstanceCoordinator.bundleIdentifier,
        lockURL: URL? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        instanceLock = lockURL.map(AppInstanceLock.init(lockURL:))
            ?? AppInstanceLock(bundleIdentifier: bundleIdentifier)
    }

    func claimPrimaryInstance() -> Bool {
        instanceLock.acquire()
    }

    func activatePrimaryInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.activationNotification,
            object: bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )

        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })?
            .activate(options: [])
    }
}
