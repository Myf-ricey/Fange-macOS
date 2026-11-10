// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

struct FileMove: Codable, Equatable {
    let source: String
    let destination: String
}

enum FolderFileOperations {
    static func entryExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "DesktopRegions.Files", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Validate the complete batch before changing any file. Never replace an
    /// existing entry, including a dangling symbolic link.
    static func planMove(_ urls: [URL], into folder: URL) throws -> [FileMove] {
        let folder = folder.standardizedFileURL
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard values.isDirectory == true, values.isWritable != false else {
            throw error("目标文件夹不可写，请重新选择文件夹或检查访问权限。")
        }
        let canonicalFolder = folder.resolvingSymlinksInPath().path
        var seen = Set<String>()
        let sources = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        let roots = sources.filter { candidate in
            !sources.contains { parent in
                parent != candidate && candidate.path.hasPrefix(parent.path + "/") &&
                (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            }
        }
        var moves: [FileMove] = []
        var destinations = Set<String>()
        for source in roots {
            var info = stat()
            guard lstat(source.path, &info) == 0 else { throw error("找不到文件：\(source.lastPathComponent)") }
            let isLink = (info.st_mode & S_IFMT) == S_IFLNK
            let canonicalSource = isLink ? source.path : source.resolvingSymlinksInPath().path
            if canonicalFolder == canonicalSource || canonicalFolder.hasPrefix(canonicalSource + "/") {
                throw error("不能把文件夹放入自身或它的子文件夹。")
            }
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            if source.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalFolder { continue }
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

    static func undo(_ moves: [FileMove]) throws {
        // Preflight reverse operations too: undo must never overwrite new work.
        for move in moves {
            var info = stat()
            guard lstat(move.destination, &info) == 0 else { throw error("无法撤销：文件已被移动或删除。\n\(move.destination)") }
            guard lstat(move.source, &info) != 0 else { throw error("无法撤销：原位置已有同名文件。\n\(move.source)") }
        }
        try execute(moves.reversed().map { FileMove(source: $0.destination, destination: $0.source) })
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

    func reload() {
        guard !loading else { reloadAgain = true; return }
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
                switch result {
                case .success(let urls): self.onChange?(urls, nil)
                case .failure(let error): self.onChange?([], "文件夹暂不可访问，请检查磁盘或重新选择映射。\n\(error.localizedDescription)")
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
