// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

struct FileMove: Codable, Equatable {
    let source: String
    let destination: String
    var copiedIdentity: CopiedItemIdentity?
}

/// Undo can trash the copy we created, even if its original was renamed.
/// A different item subsequently placed at the same path must be left alone.
struct CopiedItemIdentity: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int
    let birthNanos: Int

    init(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw FolderFileOperations.error("找不到副本：\(url.lastPathComponent)") }
        device = info.st_dev
        inode = info.st_ino
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanos = info.st_birthtimespec.tv_nsec
    }
}

enum FolderFileOperations {
    static func isDropFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey])
        return values?.isDirectory == true && values?.isPackage == false &&
            values?.isSymbolicLink == false && values?.isAliasFile != true
    }

    static func entryExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func entryIsMissing(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "DesktopRegions.Files", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func topLevelSources(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let sources = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        return sources.filter { candidate in
            !sources.contains { parent in
                parent != candidate && candidate.path.hasPrefix(parent.path + "/") &&
                (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            }
        }
    }

    /// Validate the complete batch before changing any file. Never replace an
    /// existing entry, including a dangling symbolic link.
    static func planMove(_ urls: [URL], into folder: URL, copying: Bool = false) throws -> [FileMove] {
        let folder = folder.standardizedFileURL
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard values.isDirectory == true, values.isWritable != false else {
            throw error("目标文件夹不可写，请重新选择文件夹或检查访问权限。")
        }
        let canonicalFolder = folder.resolvingSymlinksInPath().path
        var moves: [FileMove] = []
        var destinations = Set<String>()
        for source in topLevelSources(urls) {
            var info = stat()
            guard lstat(source.path, &info) == 0 else { throw error("找不到文件：\(source.lastPathComponent)") }
            let isLink = (info.st_mode & S_IFMT) == S_IFLNK
            let canonicalSource = isLink ? source.path : source.resolvingSymlinksInPath().path
            if canonicalFolder == canonicalSource || canonicalFolder.hasPrefix(canonicalSource + "/") {
                throw error("不能把文件夹放入自身或它的子文件夹。")
            }
            var destination = folder.appendingPathComponent(source.lastPathComponent)
            if source.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalFolder {
                guard copying else { continue }
                let stem = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                var number = 1
                repeat {
                    let suffix = number == 1 ? " 副本" : " 副本 \(number)"
                    destination = folder.appendingPathComponent(stem + suffix + ext)
                    number += 1
                } while entryExists(at: destination) || destinations.contains(destination.path)
            }
            var existing = stat()
            guard lstat(destination.path, &existing) != 0,
                  destinations.insert(destination.path).inserted else {
                throw error("目标中已有同名项目“\(source.lastPathComponent)”。请先在访达中重命名，再拖入。")
            }
            moves.append(FileMove(source: source.path, destination: destination.path))
        }
        return moves
    }

    static func execute(_ moves: [FileMove]) throws {
        var completed: [FileMove] = []
        do {
            for move in moves {
                try coordinatedMove(from: URL(fileURLWithPath: move.source), to: URL(fileURLWithPath: move.destination))
                completed.append(move)
            }
        } catch {
            let failure = error
            var failedRestores: [String] = []
            for move in completed.reversed() {
                do { try coordinatedMove(from: URL(fileURLWithPath: move.destination), to: URL(fileURLWithPath: move.source)) }
                catch { failedRestores.append(move.destination) }
            }
            if !failedRestores.isEmpty {
                throw self.error("\(failure.localizedDescription)\n以下文件已移动，请在访达中检查：\n" + failedRestores.joined(separator: "\n"))
            }
            throw failure
        }
    }

    static func copy(_ plan: [FileMove], into folder: URL) throws -> [FileMove] {
        let manager = FileManager.default
        let staging = folder.appendingPathComponent(".fange-copy-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        var publish: [FileMove] = []
        var copies: [FileMove] = []
        for var item in plan {
            let staged = staging.appendingPathComponent(UUID().uuidString)
            try manager.copyItem(at: URL(fileURLWithPath: item.source), to: staged)
            item.copiedIdentity = try CopiedItemIdentity(at: staged)
            copies.append(item)
            publish.append(FileMove(source: staged.path, destination: item.destination))
        }
        // All copies are complete before exposing the first final name.
        try execute(publish)
        return copies
    }

    private static func undoCopies(_ copies: [FileMove]) throws {
        for copy in copies {
            let url = URL(fileURLWithPath: copy.destination)
            guard try CopiedItemIdentity(at: url) == copy.copiedIdentity else {
                throw error("无法撤销拷贝：原副本已被替换。\n\(url.path)")
            }
        }
        var restore: [FileMove] = []
        do {
            for copy in copies {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: copy.destination), resultingItemURL: &trashed)
                if let path = trashed?.path { restore.append(FileMove(source: path, destination: copy.destination)) }
            }
        } catch {
            try execute(Array(restore.reversed()))
            throw error
        }
    }

    static func rename(_ source: URL, to name: String) throws -> FileMove {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw error("文件名不能为空、不能以句点开头，也不能包含斜杠或冒号。")
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        let move = FileMove(source: source.path, destination: destination.path)
        try execute([move])
        return move
    }

    static func undo(_ moves: [FileMove]) throws {
        if moves.first?.copiedIdentity != nil { try undoCopies(moves); return }
        // Preflight reverse operations too: undo must never overwrite new work.
        for move in moves {
            var info = stat()
            guard lstat(move.destination, &info) == 0 else { throw error("无法撤销：文件已被移动或删除。\n\(move.destination)") }
            guard lstat(move.source, &info) != 0 || isAlternateSpelling(move) else {
                throw error("无法撤销：原位置已有同名文件。\n\(move.source)")
            }
        }
        try execute(moves.reversed().map { FileMove(source: $0.destination, destination: $0.source) })
    }

    private static func isAlternateSpelling(_ move: FileMove) -> Bool {
        let source = URL(fileURLWithPath: move.source)
        let destination = URL(fileURLWithPath: move.destination)
        let folder = source.deletingLastPathComponent()
        guard folder == destination.deletingLastPathComponent(),
              source.lastPathComponent.caseInsensitiveCompare(destination.lastPathComponent) == .orderedSame,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.contains(destination.lastPathComponent) && !names.contains(source.lastPathComponent)
    }

    private static func coordinatedMove(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                // moveItem refuses collisions even if another process created
                // the destination after preflight.
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
    }
}

