// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin
import MachO

struct UpdateInstallRequest: Codable {
    let targetPath: String
    let stagedPath: String
    let backupPath: String
    let workspacePath: String
    let releaseTag: String
    let parentPID: Int32
    let requiredTeam: String?
}

struct UpdateInstallationResult: Codable {
    let success: Bool
    let message: String
}

enum UpdateInstaller {
    static let bundleIdentifier = "com.ricey.desktop-regions"

    static func makeWorkspace() throws -> URL {
        let parent = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DesktopRegions/Updates", isDirectory: true)
        let workspace = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        return workspace
    }

    /// ZIP central-directory preflight precedes extraction. This app's native
    /// bundle contains no symlinks; reject link/traversal payloads outright.
    static func validateArchive(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ i: Int) -> Int { Int(data[i]) | (Int(data[i + 1]) << 8) }
        func u32(_ i: Int) -> Int { u16(i) | (u16(i + 2) << 16) }
        guard data.count >= 22 else { throw UpdatePolicy.error("安装包不是完整的 ZIP 文件。") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if u32(i) == 0x06054b50, i + 22 + u16(i + 20) == data.count { end = i; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10),
              u16(end + 10) > 0, u16(end + 10) < 65_535 else { throw UpdatePolicy.error("不支持此安装包格式，请前往 GitHub 安装。") }
        let count = u16(end + 10)
        let centralEnd = u32(end + 16) + u32(end + 12)
        var cursor = u32(end + 16), expanded: Int64 = 0
        guard cursor >= 0, centralEnd <= end else { throw UpdatePolicy.error("ZIP 目录损坏。") }
        for _ in 0..<count {
            guard cursor + 46 <= centralEnd, u32(cursor) == 0x02014b50 else { throw UpdatePolicy.error("ZIP 目录损坏。") }
            let length = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32)
            let next = cursor + 46 + length + extra + comment
            guard next <= centralEnd, u16(cursor + 8) & 1 == 0,
                  let name = String(data: data[(cursor + 46)..<(cursor + 46 + length)], encoding: .utf8),
                  !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/").contains(".."),
                  ((u32(cursor + 38) >> 16) & 0o170000) != 0o120000 else {
                throw UpdatePolicy.error("安装包包含不安全的路径、链接或加密项目，已停止安装。")
            }
            let local = u32(cursor + 42)
            guard local + 30 <= data.count, u32(local) == 0x04034b50,
                  u16(local + 26) == length, local + 30 + length <= data.count,
                  data[(local + 30)..<(local + 30 + length)] == data[(cursor + 46)..<(cursor + 46 + length)] else {
                throw UpdatePolicy.error("ZIP 文件路径信息不一致。")
            }
            expanded += Int64(u32(cursor + 24))
            guard expanded <= 2 * 1024 * 1024 * 1024 else { throw UpdatePolicy.error("安装包解压后过大。") }
            cursor = next
        }
        guard cursor == centralEnd else { throw UpdatePolicy.error("ZIP 目录记录不完整。") }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdatePolicy.error("\(URL(fileURLWithPath: executable).lastPathComponent) 失败：\(text.prefix(1200))")
        }
        return text
    }

    static func signingTeam(of app: URL) -> String? {
        guard let text = try? run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path]),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let value = String(line.dropFirst("TeamIdentifier=".count))
        return value == "not set" ? nil : value
    }

    static func verifyApplication(_ app: URL, releaseTag: String, requiredTeam: String?) throws {
        let fm = FileManager.default
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard app.pathExtension == "app", values.isDirectory == true, values.isSymbolicLink != true,
              let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let parsed = UpdateVersion(version), let expected = UpdateVersion(releaseTag),
              parsed.baseDescription == expected.baseDescription,
              let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path),
              executable.standardizedFileURL.path.hasPrefix(app.standardizedFileURL.path + "/Contents/MacOS/") else {
            throw UpdatePolicy.error("安装包中的应用身份或版本不符合本次更新，已停止安装。")
        }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
           let required = UpdateVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = UpdateVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!
            guard current >= required else { throw UpdatePolicy.error("新版本需要 macOS \(minimum) 或更高版本。") }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // Foundation reads Mach-O architectures without requiring Xcode or
        // Command Line Tools on the user's Mac.
        let architecture = UpdatePolicy.nativeArchitecture == "arm64" ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
        guard bundle.executableArchitectures?.contains(where: { $0.int32Value == architecture }) == true else {
            throw UpdatePolicy.error("此安装包不支持这台 Mac 的处理器架构。")
        }
        if let requiredTeam, signingTeam(of: app) != requiredTeam {
            throw UpdatePolicy.error("新版本的开发者签名与当前版本不同，已停止安装。")
        }
    }

    static func prepare(archive: URL, workspace: URL, target: URL, releaseTag: String) throws -> UpdateInstallRequest {
        let fm = FileManager.default
        let target = target.standardizedFileURL
        guard !fm.fileExists(atPath: target.appendingPathComponent("Contents/_MASReceipt/receipt").path) else {
            throw UpdatePolicy.error("App Store 版本请通过 App Store 更新。")
        }
        guard target.pathExtension == "app", Bundle(url: target)?.bundleIdentifier == bundleIdentifier,
              fm.isWritableFile(atPath: target.deletingLastPathComponent().path),
              (try target.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              !target.path.contains("/AppTranslocation/") else {
            throw UpdatePolicy.error("当前应用位置不可覆盖。请将饭格移至可写的“应用程序”文件夹后重试。")
        }
        try validateArchive(archive)
        let expanded = workspace.appendingPathComponent("expanded", isDirectory: true)
        try fm.createDirectory(at: expanded, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        guard let enumerator = fm.enumerator(at: expanded, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw UpdatePolicy.error("无法读取解压后的安装包。")
        }
        var apps: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "app" { apps.append(url) }
        guard apps.count == 1 else { throw UpdatePolicy.error("安装包中必须包含唯一的饭格应用。") }
        let team = signingTeam(of: target)
        try verifyApplication(apps[0], releaseTag: releaseTag, requiredTeam: team)
        let token = UUID().uuidString
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".饭格-update-\(token).app")
        let backup = parent.appendingPathComponent(".饭格-before-update-\(token).app")
        do {
            try fm.copyItem(at: apps[0], to: staged)
            try verifyApplication(staged, releaseTag: releaseTag, requiredTeam: team)
            return UpdateInstallRequest(targetPath: target.path, stagedPath: staged.path, backupPath: backup.path,
                workspacePath: workspace.path, releaseTag: releaseTag, parentPID: getpid(), requiredTeam: team)
        } catch { try? fm.removeItem(at: staged); throw error }
    }

    static func startHelper(_ request: UpdateInstallRequest) throws {
        let fm = FileManager.default
        let workspace = URL(fileURLWithPath: request.workspacePath, isDirectory: true)
        let manifest = workspace.appendingPathComponent("install.json")
        try JSONEncoder().encode(request).write(to: manifest, options: .atomic)
        guard let executable = Bundle.main.executableURL else { throw UpdatePolicy.error("无法启动更新安装器。") }
        let helper = workspace.appendingPathComponent("update-helper")
        try fm.copyItem(at: executable, to: helper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--install-update", manifest.path]
        let log = workspace.appendingPathComponent("installer.log")
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        try? handle.close()
    }

    /// Same-volume renames are the commit point. Keep the complete old bundle
    /// until launch has succeeded; rollback never mixes files between versions.
    static func replace(_ request: UpdateInstallRequest, launch: () throws -> Void) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: request.targetPath)
        let staged = URL(fileURLWithPath: request.stagedPath)
        let backup = URL(fileURLWithPath: request.backupPath)
        guard staged.deletingLastPathComponent() == target.deletingLastPathComponent(),
              backup.deletingLastPathComponent() == target.deletingLastPathComponent(),
              staged.lastPathComponent.hasPrefix(".饭格-update-"), backup.lastPathComponent.hasPrefix(".饭格-before-update-"),
              !fm.fileExists(atPath: backup.path), Bundle(url: target)?.bundleIdentifier == bundleIdentifier else {
            throw UpdatePolicy.error("更新安装路径无效，旧版本保持不变。")
        }
        try verifyApplication(staged, releaseTag: request.releaseTag, requiredTeam: request.requiredTeam)
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: staged, to: target)
            try launch()
        } catch {
            do {
                if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: staged) }
                try fm.moveItem(at: backup, to: target)
            } catch { throw UpdatePolicy.error("更新未完成，旧版本备份位于：\(backup.path)；请从该位置恢复应用。") }
            throw error
        }
    }

    static func acknowledgeLaunch(manifestPath: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let request = try? JSONDecoder().decode(UpdateInstallRequest.self, from: data),
              Bundle.main.bundleURL.standardizedFileURL.path == request.targetPath,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              UpdateVersion(version)?.baseDescription == UpdateVersion(request.releaseTag)?.baseDescription else { return }
        UserDefaults.standard.set(request.releaseTag, forKey: "installedGitHubReleaseTag")
        UserDefaults.standard.set(bundleFingerprint, forKey: "installedGitHubReleaseBundle")
        try? Data("ready".utf8).write(to: URL(fileURLWithPath: request.workspacePath).appendingPathComponent("launch-ready"), options: .atomic)
    }

    static var bundleFingerprint: String {
        "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")"
    }
    static var currentVersion: String {
        if UserDefaults.standard.string(forKey: "installedGitHubReleaseBundle") == bundleFingerprint,
           let tag = UserDefaults.standard.string(forKey: "installedGitHubReleaseTag") { return tag }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func runHelper(manifestPath: String) -> Int32 {
        let fm = FileManager.default
        var request: UpdateInstallRequest?
        var lock: AppInstanceLock?
        do {
            let parsed = try JSONDecoder().decode(UpdateInstallRequest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
            request = parsed
            guard parsed.parentPID > 1, parsed.parentPID != getpid(),
                  URL(fileURLWithPath: manifestPath).deletingLastPathComponent().path == parsed.workspacePath else {
                throw UpdatePolicy.error("更新安装请求无效。")
            }
            let deadline = Date().addingTimeInterval(120)
            while kill(parsed.parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard kill(parsed.parentPID, 0) != 0 else { throw UpdatePolicy.error("饭格尚未退出，本次更新已取消。") }
            let instanceLock = AppInstanceLock(bundleIdentifier: bundleIdentifier)
            guard instanceLock.acquire() else { throw UpdatePolicy.error("饭格已重新打开，请关闭后再次更新。") }
            lock = instanceLock
            try replace(parsed) {
                // Release the lock before the new app starts its own instance.
                instanceLock.release()
                do {
                    try openApp(URL(fileURLWithPath: parsed.targetPath), arguments: ["--complete-update", manifestPath])
                    let receipt = URL(fileURLWithPath: parsed.workspacePath).appendingPathComponent("launch-ready")
                    let timeout = Date().addingTimeInterval(30)
                    while !fm.fileExists(atPath: receipt.path), Date() < timeout {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    }
                    guard fm.fileExists(atPath: receipt.path) else { throw UpdatePolicy.error("新版本未能正常启动，已恢复旧版本。") }
                } catch {
                    // Never roll back code underneath a live process, even if
                    // Launch Services timed out after starting that process.
                    let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == parsed.targetPath }
                    for app in running { app.terminate() }
                    let quitDeadline = Date().addingTimeInterval(8)
                    while running.contains(where: { !$0.isTerminated }), Date() < quitDeadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    }
                    guard !running.contains(where: { !$0.isTerminated }), instanceLock.acquire() else {
                        writeResult(parsed, success: false, message: "新版本未确认启动，旧版本备份位于：\(parsed.backupPath)")
                        exit(EXIT_FAILURE)
                    }
                    throw error
                }
            }
            let backups = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("DesktopRegions/UpdateBackups/\(UUID().uuidString)", isDirectory: true)
            var backupPath = parsed.backupPath
            do {
                try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                let saved = backups.appendingPathComponent("饭格.app")
                try fm.moveItem(at: URL(fileURLWithPath: parsed.backupPath), to: saved)
                backupPath = saved.path
            } catch { NSLog("旧版本备份保留在 %@", backupPath) }
            writeResult(parsed, success: true, message: "已更新到 \(parsed.releaseTag)。\n分区与文件映射设置已保留。\n旧版本备份：\(backupPath)")
            for name in ["update.zip", "expanded", "update-helper"] { try? fm.removeItem(at: URL(fileURLWithPath: parsed.workspacePath).appendingPathComponent(name)) }
            withExtendedLifetime(lock) {}
            return EXIT_SUCCESS
        } catch {
            lock?.release()
            if let request {
                writeResult(request, success: false, message: error.localizedDescription)
                if kill(request.parentPID, 0) != 0 {
                    try? openApp(URL(fileURLWithPath: request.targetPath), arguments: ["--update-result", manifestPath])
                } else {
                    _ = NSApplication.shared
                    NSApp.setActivationPolicy(.accessory)
                    let alert = NSAlert(error: error); NSApp.activate(ignoringOtherApps: true); alert.runModal()
                }
            }
            return EXIT_FAILURE
        }
    }

    private static func writeResult(_ request: UpdateInstallRequest, success: Bool, message: String) {
        try? JSONEncoder().encode(UpdateInstallationResult(success: success, message: message))
            .write(to: URL(fileURLWithPath: request.workspacePath).appendingPathComponent("result.json"), options: .atomic)
    }
    private static func openApp(_ url: URL, arguments: [String]) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        var completed = false
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in launchError = error; completed = true }
        let deadline = Date().addingTimeInterval(30)
        while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard completed else { throw UpdatePolicy.error("启动更新后的饭格超时。") }
        if let launchError { throw launchError }
    }
}
