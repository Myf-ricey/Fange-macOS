// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Saves a Finder-readable copy of the workspace before quitting. The files
/// in the snapshot are aliases, so exporting or removing one leaves its
/// original in place.
final class WorkspaceRecovery {
    struct Layout: Codable {
        let version: Int
        let regions: [Region]
        let usesMacDefaultGrid: Bool
    }

    private static let folderKey = "workspaceRecoveryFolder"
    private static let snapshotPrefix = "分区备份 "
    private static let layoutFile = "分区布局.json"
    private let preferences: UserDefaults
    private let defaultFolderURL: URL

    init(preferences: UserDefaults = .standard, defaultFolderURL: URL? = nil) {
        self.preferences = preferences
        self.defaultFolderURL = defaultFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("饭格恢复", isDirectory: true)
    }

    var folderURL: URL {
        preferences.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultFolderURL
    }

    func setFolder(_ url: URL?) {
        preferences.set(url?.path, forKey: Self.folderKey)
    }

    func save(regions: [Region], usesMacDefaultGrid: Bool, mappedFolders: [UUID: URL] = [:]) throws -> URL {
        let layout = Layout(version: 1, regions: regions, usesMacDefaultGrid: usesMacDefaultGrid)
        let selectedFolder = folderURL
        do {
            return try write(layout, mappedFolders: mappedFolders, to: selectedFolder)
        } catch where selectedFolder != defaultFolderURL {
            return try write(layout, mappedFolders: mappedFolders, to: defaultFolderURL)
        }
    }

    func latestLayout() -> Layout? {
        let folders = folderURL == defaultFolderURL ? [folderURL] : [folderURL, defaultFolderURL]
        let snapshots = folders.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }.filter { $0.lastPathComponent.hasPrefix(Self.snapshotPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for snapshot in snapshots {
            let url = snapshot.appendingPathComponent(Self.layoutFile)
            guard let data = try? Data(contentsOf: url),
                  let result = try? JSONDecoder().decode(Layout.self, from: data),
                  result.version == 1, !result.regions.isEmpty,
                  Set(result.regions.map(\.id)).count == result.regions.count else { continue }
            return result
        }
        return nil
    }

    private func write(_ layout: Layout, mappedFolders: [UUID: URL], to folder: URL) throws -> URL {
        let manager = FileManager.default
        if folder == defaultFolderURL, !FolderFileOperations.entryExists(at: folder) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let id = UUID().uuidString
        let staging = folder.appendingPathComponent(".fange-\(id)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(layout).write(to: staging.appendingPathComponent(Self.layoutFile), options: .atomic)
        for (index, region) in layout.regions.enumerated() {
            let name = region.name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
            let label = String(decoding: name.utf8.prefix(180), as: UTF8.self)
            let regionFolder = staging.appendingPathComponent("\(index + 1) \(label)", isDirectory: true)
            try manager.createDirectory(at: regionFolder, withIntermediateDirectories: false)
            if let path = region.mappedFolderPath {
                let source = mappedFolders[region.id] ?? URL(fileURLWithPath: path, isDirectory: true)
                try addAlias(for: source, named: "打开映射文件夹", in: regionFolder)
            } else {
                for binding in region.itemBindings where binding.isExplicit {
                    let source = URL(fileURLWithPath: binding.path)
                    let name = source.lastPathComponent
                    try addAlias(for: source, named: name, in: regionFolder)
                }
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss-SSS"
        let name = Self.snapshotPrefix + formatter.string(from: Date()) + " " + id.prefix(8)
        let snapshot = folder.appendingPathComponent(name, isDirectory: true)
        try manager.moveItem(at: staging, to: snapshot)
        return snapshot
    }

    private func addAlias(for source: URL, named name: String, in folder: URL) throws {
        guard !FolderFileOperations.entryIsMissing(at: source) else { return }
        var destination = folder.appendingPathComponent(name)
        if name.hasPrefix(".") || FolderFileOperations.entryExists(at: destination) {
            let label = String(decoding: name.utf8.prefix(180), as: UTF8.self)
            destination = folder.appendingPathComponent("替身 \(UUID().uuidString.prefix(8)) \(label)")
        }
        do {
            let data = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: destination)
        } catch {
            // A dangling symbolic link is still a real Desktop entry. Keep
            // its original path accessible even if Finder cannot bookmark it.
            guard !FolderFileOperations.entryIsMissing(at: source) else { return }
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        }
    }
}
