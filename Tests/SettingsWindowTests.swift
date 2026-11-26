// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

@main
struct SettingsWindowTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RegionStore(fileURL: root.appendingPathComponent("regions.json"))
        let frame = NSRect(x: 100, y: 100, width: 400, height: 500)
        let region = Region.defaultNewRegion(frame: frame)
        var listRegion = region.duplicated(name: "列表", frame: frame)
        listRegion.displayMode = .list
        let extraRegions = (0..<10).map { region.duplicated(name: "分区 \($0)", frame: frame) }
        store.replace(with: [region, listRegion] + extraRegions)

        let delegate = AppDelegate(store: store)
        let settings = SettingsWindowController(appDelegate: delegate)
        settings.refresh()
        let main = settings.window!
        let table = descendants(of: main.contentView!).compactMap { $0 as? NSScrollView }.first!
        table.scrollerStyle = .legacy
        check(main.styleMask.contains(.resizable), "main settings has native resize handles")
        main.setContentSize(NSSize(width: 1100, height: 650))
        let fullTableHeight = table.contentSize.height
        main.setContentSize(main.contentMinSize)
        main.contentView!.layoutSubtreeIfNeeded()
        check(table.contentSize.height < fullTableHeight, "table viewport follows the window height")
        check(table.documentView!.bounds.height > table.contentSize.height, "extra rows still scroll")
        let row = descendants(of: table.documentView!).compactMap { $0 as? RegionRowView }.first!
        let moreButton = row.subviews.compactMap { $0 as? NSButton }.last!
        check(row.bounds.width == table.contentSize.width && moreButton.frame.maxX <= row.bounds.width,
              "rows and the rightmost control fit with the legacy scroller")
        let narrowSize = main.frame.size
        settings.showWindow(nil)
        settings.collapseToEdge()
        settings.expandFromEdge()
        check(main.frame.size == narrowSize, "edge tab restores the resized settings window")

        settings.showAdvancedSettings(for: region.id)
        let editor = NSApp.windows.first { $0.title == "\(region.name) · 更多设置" }!
        let form = editor.contentView as! NSScrollView
        form.scrollerStyle = .legacy
        check(editor.styleMask.contains(.resizable), "per-region settings has native resize handles")
        editor.setContentSize(editor.contentMinSize)
        form.layoutSubtreeIfNeeded()
        let document = form.documentView!
        check(document.bounds.width == form.contentSize.width, "form width follows the viewport")
        check(document.bounds.height > form.contentSize.height, "short window scrolls the full form")
        let controls = descendants(of: document)
        let title = controls.compactMap { $0 as? NSTextField }.first { $0.stringValue == "分区外观与网格" }!
        let reset = controls.compactMap { $0 as? NSButton }.first { $0.title == "恢复默认参数" }!
        let slider = controls.compactMap { $0 as? NSSlider }.first!
        let popup = controls.compactMap { $0 as? NSPopUpButton }.first!
        let popupFrame = popup.convert(popup.bounds, to: document)
        check(popupFrame.width >= 180 && document.bounds.contains(popupFrame), "fixed-width controls fit the narrow form")
        check(document.visibleRect.contains(title.convert(title.bounds, to: document)), "form opens at the top")
        let narrowSliderWidth = slider.bounds.width
        check(narrowSliderWidth >= 110, "narrow window leaves usable slider width")
        form.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - form.contentSize.height))
        form.reflectScrolledClipView(form.contentView)
        check(document.visibleRect.contains(reset.convert(reset.bounds, to: document)), "bottom button is fully reachable")
        editor.setContentSize(NSSize(width: 640, height: 460))
        form.layoutSubtreeIfNeeded()
        check(slider.bounds.width > narrowSliderWidth, "form controls expand as the window widens")

        settings.showAdvancedSettings(for: listRegion.id)
        let listEditor = NSApp.windows.first { $0.title == "列表 · 更多设置" }!
        check(listEditor.frame.size == editor.frame.size, "advanced window retains the chosen size across regions")
        let listLabels = descendants(of: listEditor.contentView!).compactMap { $0 as? NSTextField }
        check(listLabels.contains { $0.stringValue == "文件排序" && !$0.isHiddenOrHasHiddenAncestor },
              "list regions still show file sorting")
        listEditor.setContentSize(NSSize(width: 540, height: 380))
        settings.showAdvancedSettings(for: extraRegions[0].id)
        let reopened = NSApp.windows.first { $0.title == "\(extraRegions[0].name) · 更多设置" }!
        check(reopened.frame.size == listEditor.frame.size, "the next resize is saved after switching regions")

        try verifyGridOverflow(in: root)
        print("Settings window resize, grid overflow and drop tests passed.")
    }

    private static func verifyGridOverflow(in root: URL) throws {
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let layoutURL = root.appendingPathComponent("grid.json")
        let journalURL = root.appendingPathComponent("grid-hidden.json")
        let store = RegionStore(fileURL: layoutURL)
        let visibility = DesktopItemVisibility(journalURL: journalURL, desktopURL: desktop)
        var region = Region.defaultNewRegion(frame: NSRect(x: 100, y: 100, width: 400, height: 500))
        region.gridRows = 4
        for index in 0..<8 {
            let url = desktop.appendingPathComponent(index == 7 ? "CC Switch" : "App \(index)")
            try Data().write(to: url)
            region.itemBindings.append(RegionItemBinding(path: url.path, slotIndex: index))
        }
        store.replace(with: [region])
        try visibility.synchronize(regions: [region])
        let originalLayout = try Data(contentsOf: layoutURL)
        let originalJournal = try Data(contentsOf: journalURL)

        var acceptsOverflow = false
        var prompts: [(String, String)] = []
        let delegate = AppDelegate(store: store, desktopVisibility: visibility) { title, message in
            prompts.append((title, message))
            return acceptsOverflow
        }
        delegate.openAdvancedSettings(for: region.id)
        let editor = NSApp.windows.first { $0.title == "\(region.name) · 更多设置" && $0.isVisible }!
        let controls = descendants(of: editor.contentView!)
        let rows = controls.compactMap { $0 as? NSStepper }.first { $0.action == NSSelectorFromString("rowsChanged") }!
        let reset = controls.compactMap { $0 as? NSButton }.first { $0.title == "恢复默认参数" }!

        rows.integerValue = 3
        rows.sendAction(rows.action, to: rows.target)
        check(store.region(id: region.id) == region, "changing 2×4 to 2×3 must preserve all eight bindings and the old frame")
        check(rows.integerValue == 4, "rejected row stepper returns to the saved value")
        check(prompts.count == 1 && prompts[0].0.contains("2 个项目") && prompts[0].1.contains("6 个项目"),
              "the warning explains how many items will remain visible and how many will scroll")

        reset.sendAction(reset.action, to: reset.target)
        check(store.region(id: region.id) == region, "resetting to the default 2×3 grid must reject the entire change")
        let savedLayout = try Data(contentsOf: layoutURL)
        let savedJournal = try Data(contentsOf: journalURL)
        check(savedLayout == originalLayout && savedJournal == originalJournal,
              "rejected changes never rewrite the saved region or visibility journal")
        var info = stat()
        check(lstat(region.itemBindings[7].path, &info) == 0 && (info.st_flags & UInt32(UF_HIDDEN)) != 0,
              "the last bound icon stays in the region and Finder keeps its original hidden")

        acceptsOverflow = true
        rows.integerValue = 3
        rows.sendAction(rows.action, to: rows.target)
        let resized = store.region(id: region.id)!
        check(resized.gridRows == 3 && resized.gridColumns == 2 && resized.hasGridOverflow,
              "confirming a shrink keeps two columns and extends the three visible rows")
        check(resized.itemBindings == region.itemBindings && RegionStore(fileURL: layoutURL).region(id: region.id) == resized,
              "all eight items and their extension persist after reloading the saved layout")

        var scrolling = resized
        scrolling.name = "Overflow scrolling"
        scrolling.setFrame(resized.frame.offsetBy(dx: -6000, dy: -6000))
        let controller = RegionWindowController(region: scrolling, editMode: false)
        defer { controller.close() }
        let overlay = NSApp.windows.first { $0.title == "\(scrolling.name) 编辑层" }!
        let scroll = overlay.contentView!.subviews.compactMap { $0 as? RegionFileScrollView }.first!
        let files = scroll.documentView as! RegionFilesView
        let desktopLayout = files.desktopLayout!
        let centers = region.itemBindings.map { desktopLayout.centers[$0.path]! }
        let visible = scroll.contentView.bounds
        check(scroll.hasVerticalScroller && centers.indices.filter { visible.contains(centers[$0]) } == Array(0..<6),
              "the viewport shows exactly six of the eight bound icons")
        check(centers[6].x == centers[0].x && centers[7].x == centers[1].x && centers[6].y == centers[7].y,
              "the extension uses the same columns and a new row")
        files.scroll(NSPoint(x: 0, y: files.bounds.height - visible.height))
        check(scroll.contentView.bounds.contains(centers[6]) && scroll.contentView.bounds.contains(centers[7]),
              "scrolling reaches both extra icons")

        var filled = resized
        filled.itemBindings = Array(resized.itemBindings.prefix(6))
        filled.allowsGridOverflow = false
        filled.allowsCollapse = false
        store.update(filled)
        let incoming = [desktop.appendingPathComponent("Next App"), desktop.appendingPathComponent("Another App")]
        for url in incoming { try Data().write(to: url) }
        let point = NSPoint(x: filled.frame.midX, y: filled.frame.midY)
        acceptsOverflow = false
        check(!delegate.filesDropped(incoming, into: filled.id, near: point, folder: nil) &&
              store.region(id: filled.id) == filled && incoming.allSatisfy {
                  FileManager.default.fileExists(atPath: $0.path)
              }, "declining a drop into a full partition preserves the partition and the sources")
        check(prompts.last?.0.contains("可见位置已满") == true && prompts.last?.1.contains("2 个项目") == true,
              "the full-drop alert explains that both incoming items will be below the visible grid")
        acceptsOverflow = true
        check(delegate.filesDropped(incoming, into: filled.id, near: point, folder: nil),
              "confirming a drop enables scrolling even for a partition using native Finder icons")
        let withDrop = store.region(id: filled.id)!
        check(withDrop.itemBindings.suffix(2).map(\.slotIndex) == [6, 7] &&
              withDrop.itemBindings.suffix(2).map(\.path) == incoming.map(\.path) &&
              withDrop.gridCapacity == 6 && withDrop.rendersBoundIcons,
              "both new items append to the extension without changing the visible grid")
        acceptsOverflow = false
        let promptsAfterDrop = prompts.count
        check(delegate.filesDropped(incoming, into: filled.id, near: point, folder: nil) &&
              prompts.count == promptsAfterDrop && store.region(id: filled.id) == withDrop,
              "moving the same items within the extension does not prompt again")

        var sparse = store.region(id: region.id)!
        sparse.gridRows = 4
        sparse.itemBindings = [region.itemBindings[0], region.itemBindings[7]]
        store.update(sparse)
        let promptCount = prompts.count
        rows.integerValue = 3
        rows.sendAction(rows.action, to: rows.target)
        let compact = store.region(id: region.id)!
        check(compact.gridRows == 3 && compact.itemBindings.map(\.path) == sparse.itemBindings.map(\.path) &&
              compact.itemBindings.map(\.slotIndex) == [0, 1] && prompts.count == promptCount,
              "a shrink with sufficient capacity relocates a sparse binding without asking")
        store.update(resized)
        let shortFrame = NSRect(x: resized.frame.minX, y: resized.frame.maxY - 240,
                                width: resized.frame.width, height: 240)
        acceptsOverflow = false
        delegate.regionFrameChanged(id: resized.id, frame: shortFrame)
        check(store.region(id: resized.id) == resized, "declining a manual shrink preserves the frame and grid")
        acceptsOverflow = true
        delegate.regionFrameChanged(id: resized.id, frame: shortFrame)
        check(store.region(id: resized.id)?.frame == shortFrame &&
              store.region(id: resized.id)?.gridColumns == 2 && store.region(id: resized.id)?.gridRows == 2 &&
              store.region(id: resized.id)?.itemBindings == resized.itemBindings,
              "a confirmed manual shrink reduces visible rows and preserves all items and columns")
        delegate.regionFrameChanged(id: resized.id, frame: resized.frame)
        check(store.region(id: resized.id)?.gridRows == 4 && store.region(id: resized.id)?.hasGridOverflow == false,
              "growing the partition makes the rows visible again")
        editor.close()
        delegate.settingsWindow?.close()
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
