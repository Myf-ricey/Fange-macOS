// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

/// Only temporary UF_HIDDEN bits owned by this app are restored. A durable
/// journal is written before hiding anything, including identity and bookmark,
/// so a crash/rename cannot leave an untracked hidden desktop entry.
final class DesktopItemVisibility {
    private struct Entry: Codable, Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanos: Int64
        let bookmark: Data?

        func matches(_ info: stat) -> Bool {
            info.st_dev == device && info.st_ino == inode &&
                Int64(info.st_birthtimespec.tv_sec) == birthSeconds &&
                Int64(info.st_birthtimespec.tv_nsec) == birthNanos
        }
    }
    private let journalURL: URL
    let desktopURL: URL
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
        try restore(entries.filter { entry in
            var info = stat()
            return !desired.contains(entry.path) || (lstat(entry.path, &info) == 0 && !entry.matches(info))
        })
        for path in desired {
            // A normal region can only own desktop entries, never a symlink's
            // target or arbitrary files elsewhere on the user's disk.
            let url = URL(fileURLWithPath: path)
            guard contains(url) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            guard info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            if !entries.contains(where: { $0.path == path && $0.matches(info) }) {
                let entry = Entry(path: path, device: info.st_dev, inode: info.st_ino,
                    birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanos: Int64(info.st_birthtimespec.tv_nsec),
                    bookmark: try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
                try save(entries + [entry])
            }
            var current = stat()
            guard lstat(path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                  current.st_birthtimespec.tv_sec == info.st_birthtimespec.tv_sec,
                  current.st_birthtimespec.tv_nsec == info.st_birthtimespec.tv_nsec else { continue }
            if lchflags(path, current.st_flags | UInt32(UF_HIDDEN)) != 0 {
                let code = errno
                if code == ENOENT || code == ENOTDIR { continue }
                throw FolderFileOperations.error("无法临时隐藏图标：\(url.lastPathComponent)（\(String(cString: strerror(code)))）")
            }
        }
    }

    func contains(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return parent.path == desktopURL.standardizedFileURL.path ||
            parent.resolvingSymlinksInPath().path == desktopURL.resolvingSymlinksInPath().path
    }

    var relocatedEntries: [String: String] {
        var seen = Set<String>()
        var relocated: [String: String] = [:]
        // A deleted entry can share a pathname with a replacement. Use the
        // most recent identity tracked for the path when following a rename.
        for entry in entries.reversed() where seen.insert(entry.path).inserted {
            if let current = locate(entry), current.path != entry.path {
                relocated[entry.path] = current.path
            }
        }
        return relocated
    }

    func restoreAll() throws { try restore(entries) }

    func restore(paths: Set<String>) throws {
        try restore(entries.filter { paths.contains($0.path) })
    }

    private func restore(_ candidates: [Entry]) throws {
        var restored = Set<Entry>()
        var failures: [String] = []
        for entry in candidates {
            guard let url = locate(entry) else {
                // Deleted entries need no recovery. Unresolved bookmarks are
                // retained and retried when their volume is available again.
                if entry.bookmark == nil && FolderFileOperations.entryIsMissing(at: URL(fileURLWithPath: entry.path)) {
                    restored.insert(entry)
                }
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, entry.matches(info) else { continue }
            if info.st_flags & UInt32(UF_HIDDEN) == 0 ||
                lchflags(url.path, info.st_flags & ~UInt32(UF_HIDDEN)) == 0 {
                restored.insert(entry)
            } else if errno != ENOENT && errno != ENOTDIR && contains(url) {
                failures.append(url.lastPathComponent)
            }
        }
        if !restored.isEmpty {
            try save(entries.filter { !restored.contains($0) })
        }
        if !failures.isEmpty { throw FolderFileOperations.error("以下图标未能恢复显示，请检查文件权限：" + failures.joined(separator: "、")) }
    }

    private func locate(_ entry: Entry) -> URL? {
        func matches(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && entry.matches(info)
        }
        let original = URL(fileURLWithPath: entry.path)
        if matches(original) { return original }
        if let data = entry.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale), matches(resolved) {
                return resolved
            }
        }
        return (try? FileManager.default.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: nil))?.first(where: matches)
    }

    private func save(_ updated: [Entry]) throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: journalURL, options: .atomic)
        entries = updated
    }
}
