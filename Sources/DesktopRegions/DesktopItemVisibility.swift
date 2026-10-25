// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

/// Only temporary UF_HIDDEN bits owned by this app are restored. A durable
/// journal is written before hiding anything, including identity and bookmark,
/// so a crash/rename cannot leave an untracked hidden desktop entry.
final class DesktopItemVisibility {
    private struct Entry: Codable {
        let path: String
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanos: Int64
        let bookmark: Data?
    }
    private let journalURL: URL
    private let desktopURL: URL
    private var entries: [Entry]
    var temporarilyVisiblePaths = Set<String>()

    init(journalURL: URL? = nil, desktopURL: URL? = nil) {
        self.desktopURL = desktopURL ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        self.journalURL = journalURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DesktopRegions/temporary-hidden-items.json")
        entries = (try? Data(contentsOf: self.journalURL)).flatMap {
            try? JSONDecoder().decode([Entry].self, from: $0)
        } ?? []
    }

    func synchronize(regions: [Region]) throws {
        let desired = Set(regions.filter(\.hidesDesktopItems).flatMap {
            $0.itemBindings.filter(\.isExplicit).map(\.path)
        }).subtracting(temporarilyVisiblePaths)
        try restore(paths: Set(entries.map(\.path)).subtracting(desired))
        for path in desired where !entries.contains(where: { $0.path == path }) {
            // A normal region can only own desktop entries, never a symlink's
            // target or arbitrary files elsewhere on the user's disk.
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL == desktopURL.standardizedFileURL else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            guard info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            let entry = Entry(path: path, device: info.st_dev, inode: info.st_ino,
                birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanos: Int64(info.st_birthtimespec.tv_nsec),
                bookmark: try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
            entries.append(entry)
            do { try save() } catch { entries.removeLast(); throw error }
            guard lchflags(path, info.st_flags | UInt32(UF_HIDDEN)) == 0 else {
                entries.removeLast()
                try save()
                throw FolderFileOperations.error("无法临时隐藏图标：\(url.lastPathComponent)（\(String(cString: strerror(errno)))）")
            }
        }
    }

    var relocatedEntries: [String: String] {
        Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard let current = locate(entry), current.path != entry.path else { return nil }
            return (entry.path, current.path)
        })
    }

    func restoreAll() throws { try restore(paths: Set(entries.map(\.path))) }

    func restore(paths: Set<String>) throws {
        var restored = Set<String>()
        var failures: [String] = []
        for entry in entries where paths.contains(entry.path) {
            guard let url = locate(entry) else {
                // Deleted entries need no recovery. Unresolved bookmarks are
                // retained and retried when their volume is available again.
                if entry.bookmark == nil { restored.insert(entry.path) }
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if lchflags(url.path, info.st_flags & ~UInt32(UF_HIDDEN)) == 0 {
                restored.insert(entry.path)
            } else { failures.append(url.lastPathComponent) }
        }
        if !restored.isEmpty {
            entries.removeAll { restored.contains($0.path) }
            try save()
        }
        if !failures.isEmpty { throw FolderFileOperations.error("以下图标未能恢复显示，请检查文件权限：" + failures.joined(separator: "、")) }
    }

    private func locate(_ entry: Entry) -> URL? {
        func matches(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && info.st_dev == entry.device && info.st_ino == entry.inode &&
                Int64(info.st_birthtimespec.tv_sec) == entry.birthSeconds &&
                Int64(info.st_birthtimespec.tv_nsec) == entry.birthNanos
        }
        let original = URL(fileURLWithPath: entry.path)
        if matches(original) { return original }
        if let data = entry.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale), matches(resolved) {
                return resolved
            }
        }
        return (try? FileManager.default.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: nil))?.first(where: matches)
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: journalURL, options: .atomic)
    }
}
