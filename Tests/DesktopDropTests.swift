// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

@main
struct DesktopDropTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = desktop.appendingPathComponent("Zotero.app")
        try Data("fixture".utf8).write(to: url)
        let store = RegionStore(fileURL: root.appendingPathComponent("regions.json"))
        var region = Region.defaultNewRegion(frame: NSRect(x: 100, y: 100, width: 400, height: 500))
        region.allowsCollapse = true
        region.itemBindings = [RegionItemBinding(path: url.path, slotIndex: 0)]
        store.replace(with: [region])
        let visibility = DesktopItemVisibility(journalURL: root.appendingPathComponent("hidden.json"), desktopURL: desktop)
        try visibility.synchronize(regions: store.regions)
        func hidden() -> Bool {
            var info = stat(); _ = lstat(url.path, &info)
            return info.st_flags & UInt32(UF_HIDDEN) != 0
        }
        check(hidden(), "fixture starts hidden behind the bound icon")
        let delegate = AppDelegate(store: store, desktopVisibility: visibility)
        delegate.beginFileDrag(regionID: region.id, urls: [url])
        check(hidden(), "starting a bound-icon drag must not reveal Finder's stale desktop position")
        delegate.endFileDrag(regionID: region.id, urls: [url], operation: [])
        check(hidden() && store.region(id: region.id)!.itemBindings.count == 1,
              "cancelled/rejected drag keeps the source binding and hidden Finder entry")
        check(!NSApp.windows.contains { $0.title == "饭格桌面拖放接收层" && $0.isVisible },
              "drag receiver is removed after cancellation")

        var destination = region.duplicated(name: "Destination", frame: NSRect(x: 600, y: 100, width: 400, height: 500))
        region.itemBindings = []
        destination.itemBindings = [RegionItemBinding(path: url.path, slotIndex: 1)]
        store.replace(with: [region, destination])
        delegate.endFileDrag(regionID: region.id, urls: [url], operation: .move)
        check(store.region(id: destination.id)!.itemBindings.map(\.path) == [url.path] && hidden(),
              "source ended callback preserves ownership assigned by another region")

        let source = RegionFilesView(frame: .zero) { _ in RegionFileAppearance(icon: NSImage(size: NSSize(width: 16, height: 16)), name: "fixture") }
        source.exportsBoundDesktopItems = true
        let receiver = DesktopDropController()
        let realDesktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let candidate = realDesktop.appendingPathComponent("FangeDropPolicyFixture")
        receiver.acceptsPoint = { $0.x < 400 }
        receiver.begin(urls: [candidate])
        let blank = NSPoint(x: 200, y: 300)
        check(receiver.accepts(urls: [candidate], at: blank, source: source, operation: .move),
              "bound Desktop entry has an explicit accepting desktop destination")
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: []),
              "operation.none cannot be interpreted as a successful desktop drop")
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: .copy),
              "copy-only drag cannot accidentally unbind the source")
        check(!receiver.accepts(urls: [candidate], at: NSPoint(x: 500, y: 300), source: source, operation: .move),
              "regions and native Finder icon hit targets are excluded from the blank desktop receiver")
        source.exportsBoundDesktopItems = false
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: .move),
              "mapped-folder sources retain their native Finder Desktop transfer")
        source.exportsBoundDesktopItems = true
        check(!receiver.accepts(urls: [url], at: blank, source: source, operation: .move) &&
              !receiver.accepts(urls: [candidate], at: blank, source: nil, operation: .move),
              "receiver rejects external sources and non-Desktop URLs")
        receiver.end()
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: .move),
              "a finished session cannot accept a later stale drop")

        delegate.endFileDrag(regionID: destination.id, urls: [url], operation: .copy)
        check(hidden() && store.region(id: destination.id)!.itemBindings.count == 1,
              "an external copy preserves the original hidden source and binding")
        let movedURL = root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: url, to: movedURL)
        delegate.endFileDrag(regionID: destination.id, urls: [url], operation: .move)
        var movedInfo = stat(); _ = lstat(movedURL.path, &movedInfo)
        check(store.region(id: destination.id)!.itemBindings.isEmpty && movedInfo.st_flags & UInt32(UF_HIDDEN) == 0,
              "an external move unbinds the original path and restores visibility at the new location")

        try verifyDesktopImport(in: root)
        try verifyFolderDrops(in: root)
        try verifyQuitRecovery(in: root)
        if ProcessInfo.processInfo.environment["FANGE_LIVE_FINDER_MISSING_TEST"] == "1" {
            let missing = realDesktop.appendingPathComponent("FangeMissing-\(UUID().uuidString)")
            let screen = NSScreen.screens.first!
            let error = DesktopArranger.moveDesktopItems([missing], toSlotIndices: [0], in: region, screen: screen)
            check(error.map(DesktopArranger.isMissingItemError) == true, "real Finder reports a deleted item")
            check(DesktopArranger.moveDesktopItems([missing], toSlotIndices: [0], in: region, screen: screen,
                                                  ignoringMissingItems: true) == nil,
                  "background positioning tolerates the real Finder missing-item error")
        }

        // Real Finder regression, using a disposable alias instead of changing
        // the user's Zotero icon or their saved region configuration.
        if ProcessInfo.processInfo.environment["FANGE_LIVE_DROP_TEST"] == "1" {
            let aliasTarget = root.appendingPathComponent("Zotero.app")
            try FileManager.default.createDirectory(at: aliasTarget, withIntermediateDirectories: true)
            let alias = realDesktop.appendingPathComponent("FangeDropRegression-\(UUID().uuidString).app")
            try URL.writeBookmarkData(aliasTarget.bookmarkData(options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil, relativeTo: nil), to: alias)
            defer { try? FileManager.default.removeItem(at: alias) }
            let liveStore = RegionStore(fileURL: root.appendingPathComponent("live-regions.json"))
            var liveRegion = Region.defaultNewRegion(frame: NSRect(x: -5000, y: -5000, width: 400, height: 500))
            liveRegion.allowsCollapse = true
            liveRegion.itemBindings = [RegionItemBinding(path: alias.path, slotIndex: 0)]
            liveStore.replace(with: [liveRegion])
            let liveVisibility = DesktopItemVisibility(journalURL: root.appendingPathComponent("live-hidden.json"), desktopURL: realDesktop)
            try liveVisibility.synchronize(regions: liveStore.regions)
            let live = AppDelegate(store: liveStore, desktopVisibility: liveVisibility)
            live.beginFileDrag(regionID: liveRegion.id, urls: [alias])
            var info = stat(); _ = lstat(alias.path, &info)
            check(info.st_flags & UInt32(UF_HIDDEN) != 0, "real Finder alias stays hidden throughout drag start")
            live.endFileDrag(regionID: liveRegion.id, urls: [alias], operation: [])
            check(liveStore.region(id: liveRegion.id)!.itemBindings.count == 1,
                  "real alias survives an actual source cancellation callback")
            let point = NSPoint(x: NSScreen.screens.first!.visibleFrame.minX + 200,
                                y: NSScreen.screens.first!.visibleFrame.midY)
            check(live.releaseBoundFilesToDesktop([alias], at: point), "real Finder accepts alias placement while it is hidden")
            live.endFileDrag(regionID: liveRegion.id, urls: [alias], operation: .move)
            _ = lstat(alias.path, &info)
            check(info.st_flags & UInt32(UF_HIDDEN) == 0 && liveStore.region(id: liveRegion.id)!.itemBindings.isEmpty,
                  "accepted desktop drop unhides and unbinds the alias after the source callback")
            let reader = NSAppleScript(source: "tell application \"Finder\" to get desktop position of item \"\(alias.lastPathComponent)\" of desktop")!
            var error: NSDictionary?
            let result = reader.executeAndReturnError(&error)
            let expected = NSPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y)
            check(error == nil && abs(CGFloat(result.atIndex(1)!.int32Value) - expected.x) <= 1 &&
                  abs(CGFloat(result.atIndex(2)!.int32Value) - expected.y) <= 1,
                  "Finder reports the requested drop coordinates, not the original stale position")
            let aliasValues = try alias.resourceValues(forKeys: [.isAliasFileKey])
            check(aliasValues.isAliasFile == true &&
                  FileManager.default.fileExists(atPath: aliasTarget.path), "alias identity and original application target are preserved")
        }
    }

    private static func verifyDesktopImport(in root: URL) throws {
        let fm = FileManager.default
        let desktop = root.appendingPathComponent("Import Desktop", isDirectory: true)
        let source = desktop.appendingPathComponent("Source Folder", isDirectory: true)
        let incomingFolder = source.appendingPathComponent("Attachments", isDirectory: true)
        try fm.createDirectory(at: incomingFolder, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("Report.txt")
        let child = incomingFolder.appendingPathComponent("Photo.txt")
        try Data("report".utf8).write(to: file)
        try Data("photo".utf8).write(to: child)
        let store = RegionStore(fileURL: root.appendingPathComponent("desktop-import.json"))
        let visibility = DesktopItemVisibility(journalURL: root.appendingPathComponent("import-hidden.json"), desktopURL: desktop)
        var region = Region.defaultNewRegion(frame: NSRect(x: -5000, y: -5000, width: 400, height: 420))
        region.itemBindings = [RegionItemBinding(path: source.path, slotIndex: 0)]
        store.replace(with: [region])
        let app = AppDelegate(store: store, desktopVisibility: visibility)
        try visibility.synchronize(regions: [region])
        let point = RegionLayout.globalSlotCenters(in: region)[1]
        check(app.filesDropped([file, incomingFolder, child, file], into: region.id, near: point, folder: nil),
              "ordinary region accepts items from inside a managed desktop folder")
        let movedFile = desktop.appendingPathComponent(file.lastPathComponent)
        let movedFolder = desktop.appendingPathComponent(incomingFolder.lastPathComponent)
        waitUntil("batch import binds top-level items once, preserves the original slot, and uses the drop point") {
            let bindings = store.region(id: region.id)?.itemBindings ?? []
            return bindings.count == 3 && bindings.contains(region.itemBindings[0]) &&
                bindings.contains(RegionItemBinding(path: movedFile.path, slotIndex: 1)) &&
                bindings.contains(where: { $0.path == movedFolder.path })
        }
        let photo = try Data(contentsOf: movedFolder.appendingPathComponent(child.lastPathComponent))
        check(isHidden(movedFile) && !fm.fileExists(atPath: file.path) && photo == Data("photo".utf8),
              "real move preserves folder contents and uses managed desktop icons")
        app.undoLastAction()
        waitUntil("one undo restores the files, folder contents, visibility and prior bindings") {
            store.region(id: region.id)?.itemBindings == region.itemBindings &&
                fm.fileExists(atPath: file.path) && fm.fileExists(atPath: child.path) &&
                !fm.fileExists(atPath: movedFile.path) && !fm.fileExists(atPath: movedFolder.path) &&
                !isHidden(file) && !isHidden(incomingFolder)
        }
        check(app.filesDropped([source], into: region.id, near: point, folder: nil, operation: .copy),
              "Option can duplicate a bound desktop folder into another slot")
        let duplicate = desktop.appendingPathComponent("Source Folder 副本", isDirectory: true)
        waitUntil("copy gets a new name and slot without releasing the original") {
            store.region(id: region.id)?.itemBindings.count == 2 && isHidden(duplicate) &&
            fm.fileExists(atPath: duplicate.appendingPathComponent("Attachments/Photo.txt").path)
        }
        app.undoLastAction()
        waitUntil("undo removes only the new copy and preserves the selected original") {
            store.region(id: region.id)?.itemBindings == region.itemBindings && !fm.fileExists(atPath: duplicate.path) &&
            fm.fileExists(atPath: child.path)
        }
        try visibility.restoreAll()
    }

    private static func verifyFolderDrops(in root: URL) throws {
        let fm = FileManager.default
        let desktop = root.appendingPathComponent("FolderDropDesktop", isDirectory: true)
        let folder = desktop.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = desktop.appendingPathComponent("Report.txt")
        let privateFile = desktop.appendingPathComponent("Private.txt")
        for source in [file, privateFile] { try Data(source.lastPathComponent.utf8).write(to: source) }
        check(lchflags(privateFile.path, UInt32(UF_HIDDEN)) == 0, "fixture includes a user-hidden file")

        let store = RegionStore(fileURL: root.appendingPathComponent("folder-drop-regions.json"))
        var region = Region.defaultNewRegion(frame: NSRect(x: -5000, y: -5000, width: 400, height: 420))
        region.itemBindings = [file, folder, privateFile].enumerated().map {
            RegionItemBinding(path: $1.path, slotIndex: $0)
        }
        let mappedRoot = root.appendingPathComponent("Mapped", isDirectory: true)
        let subfolder = mappedRoot.appendingPathComponent("Child", isDirectory: true)
        try fm.createDirectory(at: subfolder, withIntermediateDirectories: true)
        var mapped = Region.defaultNewRegion(frame: region.frame.offsetBy(dx: 500, dy: 0))
        mapped.mappedFolderPath = mappedRoot.path
        mapped.displayMode = .list
        store.replace(with: [region, mapped])
        let visibility = DesktopItemVisibility(journalURL: root.appendingPathComponent("folder-drop-hidden.json"), desktopURL: desktop)
        let delegate = AppDelegate(store: store, desktopVisibility: visibility)
        delegate.endFileDrag(regionID: region.id, urls: [], operation: [])
        check(isHidden(file) && isHidden(folder), "ordinary region presents both files as managed icons")
        let board = NSPasteboard.withUniqueName()
        delegate.copyFilesToClipboard([file, privateFile], board: board)
        check(!isHidden(file) && isHidden(privateFile), "Finder clipboard readers get the original user visibility")
        board.clearContents()
        waitUntil("replacing the clipboard restores the managed icon") { isHidden(file) }
        board.releaseGlobally()
        let point = NSPoint(x: region.frame.midX, y: region.frame.midY)
        check(!delegate.filesDropped([file], into: region.id, near: point, folder: subfolder),
              "ordinary folder target must belong to the receiving region")
        check(delegate.filesDropped([file, privateFile], into: region.id, near: point, folder: folder, operation: .copy),
              "Option accepts a multi-file folder copy")
        waitUntil("copy keeps the original bindings and preserves user visibility on each copy") {
            isHidden(file) && store.regions.first?.itemBindings == region.itemBindings &&
            fm.fileExists(atPath: folder.appendingPathComponent(file.lastPathComponent).path) &&
            !isHidden(folder.appendingPathComponent(file.lastPathComponent)) &&
            isHidden(folder.appendingPathComponent(privateFile.lastPathComponent))
        }
        // Isolate the later move test from these newly created copies.
        try fm.removeItem(at: folder.appendingPathComponent(file.lastPathComponent))
        try fm.removeItem(at: folder.appendingPathComponent(privateFile.lastPathComponent))
        check(delegate.filesDropped([file, privateFile], into: region.id, near: point, folder: folder),
              "ordinary region accepts a real multi-file folder move")
        delegate.endFileDrag(regionID: region.id, urls: [file, privateFile], operation: .move)
        waitUntil("moving clears source bindings and preserves the target folder's slot") {
            store.region(id: region.id)?.itemBindings == [region.itemBindings[1]]
        }
        let visibleChildren = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        check(visibleChildren.map(\.lastPathComponent) == [file.lastPathComponent] &&
              isHidden(folder.appendingPathComponent(privateFile.lastPathComponent)),
              "default Finder visibility includes the moved file and preserves a user-hidden file")

        let mappedFile = mappedRoot.appendingPathComponent("From mapped.txt")
        try Data("mapped content".utf8).write(to: mappedFile)
        let mappedPoint = NSPoint(x: mapped.frame.midX, y: mapped.frame.midY)
        check(delegate.filesDropped([mappedFile], into: mapped.id, near: mappedPoint, folder: subfolder),
              "mapped list accepts a file dropped onto its child folder")
        let movedFile = subfolder.appendingPathComponent(mappedFile.lastPathComponent)
        waitUntil("mapped file lands inside the pointed-at child folder") {
            fm.fileExists(atPath: movedFile.path) && !fm.fileExists(atPath: mappedFile.path)
        }
        let contents = try Data(contentsOf: movedFile)
        check(contents == Data("mapped content".utf8), "folder move preserves the original contents")
    }

    private static func verifyQuitRecovery(in root: URL) throws {
        let manager = FileManager.default
        let desktop = root.appendingPathComponent("Recovery Desktop", isDirectory: true)
        let mapped = root.appendingPathComponent("Mapped Folder", isDirectory: true)
        let selected = root.appendingPathComponent("Selected Backup Folder", isDirectory: true)
        for folder in [desktop, mapped, selected] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let deleted = desktop.appendingPathComponent("deleted.txt")
        let original = desktop.appendingPathComponent("before-rename.txt")
        let originallyHidden = desktop.appendingPathComponent("already-hidden.txt")
        for file in [deleted, original, originallyHidden] {
            try Data("fixture".utf8).write(to: file)
        }
        check(lchflags(originallyHidden.path, UInt32(UF_HIDDEN)) == 0, "fixture is independently hidden")

        let store = RegionStore(fileURL: root.appendingPathComponent("recovery-test-regions.json"))
        var region = Region.defaultNewRegion(frame: NSRect(x: -5000, y: -5000, width: 400, height: 500))
        region.name = "工具/办公"
        region.displayMode = .list
        region.isCollapsed = true
        region.itemBindings = [deleted, original, originallyHidden].enumerated()
            .map { RegionItemBinding(path: $0.element.path, slotIndex: $0.offset) }
        var mappedRegion = region.duplicated(name: "映射", frame: region.frame)
        mappedRegion.mappedFolderPath = mapped.path
        store.replace(with: [region, mappedRegion])

        let journal = root.appendingPathComponent("recovery-test-hidden.json")
        let visibility = DesktopItemVisibility(journalURL: journal, desktopURL: desktop)
        try visibility.synchronize(regions: store.regions)
        let preferenceName = "FangeRecoveryTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: preferenceName)!
        defer { preferences.removePersistentDomain(forName: preferenceName) }
        let fallback = root.appendingPathComponent("Default Backup Folder", isDirectory: true)
        let recovery = WorkspaceRecovery(preferences: preferences, defaultFolderURL: fallback)
        recovery.setFolder(selected)
        let delegate = AppDelegate(store: store, desktopVisibility: visibility, workspaceRecovery: recovery)
        delegate.watchDesktopChanges()

        try manager.removeItem(at: deleted)
        waitUntil("a Desktop deletion releases its binding without a Finder snapshot") {
            !store.regions[0].itemBindings.contains { $0.path == deleted.path }
        }
        let renamed = desktop.appendingPathComponent("after-rename.txt")
        try manager.moveItem(at: original, to: renamed)
        waitUntil("a Desktop rename preserves the hidden entry's slot") {
            store.regions[0].itemBindings.contains { $0.path == renamed.path && $0.slotIndex == 1 } && isHidden(renamed)
        }

        try Data("replacement".utf8).write(to: deleted)
        store.mutate(id: region.id) { $0.itemBindings.append(RegionItemBinding(path: deleted.path, slotIndex: 0)) }
        try visibility.synchronize(regions: store.regions)
        check(isHidden(deleted), "a deleted entry's visibility record cannot claim a new file with the same name")

        check(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "normal quit completes with a recovery snapshot")
        check(!isHidden(renamed) && !isHidden(deleted) && isHidden(originallyHidden),
              "normal quit restores app-owned Desktop flags and respects a preexisting hidden file")
        try Data().write(to: desktop.appendingPathComponent("late-change.txt"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        check(!isHidden(renamed) && !isHidden(deleted), "a late filesystem event cannot hide Desktop entries after quit preparation")

        let folders = try manager.contentsOfDirectory(at: selected, includingPropertiesForKeys: nil)
        check(folders.count == 1, "clean quit saves one complete snapshot in the user-selected folder")
        let directory = folders[0]
        let layout = try JSONDecoder().decode(WorkspaceRecovery.Layout.self, from: Data(contentsOf: directory.appendingPathComponent("分区布局.json")))
        check(layout.regions == store.regions, "the snapshot preserves names, geometry, collapsed state, mapping and slot ownership")
        let link = directory.appendingPathComponent("1 工具／办公").appendingPathComponent(renamed.lastPathComponent)
        let aliasTarget = try URL(resolvingAliasFileAt: link, options: [.withoutUI, .withoutMounting])
        let alias = try link.resourceValues(forKeys: [.isAliasFileKey])
        let mappedLink = directory.appendingPathComponent("2 映射").appendingPathComponent("打开映射文件夹")
        let mappedTarget = try URL(resolvingAliasFileAt: mappedLink, options: [.withoutUI, .withoutMounting])
        check(alias.isAliasFile == true && aliasTarget.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path &&
              mappedTarget.resolvingSymlinksInPath().path == mapped.resolvingSymlinksInPath().path,
              "Finder aliases open the original Desktop item and mapped folder")

        let recoveredStore = RegionStore(fileURL: root.appendingPathComponent("missing-regions.json"))
        let persistedVisibility = DesktopItemVisibility(journalURL: journal, desktopURL: desktop)
        let relaunched = AppDelegate(store: recoveredStore, desktopVisibility: persistedVisibility, workspaceRecovery: recovery)
        relaunched.loadWorkspace()
        check(recoveredStore.regions == layout.regions, "launch recovers the layout when the main configuration is missing")
        try persistedVisibility.synchronize(regions: recoveredStore.regions)
        check(isHidden(renamed) && isHidden(deleted), "relaunch restores managed icon presentation from the saved bindings")
        try persistedVisibility.restoreAll()

        recovery.setFolder(root.appendingPathComponent("Unavailable Backup Folder", isDirectory: true))
        let backup = try recovery.save(regions: store.regions, usesMacDefaultGrid: true)
        check(backup.deletingLastPathComponent().path == fallback.path && recovery.latestLayout()?.usesMacDefaultGrid == true,
              "an unavailable custom folder falls back to the default and the layout remains recoverable")
    }

    private static func isHidden(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(UF_HIDDEN) != 0
    }

    private static func waitUntil(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        check(condition(), message)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { print("FAIL: \(message)"); exit(1) }
        print("PASS: \(message)")
    }
}
