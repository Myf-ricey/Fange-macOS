// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum LoginItemState {
    case disabled
    case enabled
    case unavailable

    var isEnabled: Bool {
        self == .enabled
    }
}

enum LoginItemError: LocalizedError {
    case homeDirectoryUnavailable

    var errorDescription: String? {
        "无法访问当前用户的登录启动项目录，请检查用户目录权限后再试。"
    }
}

/// Manages a per-user LaunchAgent. This is reliable for locally built and
/// ad-hoc-signed copies of the app, which macOS may decline to register through
/// SMAppService until they have a Developer ID signature.
struct LoginItemManager {
    private let fileManager = FileManager.default
    private let label = "com.ricey.desktop-regions.login"

    var state: LoginItemState {
        guard let launchAgentURL else { return .unavailable }
        return fileManager.fileExists(atPath: launchAgentURL.path) ? .enabled : .disabled
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        guard let launchAgentURL else {
            throw LoginItemError.homeDirectoryUnavailable
        }

        if enabled {
            try fileManager.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let propertyList: [String: Any] = [
                "Label": label,
                "ProgramArguments": [
                    "/usr/bin/open",
                    Bundle.main.bundleURL.standardizedFileURL.path
                ],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua"
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
            try data.write(to: launchAgentURL, options: .atomic)
        } else if fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }

        return state
    }

    /// If the app has been moved, keep the enabled login item pointed at its
    /// current bundle path without changing the user's on/off preference.
    func refreshEnabledItemPath() {
        guard state == .enabled else { return }
        _ = try? setEnabled(true)
    }

    private var launchAgentURL: URL? {
        guard let userLibrary = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return userLibrary
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
    }
}
