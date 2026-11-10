// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

@main
struct FolderFeaturesTests {
    static func main() throws {
        _ = NSApplication.shared
        func check(_ condition: Bool, _ message: String = "check failed") { precondition(condition, message) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("fange-folder-tests-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ name: String, in folder: URL, text: String = "content") throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        func hidden(_ url: URL) -> Bool {
            var info = stat()
            check(lstat(url.path, &info) == 0)
            return info.st_flags & UInt32(UF_HIDDEN) != 0
        }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("expected rejection") } catch {}
        }
        func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 6) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            check(condition(), "filesystem change did not reach the view")
        }

        var region = Region.defaultNewRegion(frame: NSRect(x: -5000, y: -5000, width: 270, height: 420))
        region.fileSort = RegionFileSort(key: .size, ascending: false, foldersFirst: false)
        let json = try JSONEncoder().encode(region)
        var legacy = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        for key in ["mappedFolderPath", "mappedFolderBookmark", "allowsCollapse", "isCollapsed", "displayMode", "fileSort"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Region.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(!decoded.isMapped && decoded.allowsCollapse && !decoded.isCollapsed && decoded.displayMode == .icons)
        region.displayMode = .list
        region.isCollapsed = true
        region.mappedFolderPath = "/tmp/example"
        region.mappedFolderBookmark = Data([1, 2, 3])
        check(try JSONDecoder().decode(Region.self, from: JSONEncoder().encode(region)) == region)
        let duplicate = region.duplicated(name: "copy", frame: region.frame)
        check(!duplicate.isMapped && duplicate.displayMode == .list && duplicate.allowsCollapse && !duplicate.isCollapsed)
        region.allowsCollapse = false
        check(!(try JSONDecoder().decode(Region.self, from: JSONEncoder().encode(region))).isCollapsed)
        check(decoded.fileSort == RegionFileSort())
        check(duplicate.fileSort == region.fileSort)
        print("legacy migration, persisted options, duplication: PASS")

        let sorting = try directory("sorting")
        let f10 = try write("file10.txt", in: sorting, text: "1234567890")
        let f2 = try write("file2.txt", in: sorting, text: "12")
        let f1 = try write("file1.txt", in: sorting, text: "1")
        let folder = sorting.appendingPathComponent("z-folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let inputs = [f10, f1, f2, folder]
        check(RegionFileSorting.sorted(inputs, by: RegionFileSort()).map(\.lastPathComponent) == ["z-folder", "file1.txt", "file2.txt", "file10.txt"])
        check(RegionFileSorting.sorted(inputs, by: RegionFileSort(key: .size, ascending: false)).map(\.lastPathComponent) == ["z-folder", "file10.txt", "file2.txt", "file1.txt"])
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, url) in [f10, f1, f2].enumerated() {
            try fm.setAttributes([.modificationDate: baseDate.addingTimeInterval(Double(i) * 100)], ofItemAtPath: url.path)
        }
        check(RegionFileSorting.sorted([f10, f1, f2], by: RegionFileSort(key: .modified, ascending: false)).map(\.lastPathComponent) == ["file2.txt", "file1.txt", "file10.txt"])
        check(RegionFileSorting.sorted(inputs, by: RegionFileSort(key: .name, ascending: false, foldersFirst: false)).first == folder)
        print("natural names, metadata sorting, descending order, independent folder priority: PASS")

        let sortControls = RegionSortControls()
        var sortChanges: [RegionFileSort] = []
        sortControls.onChange = { sortChanges.append($0) }
        sortControls.update(RegionFileSort(key: .size, ascending: false, foldersFirst: true))
        check(sortChanges.isEmpty && sortControls.keyPopup.titleOfSelectedItem == "大小" &&
            sortControls.orderPopup.titleOfSelectedItem == "降序" && sortControls.foldersFirst.state == .on,
            "排序设置应反映已保存选项，刷新设置不能再次触发修改")
        sortControls.keyPopup.selectItem(at: RegionFileSortKey.allCases.firstIndex(of: .modified)!)
        sortControls.keyPopup.sendAction(sortControls.keyPopup.action!, to: sortControls.keyPopup.target)
        check(sortChanges.last == RegionFileSort(key: .modified, ascending: false, foldersFirst: true))
        sortControls.orderPopup.selectItem(at: 0)
        sortControls.orderPopup.sendAction(sortControls.orderPopup.action!, to: sortControls.orderPopup.target)
        sortControls.foldersFirst.state = .off
        sortControls.foldersFirst.sendAction(sortControls.foldersFirst.action!, to: sortControls.foldersFirst.target)
        check(sortChanges.last == RegionFileSort(key: .modified, ascending: true, foldersFirst: false))
        print("visible sorting controls reflect saved values and emit independent changes: PASS")

        let source = try directory("source")
        let target = try directory("target")
        let one = try write("one.txt", in: source)
        let two = try write("two.txt", in: source)
        let moves = try FolderFileOperations.planMove([one, two, one], into: target)
        check(moves.count == 2)
        try FolderFileOperations.execute(moves)
        check(!fm.fileExists(atPath: one.path) && fm.fileExists(atPath: target.appendingPathComponent("one.txt").path))
        try FolderFileOperations.undo(moves)
        check(fm.fileExists(atPath: one.path) && !fm.fileExists(atPath: target.appendingPathComponent("one.txt").path))
        _ = try write("two.txt", in: target, text: "existing")
        rejects { _ = try FolderFileOperations.planMove([one, two], into: target) }
        let existingContent = try String(contentsOf: target.appendingPathComponent("two.txt"), encoding: .utf8)
        check(fm.fileExists(atPath: one.path) && existingContent == "existing")
        // A collision appearing after preflight must roll back earlier moves.
        rejects { try FolderFileOperations.execute(moves) }
        check(fm.fileExists(atPath: one.path) && fm.fileExists(atPath: two.path))
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        rejects { _ = try FolderFileOperations.planMove([source], into: nested) }
        check(try FolderFileOperations.planMove([one], into: source).isEmpty)
        let sub = try write("child.txt", in: nested)
        check(try FolderFileOperations.planMove([nested, sub], into: target).count == 1)
        let link = source.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: one)
        let linkMoves = try FolderFileOperations.planMove([link], into: target)
        try FolderFileOperations.execute(linkMoves)
        check((try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path)) == one.path)
        try FolderFileOperations.undo(linkMoves)
        check(fm.fileExists(atPath: one.path))
        let collision = source.appendingPathComponent("collision")
        _ = try write("collision", in: source)
        try fm.createSymbolicLink(at: target.appendingPathComponent("collision"), withDestinationURL: root.appendingPathComponent("missing"))
        rejects { _ = try FolderFileOperations.planMove([collision], into: target) }
        print("real moves, rollback, no overwrite, self/descendant rejection, symlink preservation: PASS")

        let desktop = try directory("desktop")
        let file = try write("ordinary.txt", in: desktop)
        let originalHidden = try write("already-hidden.txt", in: desktop)
        check(lchflags(originalHidden.path, UInt32(UF_HIDDEN)) == 0)
        let desktopLink = desktop.appendingPathComponent("desktop-link")
        try fm.createSymbolicLink(at: desktopLink, withDestinationURL: one)
        let journal = root.appendingPathComponent("hidden.json")
        var ordinary = Region.defaultNewRegion(frame: region.frame)
        ordinary.displayMode = .list
        ordinary.itemBindings = [file, originalHidden, desktopLink].enumerated().map { RegionItemBinding(path: $0.element.path, slotIndex: $0.offset) }
        let visibility = DesktopItemVisibility(journalURL: journal, desktopURL: desktop)
        try visibility.synchronize(regions: [ordinary])
        defer { try? visibility.restoreAll() }
        check(hidden(file) && hidden(desktopLink) && !hidden(one))
        let renamed = desktop.appendingPathComponent("renamed.txt")
        try fm.moveItem(at: file, to: renamed)
        let recovery = DesktopItemVisibility(journalURL: journal, desktopURL: desktop)
        try recovery.restoreAll()
        check(!hidden(renamed) && !hidden(desktopLink) && hidden(originalHidden) && !hidden(one))
        let replacement = try write("ordinary.txt", in: desktop)
        var replacementRegion = ordinary
        replacementRegion.itemBindings = [RegionItemBinding(path: replacement.path, slotIndex: 0)]
        let manager = DesktopItemVisibility(journalURL: journal, desktopURL: desktop)
        try manager.synchronize(regions: [replacementRegion])
        let journalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: journalDate], ofItemAtPath: journal.path)
        try manager.synchronize(regions: [replacementRegion])
        check((try fm.attributesOfItem(atPath: journal.path)[.modificationDate] as? Date) == journalDate,
            "没有显隐变更时不能重复写恢复日志，阻塞展开和设置操作")
        replacementRegion.displayMode = .icons
        replacementRegion.allowsCollapse = false
        try manager.synchronize(regions: [replacementRegion])
        check(!hidden(replacement))
        replacementRegion.isCollapsed = true
        try manager.synchronize(regions: [replacementRegion])
        check(hidden(replacement))
        try manager.restoreAll()
        check(!hidden(replacement))
        var instantRegion = replacementRegion
        instantRegion.displayMode = .icons
        instantRegion.allowsCollapse = true
        instantRegion.isCollapsed = false
        try manager.synchronize(regions: [instantRegion])
        check(hidden(replacement), "可收起大图标必须由应用持续显示，展开不能等待 Finder 撤销隐藏标记")
        let instantJournal = try Data(contentsOf: journal)
        for _ in 0..<200 {
            instantRegion.isCollapsed.toggle()
            try manager.synchronize(regions: [instantRegion])
            check(hidden(replacement), "连续收展不能翻转 Finder 显隐，造成残留和延迟")
            check((try Data(contentsOf: journal)) == instantJournal)
        }
        try manager.restoreAll()
        check(!hidden(replacement))
        print("list/collapse icon hiding, rename/crash recovery, original flags, symlink targets: PASS")

        let watched = try directory("watched")
        let bookmark = try MappedFolderSession.bookmark(for: watched)
        var observed: [URL] = []
        var lastError: String?
        var callbacks = 0
        let session = MappedFolderSession(path: watched.path, bookmark: bookmark)
        session.onChange = { observed = $0; lastError = $1; callbacks += 1 }
        session.start()
        waitUntil { callbacks > 0 }
        check(lastError == nil && observed.isEmpty)
        let watchedFile = try write("watch.txt", in: watched)
        waitUntil { observed.contains { $0.lastPathComponent == watchedFile.lastPathComponent } }
        let renamedFile = watched.appendingPathComponent("renamed.txt")
        try fm.moveItem(at: watchedFile, to: renamedFile)
        waitUntil { observed.contains { $0.lastPathComponent == renamedFile.lastPathComponent } && !observed.contains { $0.lastPathComponent == watchedFile.lastPathComponent } }
        try fm.removeItem(at: renamedFile)
        waitUntil { observed.isEmpty }
        let movedFolder = root.appendingPathComponent("watched-renamed", isDirectory: true)
        try fm.moveItem(at: watched, to: movedFolder)
        let afterRename = try write("new.txt", in: movedFolder)
        waitUntil { observed.contains { $0.lastPathComponent == afterRename.lastPathComponent } }
        check(lastError == nil)
        try fm.removeItem(at: movedFolder)
        waitUntil { lastError != nil }
        print("authorized bookmarks, live add/rename/delete, folder rename, unavailable folder: PASS")

        var listRegion = ordinary
        listRegion.itemBindings = []
        listRegion.isCollapsed = false
        let controller = RegionWindowController(region: listRegion, editMode: false)
        controller.updateEditInteractionPassthrough(at: NSPoint(x: listRegion.frame.midX, y: listRegion.frame.midY), desktopIconCenters: [], iconSize: 64, isOverControlWindow: false)
        check(!controller.editSurfaceIgnoresMouseEvents)
        listRegion.isCollapsed = true
        controller.update(with: listRegion)
        controller.updateEditInteractionPassthrough(at: NSPoint(x: listRegion.frame.midX, y: listRegion.frame.midY), desktopIconCenters: [], iconSize: 64, isOverControlWindow: false)
        check(controller.editSurfaceIgnoresMouseEvents)
        let collapsedFrame = RegionLayout.visualCollisionFrame(for: listRegion)
        check(collapsedFrame.height <= listRegion.headerHeight + 1 && collapsedFrame.maxY <= listRegion.frame.maxY)
        check(RegionLayout.dropTargetRegion(at: NSPoint(x: listRegion.frame.midX, y: listRegion.frame.midY), in: [listRegion]) == nil)
        controller.updateEditInteractionPassthrough(at: NSPoint(x: collapsedFrame.midX, y: collapsedFrame.midY), desktopIconCenters: [], iconSize: 64, isOverControlWindow: false)
        check(!controller.editSurfaceIgnoresMouseEvents)
        controller.close()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        let files = RegionFilesView(frame: .zero)
        scroll.documentView = files
        files.urls = (0..<120).map { root.appendingPathComponent("file-\($0).txt") }
        files.resizeContent()
        check(files.frame.height > 200)
        files.mode = .list
        check(files.frame.height > 3500)
        print("normal-mode hit testing, collapsed footprint, unlimited grid/list scrolling: PASS")
        var resizeRegion = listRegion
        resizeRegion.isCollapsed = false
        let resizeController = RegionWindowController(region: resizeRegion, editMode: true)
        defer { resizeController.close() }
        let overlay = NSApp.windows.first { $0.isVisible && $0.title == "\(resizeRegion.name) 编辑层" }!
        let hit = overlay.contentView!.hitTest(NSPoint(x: resizeRegion.frame.width - 56, y: 38))
        check(hit is RegionView, "右下角缩放区必须优先命中分区，不能命中文件列表")
        for point in [NSPoint(x: 195, y: 70), NSPoint(x: 230, y: 50), NSPoint(x: 260, y: 8)] {
            check(overlay.contentView!.hitTest(point) is RegionView)
        }
        check(!(overlay.contentView!.hitTest(NSPoint(x: 100, y: 120)) is RegionView), "文件区仍要接收正常点击")
        resizeController.setEditMode(false)
        check(!(overlay.contentView!.hitTest(NSPoint(x: 214, y: 38)) is RegionView), "普通模式不能抢走文件行点击")
        print("enlarged resize handle has priority over file rows: PASS")

        var stillRegion = Region.defaultNewRegion(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        stillRegion.surfaceStyle = .macNative
        let stillView = RegionView(region: stillRegion)
        stillView.frame = stillRegion.frame
        stillView.setAvailableSlots([0, 1, 2])
        func pixels(_ view: NSView) -> Data {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let restingPixels = pixels(stillView)
        stillView.needsDisplay = false
        stillView.setAvailableSlots([0, 1, 2])
        check(!stillView.needsDisplay, "无变化的 Finder 轮询不能反复重绘整块背景")
        stillView.showDropFeedback()
        check(pixels(stillView) == restingPixels, "完成文件落入后不能再闪出骨架或定时高亮")
        stillView.setFinderDragPreview(active: true, hoveredSlotIndex: 0)
        check(pixels(stillView) != restingPixels, "正在拖入时仍需保留放置位置提示")
        stillView.showDropFeedback()
        check(pixels(stillView) == restingPixels, "落入完成必须同步清除拖放预览")
        print("drop completion draws no skeleton or timed flash; active drag still previews slots: PASS")

        var cachedRegion = Region.defaultNewRegion(frame: NSRect(x: -6000, y: -6000, width: 300, height: 400))
        cachedRegion.name = "Immediate visibility regression"
        cachedRegion.itemBindings = [RegionItemBinding(path: replacement.path, slotIndex: 3)]
        var appearanceLoads = 0
        let cachedController = RegionWindowController(region: cachedRegion, editMode: false) { url in
            appearanceLoads += 1
            return RegionFileAppearance.load(url)
        }
        defer { cachedController.close() }
        let cachedOverlay = NSApp.windows.first { $0.isVisible && $0.title == "\(cachedRegion.name) 编辑层" }!
        func findFiles(_ view: NSView) -> RegionFilesView? {
            if let files = view as? RegionFilesView { return files }
            return view.subviews.compactMap { findFiles($0) }.first
        }
        let cachedFiles = findFiles(cachedOverlay.contentView!)!
        let cachedScroll = cachedFiles.enclosingScrollView!
        check(appearanceLoads == 1 && !cachedScroll.isHidden)
        check(cachedController.window?.isVisible == false, "受管理分区只能用一个合成窗口显示背景和图标")
        check(cachedFiles.desktopLayout != nil)
        let slot = RegionLayout.globalSlotCenters(in: cachedRegion)[3]
        let iconRect = cachedFiles.desktopLayout!.iconRect(for: replacement.path)!
        check(abs(iconRect.midX + cachedScroll.frame.minX + cachedRegion.frame.minX - slot.x) < 0.01)
        check(abs(cachedScroll.frame.maxY - iconRect.midY + cachedRegion.frame.minY - slot.y) < 0.01,
            "大图标必须保留原槽位，而不是改成映射文件夹的紧凑网格")
        cachedController.setEditMode(true)
        var moreRequests = 0
        cachedController.onMoreRequested = { id in
            check(id == cachedRegion.id); moreRequests += 1
        }
        let moreButton = cachedOverlay.contentView!.subviews.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "region-more" }!
        check(!moreButton.isHidden && moreButton.frame.width >= 40)
        moreButton.performClick(nil)
        check(moreRequests == 1, "三个点必须是可直接操作的标准按钮，并打开当前分区的面板")
        let controlsWindow = NSWindow(contentRect: cachedRegion.frame,
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        controlsWindow.isReleasedWhenClosed = false
        controlsWindow.level = .normal
        controlsWindow.orderFrontRegardless()
        defer { controlsWindow.close() }
        cachedController.update(with: cachedRegion)
        check(cachedOverlay.level.rawValue < controlsWindow.level.rawValue,
            "编辑中的可见图标层必须低于设置面板，刷新分区后也不能盖住面板")
        let iconHit = cachedFiles.convert(NSPoint(x: iconRect.midX, y: iconRect.midY), to: cachedOverlay.contentView)
        check(cachedOverlay.contentView!.hitTest(iconHit) is RegionFilesView,
            "编辑模式的大图标仍要响应真实文件拖动")
        check(cachedOverlay.contentView!.hitTest(NSPoint(x: 5, y: 150)) is RegionView,
            "大图标之间的空白处必须仍能拖动分区")
        cachedController.setEditMode(false)
        let expandedBitmap = pixels(cachedOverlay.contentView!)
        var longestToggle: TimeInterval = 0
        for _ in 0..<100 {
            cachedRegion.isCollapsed = true
            var start = ProcessInfo.processInfo.systemUptime
            cachedController.update(with: cachedRegion)
            longestToggle = max(longestToggle, ProcessInfo.processInfo.systemUptime - start)
            check(cachedScroll.isHidden, "收起返回前就必须隐藏图标层，不能留残影等 Finder")
            check(pixels(cachedOverlay.contentView!) != expandedBitmap)
            cachedRegion.isCollapsed = false
            start = ProcessInfo.processInfo.systemUptime
            cachedController.update(with: cachedRegion)
            longestToggle = max(longestToggle, ProcessInfo.processInfo.systemUptime - start)
            check(!cachedScroll.isHidden && pixels(cachedOverlay.contentView!) == expandedBitmap,
                "展开返回时就必须有完整图标和文件名，不得排队等待异步加载")
            check(appearanceLoads == 1, "连续收展不得重新读图标或名称")
        }
        print(String(format: "single-window cached icons, original slots, 200 immediate toggles: PASS (max %.2f ms)", longestToggle * 1000))

        var mappedRegion = region
        mappedRegion.name = "Mapped scroll regression"
        mappedRegion.isCollapsed = false
        let mappedController = RegionWindowController(region: mappedRegion, editMode: false)
        defer { mappedController.close() }
        let mappedOverlay = NSApp.windows.first { $0.isVisible && $0.title == "\(mappedRegion.name) 编辑层" }!
        let mappedFiles = findFiles(mappedOverlay.contentView!)!
        mappedController.setFiles((0..<100).map { root.appendingPathComponent("scroll-\($0).txt") })
        mappedFiles.scroll(NSPoint(x: 0, y: 450))
        let scrollOrigin = mappedFiles.enclosingScrollView!.contentView.bounds.origin
        mappedRegion.isCollapsed = true; mappedController.update(with: mappedRegion)
        mappedRegion.isCollapsed = false; mappedController.update(with: mappedRegion)
        check(mappedFiles.enclosingScrollView!.contentView.bounds.origin == scrollOrigin,
            "映射和列表收展必须保留原滚动位置，不能跳回顶部")
        print("mapped/list collapse preserves cached content and scroll position: PASS")
    }
}