/// Keeps the user-selected directory authorized while its contents are shown.
/// A filesystem source delivers immediate changes; polling repairs missed
/// events on cloud/network volumes and retries temporarily unavailable folders.
final class MappedFolderSession {
    let savedPath: String
    let bookmark: Data?
    private(set) var folderURL: URL
    private var scoped = false
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.ricey.desktop-regions.folder", qos: .userInitiated)
    private var loading = false
    private var reloadAgain = false
    private var discardCurrentLoad = false
    var onChange: (([URL], String?) -> Void)?
    var sortOptions: RegionFileSort {
        didSet { if sortOptions != oldValue { reload() } }
    }

    init(path: String, bookmark: Data?, sortOptions: RegionFileSort = RegionFileSort()) {
        self.sortOptions = sortOptions
        self.savedPath = path
        self.bookmark = bookmark
        var stale = false
        folderURL = bookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        } ?? URL(fileURLWithPath: path, isDirectory: true)
        scoped = folderURL.startAccessingSecurityScopedResource()
    }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func start() {
        installWatcher()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
    }

    func reload(discardInFlight: Bool = false) {
        guard !loading else {
            reloadAgain = true
            discardCurrentLoad = discardCurrentLoad || discardInFlight
            return
        }
        loading = true
        let url = folderURL
        let sort = sortOptions
        queue.async { [weak self] in
            let result: Result<[URL], Error> = Result {
                let urls = try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: Array(RegionFileSorting.resourceKeys), options: [.skipsHiddenFiles])
                return RegionFileSorting.sorted(urls, by: sort)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading = false
                if self.discardCurrentLoad {
                    self.discardCurrentLoad = false
                } else {
                    switch result {
                    case .success(let urls): self.onChange?(urls, nil)
                    case .failure(let error): self.onChange?([], "文件夹暂不可访问，请检查磁盘或重新选择映射。\n\(error.localizedDescription)")
                    }
                }
                if self.watcher == nil { self.installWatcher() }
                if self.reloadAgain { self.reloadAgain = false; self.reload() }
            }
        }
    }

    private func installWatcher() {
        let fd = open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let flags = self.watcher?.data, !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                self.watcher?.cancel()
                self.watcher = nil
                if let bookmark = self.bookmark {
                    var stale = false
                    if let updated = try? URL(resolvingBookmarkData: bookmark,
                        options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        if self.scoped { self.folderURL.stopAccessingSecurityScopedResource() }
                        self.folderURL = updated
                        self.scoped = updated.startAccessingSecurityScopedResource()
                    }
                }
            }
            self.reload()
        }
        source.setCancelHandler { Darwin.close(fd) }
        watcher = source
        source.resume()
    }

    deinit {
        timer?.invalidate()
        watcher?.cancel()
        if scoped { folderURL.stopAccessingSecurityScopedResource() }
    }
}
