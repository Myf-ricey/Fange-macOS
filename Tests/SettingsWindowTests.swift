// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

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
        print("Settings window resize tests passed.")
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
