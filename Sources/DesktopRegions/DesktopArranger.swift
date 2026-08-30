// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

enum DesktopArranger {
    static func restoreDesktopIconPositions(_ positions: [DesktopIconPosition]) -> Error? {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let desktopPath = desktopURL.standardizedFileURL.path
        let commands = positions.compactMap { item -> String? in
            let url = URL(fileURLWithPath: item.path).standardizedFileURL
            guard url.deletingLastPathComponent().path == desktopPath,
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            let path = appleScriptString(url.path)
            return "set theItem to (POSIX file \"\(path)\" as alias)\nset desktop position of theItem to {\(Int(item.position.x)), \(Int(item.position.y))}"
        }
        guard !commands.isEmpty else { return nil }
        let source = "tell application \"Finder\"\n" + commands.joined(separator: "\n") + "\nend tell"
        return execute(source)
    }

    static func moveDesktopItems(
        _ urls: [URL],
        toSlotIndices slotIndices: [Int],
        in region: Region,
        screen: NSScreen
    ) -> Error? {
        guard urls.count == slotIndices.count else {
            return NSError(
                domain: "DesktopRegions",
                code: 1006,
                userInfo: [NSLocalizedDescriptionKey: "图标与目标位置数量不一致。"]
            )
        }

        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let desktopPath = desktopURL.standardizedFileURL.path
        let pairs = zip(urls, slotIndices).filter { url, _ in
            url.deletingLastPathComponent().standardizedFileURL.path == desktopPath
        }
        guard pairs.count == urls.count, !pairs.isEmpty else {
            return NSError(
                domain: "DesktopRegions",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "请从桌面上的文件图标拖入区域。其他位置的文件不会被移动到桌面。"]
            )
        }

        let positions = RegionLayout.finderIconPositions(in: region, screenFrame: screen.frame, count: Int.max)
        guard pairs.allSatisfy({ positions.indices.contains($0.1) }) else {
            return NSError(
                domain: "DesktopRegions",
                code: 1005,
                userInfo: [NSLocalizedDescriptionKey: "“\(region.name)”没有足够的空余图标位置，请增加网格行列数后再试。"]
            )
        }

        let commands = pairs.map { url, slotIndex -> String in
            let path = appleScriptString(url.standardizedFileURL.path)
            let point = positions[slotIndex]
            return "set theItem to (POSIX file \"\(path)\" as alias)\nset desktop position of theItem to {\(point.x), \(point.y)}"
        }
        let source = "tell application \"Finder\"\n" + commands.joined(separator: "\n") + "\nend tell"
        return execute(source)
    }

    static func moveDesktopItems(
        _ urls: [URL],
        into region: Region,
        screen: NSScreen,
        occupiedItems: [FinderDesktopItem] = []
    ) -> Error? {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let desktopPath = desktopURL.standardizedFileURL.path
        let desktopItems = urls.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path == desktopPath
        }
        guard !desktopItems.isEmpty else {
            return NSError(
                domain: "DesktopRegions",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "请从桌面上的文件图标拖入区域。其他位置的文件不会被移动到桌面。"]
            )
        }

        let movingPaths = Set(desktopItems.map { $0.standardizedFileURL.path })
        let occupied = occupiedItems.filter { !movingPaths.contains($0.url.standardizedFileURL.path) }
        let positions = positions(in: region, screen: screen, count: Int.max).filter { point in
            !occupied.contains { item in
                abs(item.position.x - CGFloat(point.x)) < 72 && abs(item.position.y - CGFloat(point.y)) < 72
            }
        }
        guard positions.count >= desktopItems.count else {
            return NSError(
                domain: "DesktopRegions",
                code: 1005,
                userInfo: [NSLocalizedDescriptionKey: "“\(region.name)”没有足够的空余图标位置，请放大区域后再试。"]
            )
        }
        var commands: [String] = []
        for (index, url) in desktopItems.enumerated() {
            let path = appleScriptString(url.standardizedFileURL.path)
            let point = positions[index]
            commands.append("set theItem to (POSIX file \"\(path)\" as alias)\nset desktop position of theItem to {\(point.x), \(point.y)}")
        }

        let source = "tell application \"Finder\"\n" + commands.joined(separator: "\n") + "\nend tell"
        return execute(source)
    }

    private static func positions(in region: Region, screen: NSScreen, count: Int) -> [(x: Int, y: Int)] {
        RegionLayout.finderIconPositions(in: region, screenFrame: screen.frame, count: count)
    }

    private static func execute(_ source: String) -> Error? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        guard let script else {
            return NSError(domain: "DesktopRegions", code: 1003, userInfo: [NSLocalizedDescriptionKey: "无法创建 Finder 图标定位脚本。"])
        }
        if !script.compileAndReturnError(&error) {
            let description = error?[NSAppleScript.errorMessage] as? String ?? "Finder 图标定位脚本编译失败。"
            return NSError(domain: "DesktopRegions", code: 1004, userInfo: [NSLocalizedDescriptionKey: description])
        }
        _ = script.executeAndReturnError(&error)
        if let error {
            let description = error[NSAppleScript.errorAppName] as? String
                ?? error[NSAppleScript.errorMessage] as? String
                ?? "Finder 未能完成桌面图标整理。"
            return NSError(domain: "DesktopRegions", code: 1002, userInfo: [NSLocalizedDescriptionKey: description])
        }
        return nil
    }

    private static func appleScriptString(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
