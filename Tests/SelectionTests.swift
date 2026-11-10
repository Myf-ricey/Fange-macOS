// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

@main
struct SelectionTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        func surface() -> (NSWindow, RegionFilesView) {
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = RegionFilesView(frame: NSRect(x: 0, y: 0, width: 320, height: 400)) {
                RegionFileAppearance(icon: icon, name: $0.lastPathComponent)
            }
            view.urls = (0..<4).map { URL(fileURLWithPath: "/tmp/selection-\($0).app") }
            window.contentView = view
            return (window, view)
        }
        let (firstWindow, first) = surface()
        let (secondWindow, second) = surface()
        func mouse(_ type: NSEvent.EventType, in view: RegionFilesView, at point: NSPoint,
                   modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type,
                location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func click(_ view: RegionFilesView, point: NSPoint = NSPoint(x: 45, y: 40),
                   modifiers: NSEvent.ModifierFlags = []) {
            let event = mouse(.leftMouseDown, in: view, at: point, modifiers: modifiers)
            app.sendEvent(event)
            view.mouseDown(with: event)
            view.mouseUp(with: mouse(.leftMouseUp, in: view, at: point, modifiers: modifiers))
        }
        click(first)
        precondition(first.selectedPaths == [first.urls[0].path], "点击必须选中文件")
        click(second)
        precondition(first.selectedPaths.isEmpty, "点击其他分区必须清除旧分区的蓝色选中")
        precondition(second.selectedPaths == [second.urls[0].path], "新分区必须正常选中")
        click(second, point: NSPoint(x: 150, y: 40), modifiers: .command)
        precondition(second.selectedPaths.count == 2, "Command 多选不能被清除")
        click(second, point: NSPoint(x: 250, y: 40), modifiers: .shift)
        precondition(second.selectedPaths.count == 3, "Shift 范围选择不能被清除")
        click(second, point: NSPoint(x: 200, y: 350))
        precondition(second.selectedPaths.isEmpty, "点击本分区空白必须清除选中")
        click(first)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        precondition(first.selectedPaths.isEmpty, "切换到打开的应用后必须清除蓝色选中")
        click(first)
        // Headers and controls are siblings of the file surface in a real region.
        let sibling = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        firstWindow.contentView = sibling
        sibling.addSubview(first)
        first.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        let headerEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 350),
            modifierFlags: [], timestamp: 0, windowNumber: firstWindow.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        app.sendEvent(headerEvent)
        precondition(first.selectedPaths.isEmpty, "点击同窗口的标题空白也必须清除选中")
        click(first)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: firstWindow)
        precondition(first.selectedPaths.isEmpty, "窗口失焦必须清除选中")
        click(first)
        RegionFileSelectionCoordinator.shared.clearAll()
        precondition(first.selectedPaths.isEmpty && second.selectedPaths.isEmpty,
                     "外部鼠标点击的全局清除入口必须清除所有分区")

        // Exercise the original layout too: cached bound icons inside a
        // scroll view, with blank edit-mode hits routed to the parent region.
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! Data().write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        var region = Region.defaultNewRegion(frame: NSRect(x: -6000, y: -6000, width: 400, height: 500))
        region.name = "Selection lifecycle regression"
        region.itemBindings = [RegionItemBinding(path: fixture.path, slotIndex: 0)]
        let controller = RegionWindowController(region: region, editMode: true) {
            RegionFileAppearance(icon: icon, name: $0.lastPathComponent)
        }
        defer { controller.close() }
        let overlay = app.windows.first { $0.title == "\(region.name) 编辑层" }!
        func findFiles(_ view: NSView) -> RegionFilesView? {
            if let files = view as? RegionFilesView { return files }
            return view.subviews.compactMap { findFiles($0) }.first
        }
        let boundFiles = findFiles(overlay.contentView!)!
        let iconRect = boundFiles.desktopLayout!.iconRect(for: fixture.path)!
        let boundClick = NSEvent.mouseEvent(with: .leftMouseDown,
            location: boundFiles.convert(NSPoint(x: iconRect.midX, y: iconRect.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: overlay.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        app.sendEvent(boundClick)
        precondition(boundFiles.selectedPaths == [fixture.path], "真实分区图标必须能选中")
        let blankClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 150),
            modifierFlags: [], timestamp: 0, windowNumber: overlay.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        app.sendEvent(blankClick)
        precondition(boundFiles.selectedPaths.isEmpty, "编辑空白透传到父视图时也必须清除蓝块")

        let renameAlias = fixture.appendingPathExtension("app")
        try! URL.writeBookmarkData(fixture.bookmarkData(options: .suitableForBookmarkFile), to: renameAlias)
        defer { try? FileManager.default.removeItem(at: renameAlias) }
        var aliasWithMetadata = renameAlias
        var metadata = URLResourceValues()
        metadata.hasHiddenExtension = true
        try! aliasWithMetadata.setResourceValues(metadata)
        first.urls[0] = renameAlias
        var submittedNames: [String] = []
        first.onRename = { url, name in
            precondition(url == first.urls[0])
            submittedNames.append(name)
        }
        func renameField() -> NSTextField? {
            first.subviews.compactMap { $0 as? NSTextField }.first
        }
        let namePoint = NSPoint(x: 53, y: 82)
        click(first, point: namePoint)
        precondition(renameField() == nil, "第一次点击名字只选中")
        click(first, point: NSPoint(x: 53, y: 40))
        precondition(renameField() == nil, "再次点击图标不应进入编辑")
        click(first, point: namePoint, modifiers: .shift)
        precondition(renameField() == nil, "组合键选择不应进入编辑")
        click(first, point: namePoint)
        let nameEditor = renameField()!.currentEditor() as! NSTextView
        precondition(nameEditor.string == renameAlias.lastPathComponent, "标签显示的 .app 后缀也要保留在编辑框")
        precondition(nameEditor.selectedRange.length == fixture.lastPathComponent.count, "默认只选中文件名主体")
        nameEditor.string = "新名称.app"
        nameEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(renameField() == nil && submittedNames == ["新名称.app"], "回车提交一次")

        let menu = first.menu(for: mouse(.rightMouseDown, in: first, at: NSPoint(x: 53, y: 40)))!
        let rename = menu.item(withTitle: "重新命名")!
        precondition(app.sendAction(rename.action!, to: rename.target, from: rename))
        let menuEditor = renameField()!.currentEditor() as! NSTextView
        menuEditor.string = "不提交.app"
        menuEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        precondition(renameField() == nil && submittedNames.count == 1, "Esc 取消右键重命名")

        precondition(app.sendAction(rename.action!, to: rename.target, from: rename))
        renameField()!.currentEditor()!.string = "点击空白保存.app"
        click(first, point: NSPoint(x: 150, y: 285))
        precondition(renameField() == nil && submittedNames == ["新名称.app", "点击空白保存.app"], "点空白也必须提交一次")

        let destination = URL(fileURLWithPath: "/tmp/新名称.app")
        click(first)
        first.followRename(from: first.urls[0], to: destination)
        first.urls[0] = destination
        precondition(first.selectedPaths == [destination.path], "刷新后仍选中新路径")
        withExtendedLifetime((firstWindow, secondWindow)) {}
        print("file selection lifecycle and inline rename: PASS")
    }
}
