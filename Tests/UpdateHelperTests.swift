// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

@main
struct UpdateHelperTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2, "pass the built DesktopRegions executable")
        precondition(!NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == UpdateInstaller.bundleIdentifier }, "close the running Fange before this disposable helper test")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fange-helper-tests-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Fixture.swift")
        try Data(#"""
        import Cocoa
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--complete-update"), CommandLine.arguments.count > index + 1,
           let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])),
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let directory = request["workspacePath"] as? String {
            try? Data("ready".utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("launch-ready"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        NSApp.run()
        """#.utf8).write(to: source)
        let binary = root.appendingPathComponent("Fixture")
        try UpdateInstaller.run("/usr/bin/swiftc", ["-framework", "Cocoa", source.path, "-o", binary.path])
        func app(_ name: String, version: String) throws -> URL {
            let app = root.appendingPathComponent(name, isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try fm.copyItem(at: binary, to: contents.appendingPathComponent("MacOS/Fixture"))
            let info: [String: Any] = ["CFBundleIdentifier": UpdateInstaller.bundleIdentifier, "CFBundleExecutable": "Fixture", "CFBundleName": "饭格安装测试", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1", "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            try Data(version.utf8).write(to: contents.appendingPathComponent("Resources/version.txt"))
            try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
            return app
        }
        let target = try app("饭格安装测试.app", version: "0.2.0")
        let staged = try app(".饭格-update-\(UUID()).app", version: "0.3.0")
        let backup = root.appendingPathComponent(".饭格-before-update-\(UUID()).app")
        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldProcess.arguments = ["1"]
        try oldProcess.run()
        let request = UpdateInstallRequest(targetPath: target.path, stagedPath: staged.path, backupPath: backup.path,
            workspacePath: root.path, releaseTag: "v0.3.0", parentPID: oldProcess.processIdentifier, requiredTeam: nil)
        let manifest = root.appendingPathComponent("install.json")
        try JSONEncoder().encode(request).write(to: manifest)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        helper.arguments = ["--install-update", manifest.path]
        try helper.run()
        oldProcess.waitUntilExit()
        helper.waitUntilExit()
        guard helper.terminationStatus == 0 else { throw UpdatePolicy.error("helper exited \(helper.terminationStatus)") }
        let result = try JSONDecoder().decode(UpdateInstallationResult.self, from: Data(contentsOf: root.appendingPathComponent("result.json")))
        guard result.success else { throw UpdatePolicy.error(result.message) }
        let installed = try String(contentsOf: target.appendingPathComponent("Contents/Resources/version.txt"), encoding: .utf8)
        precondition(installed == "0.3.0")
        let backupPath = String(result.message.split(separator: "\n").first { $0.hasPrefix("旧版本备份：") }!.dropFirst("旧版本备份：".count))
        let saved = URL(fileURLWithPath: backupPath)
        let oldVersion = try String(contentsOf: saved.appendingPathComponent("Contents/Resources/version.txt"), encoding: .utf8)
        precondition(oldVersion == "0.2.0")
        let backupsRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("DesktopRegions/UpdateBackups").path
        precondition(saved.path.hasPrefix(backupsRoot + "/"))
        try fm.removeItem(at: saved.deletingLastPathComponent())
        let end = Date().addingTimeInterval(8)
        while NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == target.path }), Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        print("separate installer process, parent exit wait, instance lock, real launch receipt, backup migration and restart: PASS")
    }
}
