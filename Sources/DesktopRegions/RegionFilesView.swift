// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

struct RegionFileAppearance {
    let icon: NSImage
    let name: String

    static func load(_ url: URL) -> RegionFileAppearance {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: 160, height: 160)
        // Resolve the lazy IconServices representation before the next reveal.
        let icon = source.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .map { NSImage(cgImage: $0, size: NSSize(width: 160, height: 160)) } ?? source
        return RegionFileAppearance(icon: icon, name: FileManager.default.displayName(atPath: url.path))
    }
}

struct BoundDesktopIconLayout: Equatable {
    let centers: [String: NSPoint]
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let textSize: CGFloat

    init(region: Region, viewport: NSRect, metrics: FinderDesktopGridMetrics = .current()) {
        let slots = RegionLayout.globalSlotCenters(in: region)
        centers = Dictionary(region.itemBindings.filter {
            $0.isExplicit && slots.indices.contains($0.slotIndex)
        }.map { binding in
            let center = slots[binding.slotIndex]
            return (binding.path, NSPoint(x: center.x - region.frame.minX - viewport.minX,
                y: viewport.maxY - (center.y - region.frame.minY)))
        }, uniquingKeysWith: { first, _ in first })
        iconSize = metrics.iconSize
        labelWidth = max(iconSize + 12, min(140, region.frame.width / CGFloat(max(1, region.gridColumns))))
        let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        textSize = CGFloat((settings?["IconViewSettings"] as? [String: Any])?["textSize"] as? Double ?? 12)
    }

    func iconRect(for path: String) -> NSRect? {
        guard let c = centers[path] else { return nil }
        return NSRect(x: c.x - iconSize / 2, y: c.y - iconSize / 2, width: iconSize, height: iconSize)
    }

    func textRect(for path: String) -> NSRect? {
        guard let icon = iconRect(for: path) else { return nil }
        return NSRect(x: icon.midX - labelWidth / 2, y: icon.maxY + 8,
            width: labelWidth, height: ceil(textSize * 2.6))
    }
}

final class RegionFileScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let files = documentView as? RegionFilesView, files.editsRegionLayout,
           files.desktopLayout != nil, !files.containsItem(at: files.convert(point, from: superview)) {
            return nil
        }
        return super.hitTest(point)
    }
}

/// Region windows share one desktop selection. Observe both in-app clicks
/// (including headers and edit-mode passthrough) and clicks delivered to other
/// apps, since neither reaches the previously selected file view's mouseDown.
final class RegionFileSelectionCoordinator {
    static let shared = RegionFileSelectionCoordinator()
    private let views = NSHashTable<RegionFilesView>.weakObjects()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?

    private init() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.clearAll()
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.clearAll() }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            self.views.allObjects.filter { $0.window === window }.forEach { $0.clearSelection() }
        }
    }

    func register(_ view: RegionFilesView) { views.add(view) }

    func handleMouseDown(_ event: NSEvent) {
        for view in views.allObjects {
            // Use the actual hit view, not just the frame: a scroller, header,
            // resize handle or another window may own the click at that point.
            if let window = view.window, event.window === window,
               let content = window.contentView,
               let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                    ?? event.locationInWindow),
               hit === view || hit.isDescendant(of: view) {
                continue
            }
            view.clearSelection()
        }
    }

    func clearAll() { views.allObjects.forEach { $0.clearSelection() } }
}

/// The scrollable file surface for mapped folders and ordinary list regions.
/// All drag pasteboard entries are real URLs, so Finder and other apps can
/// open/move the original entry without aliases or copied display files.
final class RegionFilesView: NSView, NSDraggingSource, NSTextFieldDelegate {
    var desktopLayout: BoundDesktopIconLayout? { didSet { if desktopLayout != oldValue { resizeContent() } } }
    var editsRegionLayout = false
    var mode: RegionDisplayMode = .icons { didSet { resizeContent() } }
    var titleColor = NSColor.white { didSet { needsDisplay = true } }
    var urls: [URL] = [] {
        didSet {
            let paths = Set(urls.map(\.path))
            if let renameURL, !paths.contains(renameURL.path) { finishRename(commit: false) }
            selectedPaths.formIntersection(paths)
            if let anchorIndex, oldValue.indices.contains(anchorIndex) {
                self.anchorIndex = urls.firstIndex(of: oldValue[anchorIndex])
                    ?? (selectedPaths.count == 1 ? urls.firstIndex { selectedPaths.contains($0.path) } : nil)
            }
            appearances = appearances.filter { paths.contains($0.key) }
            for url in urls where appearances[url.path] == nil { appearances[url.path] = appearanceLoader(url) }
            resizeContent()
        }
    }
    var sortOptions = RegionFileSort()
    var onSortChanged: ((RegionFileSort) -> Void)?
    var message: String? { didSet { needsDisplay = true } }
    var onFilesDropped: (([URL], NSPoint) -> Void)?
    var onDragStarted: (([URL]) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var exportsBoundDesktopItems = false
    var onRevealRequested: (([URL]) -> Void)?
    var onRevealEnded: (([URL]) -> Void)?
    var onRename: ((URL, String) -> Void)?
    var onDragEnded: (([URL], NSDragOperation) -> Void)?
    var onDropPreview: ((Bool) -> Void)?
    private(set) var selectedPaths = Set<String>()
    private var mouseDownPoint: NSPoint?
    private var pendingNameClick: URL?
    private var renameURL: URL?
    private var renameField: NSTextField?
    private var renameSuffix = ""
    private var draggedURLs: [URL] = []
    private var appearances: [String: RegionFileAppearance] = [:]
    private let appearanceLoader: (URL) -> RegionFileAppearance
    private var contextURL: URL?
    private var anchorIndex: Int?
    private var dropActive = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, appearanceLoader: RegionFileAppearance.load)
    }
    init(frame: NSRect, appearanceLoader: @escaping (URL) -> RegionFileAppearance) {
        self.appearanceLoader = appearanceLoader
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.list)
        setAccessibilityLabel("分区文件")
        RegionFileSelectionCoordinator.shared.register(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clearSelection() {
        finishRename(commit: true)
        anchorIndex = nil
        mouseDownPoint = nil
        pendingNameClick = nil
        guard !selectedPaths.isEmpty else { return }
        selectedPaths.removeAll()
        needsDisplay = true
    }

    func followRename(from source: URL, to destination: URL) {
        if selectedPaths.remove(source.path) != nil { selectedPaths.insert(destination.path) }
        if contextURL?.path == source.path { contextURL = destination }
    }

    private var columns: Int { mode == .list ? 1 : max(1, Int(bounds.width / 104)) }
    private var cellHeight: CGFloat { mode == .list ? 30 : 112 }
    func resizeContent() {
        defer {
            if let renameField, let renameURL, let i = urls.firstIndex(of: renameURL) {
                renameField.frame = renameFrame(at: i)
            }
            needsDisplay = true
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = max(1, clip.bounds.width)
        if desktopLayout != nil {
            let size = NSSize(width: width, height: clip.bounds.height)
            if frame.size != size { setFrameSize(size) }
            return
        }
        let count = mode == .list ? 1 : max(1, Int(width / 104))
        let rows = (urls.count + count - 1) / count
        let size = NSSize(width: width, height: max(clip.bounds.height, CGFloat(rows) * cellHeight + 12))
        if frame.size != size { setFrameSize(size) }
    }

    private func cell(_ index: Int) -> NSRect {
        if let layout = desktopLayout, let icon = layout.iconRect(for: urls[index].path),
           let text = layout.textRect(for: urls[index].path) {
            return icon.insetBy(dx: -5, dy: -5).union(text.insetBy(dx: -4, dy: -1))
        }
        let width = bounds.width / CGFloat(columns)
        return NSRect(x: CGFloat(index % columns) * width + 4,
                      y: CGFloat(index / columns) * cellHeight + 4,
                      width: width - 8, height: cellHeight - 4)
    }

    private func iconRect(at index: Int) -> NSRect {
        if let icon = desktopLayout?.iconRect(for: urls[index].path) { return icon }
        let rect = cell(index)
        return mode == .list
            ? NSRect(x: rect.minX + 6, y: rect.midY - 9, width: 18, height: 18)
            : NSRect(x: rect.midX - 30, y: rect.minY + 4, width: 60, height: 60)
    }

    private func textRect(at index: Int) -> NSRect {
        if let text = desktopLayout?.textRect(for: urls[index].path) { return text }
        let rect = cell(index)
        return mode == .list
            ? NSRect(x: rect.minX + 32, y: rect.midY - 8, width: max(1, rect.width - 38), height: 18)
            : NSRect(x: rect.minX + 2, y: rect.minY + 72, width: rect.width - 4, height: 34)
    }

    private var fileNameFont: NSFont {
        NSFont.systemFont(ofSize: desktopLayout?.textSize ?? (mode == .list ? 12 : 11))
    }

    private var nameParagraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = mode == .list ? .left : .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        return paragraph
    }

    private func nameHighlight(at index: Int, name: NSString) -> NSRect {
        let rect = textRect(at: index)
        let size = name.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: fileNameFont, .paragraphStyle: nameParagraphStyle]).size
        let width = min(rect.width, ceil(size.width))
        return NSRect(x: mode == .list ? rect.minX : rect.midX - width / 2, y: rect.minY,
                      width: width, height: min(rect.height, ceil(size.height))).insetBy(dx: -4, dy: -1)
    }

    private func isNameClick(_ point: NSPoint, at index: Int) -> Bool {
        guard let name = appearances[urls[index].path]?.name else { return false }
        return nameHighlight(at: index, name: name as NSString).contains(point)
    }
    private func index(at point: NSPoint) -> Int? {
        urls.indices.first { cell($0).contains(point) }
    }
    func containsItem(at point: NSPoint) -> Bool { index(at: point) != nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if editsRegionLayout, desktopLayout != nil, index(at: local) == nil { return nil }
        return super.hitTest(point)
    }
    override func draw(_ dirtyRect: NSRect) {
        if urls.isEmpty && desktopLayout == nil {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            ((message ?? "将文件拖入这里") as NSString).draw(
                in: NSRect(x: 12, y: 24, width: bounds.width - 24, height: max(100, bounds.height - 36)),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: titleColor.withAlphaComponent(0.7), .paragraphStyle: paragraph])
        }
        for i in urls.indices {
            let rect = cell(i)
            guard rect.intersects(dirtyRect), !draggedURLs.contains(urls[i]) else { continue }
            let url = urls[i]
            let selected = selectedPaths.contains(url.path)
            guard let appearance = appearances[url.path] else { continue }
            let iconRect = iconRect(at: i)
            if selected {
                let accent = NSColor.controlAccentColor
                if mode == .list {
                    accent.withAlphaComponent(0.65).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                } else {
                    let plate = NSBezierPath(roundedRect: iconRect.insetBy(dx: -4, dy: -4), xRadius: 9, yRadius: 9)
                    accent.withAlphaComponent(0.22).setFill()
                    plate.fill()
                    accent.withAlphaComponent(0.70).setStroke()
                    plate.lineWidth = 2
                    plate.stroke()
                    if renameURL?.path != url.path {
                        accent.setFill()
                        NSBezierPath(roundedRect: nameHighlight(at: i, name: appearance.name as NSString),
                                     xRadius: 5, yRadius: 5).fill()
                    }
                }
            }
            appearance.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            guard renameURL?.path != url.path else { continue }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: fileNameFont,
                .foregroundColor: selected || desktopLayout != nil ? NSColor.white : titleColor,
                .paragraphStyle: nameParagraphStyle]
            if desktopLayout != nil && !selected {
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
                attributes[.shadow] = shadow
            }
            (appearance.name as NSString).draw(in: textRect(at: i), withAttributes: attributes)
        }
        if dropActive {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(roundedRect: visibleRect.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        finishRename(commit: true)
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        pendingNameClick = nil
        guard let i = index(at: point) else {
            clearSelection(); return
        }
        if event.clickCount == 1, onRename != nil, selectedPaths == [urls[i].path],
           event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
           isNameClick(point, at: i) {
            pendingNameClick = urls[i]
        }
        if event.modifierFlags.contains(.shift), let anchor = anchorIndex {
            for j in min(anchor, i)...max(anchor, i) where urls.indices.contains(j) { selectedPaths.insert(urls[j].path) }
        } else if event.modifierFlags.contains(.command) {
            if !selectedPaths.insert(urls[i].path).inserted { selectedPaths.remove(urls[i].path) }
            anchorIndex = i
        } else if !selectedPaths.contains(urls[i].path) {
            selectedPaths = [urls[i].path]
            anchorIndex = i
        }
        needsDisplay = true
        if event.clickCount == 2 { NSWorkspace.shared.open(urls[i]) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pendingNameClick = nil; mouseDownPoint = nil }
        guard let url = pendingNameClick, let index = urls.firstIndex(of: url),
              isNameClick(convert(event.locationInWindow, from: nil), at: index) else { return }
        beginRename(url)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        pendingNameClick = nil
        draggedURLs = urls.filter { selectedPaths.contains($0.path) }
        guard !draggedURLs.isEmpty else { return }
        onDragStarted?(draggedURLs)
        needsDisplay = true
        let items = draggedURLs.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                                  contents: appearances[url.path]?.icon)
            return item
        }
        mouseDownPoint = nil
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move] }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Hit testing follows the pointer, independent of the drag image's offset.
        onDragMoved?(NSEvent.mouseLocation)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(draggedURLs, operation)
        draggedURLs = []
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            selectedPaths = Set(urls.map(\.path)); needsDisplay = true
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls.filter { selectedPaths.contains($0.path) }.map { $0 as NSURL })
        } else if event.keyCode == 36 {
            urls.filter { selectedPaths.contains($0.path) }.forEach { NSWorkspace.shared.open($0) }
        } else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let i = index(at: convert(event.locationInWindow, from: nil)) {
            let url = urls[i]
            contextURL = url
            menu.addItem(withTitle: "打开", action: #selector(openContext), keyEquivalent: "").target = self
            if let openWith = openWithMenu(for: url) { menu.addItem(openWith) }
            if onRename != nil {
                menu.addItem(withTitle: "重新命名", action: #selector(renameContext), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "拷贝", action: #selector(copyContext), keyEquivalent: "").target = self
            if #available(macOS 13.0, *) {
                menu.addItem(NSSharingServicePicker(items: [url]).standardShareMenuItem)
            }
            menu.addItem(withTitle: "在访达中显示", action: #selector(revealContext), keyEquivalent: "").target = self
            menu.addItem(.separator())
        } else { contextURL = nil }
        if desktopLayout == nil {
            let sort = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
            sort.submenu = RegionSortMenu.make(options: sortOptions) { [weak self] in self?.onSortChanged?($0) }
            menu.addItem(sort)
        }
        return menu.items.isEmpty ? nil : menu
    }
    private func openWithMenu(for url: URL) -> NSMenuItem? {
        guard url.pathExtension.lowercased() != "app" else { return nil }
        let workspace = NSWorkspace.shared
        let applications = workspace.urlsForApplications(toOpen: url)
        guard !applications.isEmpty else { return nil }
        let defaultApplication = workspace.urlForApplication(toOpen: url)
        let submenu = NSMenu()
        for app in applications {
            let name = FileManager.default.displayName(atPath: app.path)
            let item = submenu.addItem(withTitle: app == defaultApplication ? "\(name)（默认）" : name,
                                       action: #selector(openWithContext(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
        }
        let item = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func openWithContext(_ item: NSMenuItem) {
        guard let url = contextURL, let app = item.representedObject as? URL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openContext() { if let url = contextURL { NSWorkspace.shared.open(url) } }
    @objc private func renameContext() { if let url = contextURL { beginRename(url) } }
    @objc private func copyContext() {
        guard let url = contextURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    private func renameFrame(at index: Int) -> NSRect {
        let rect = textRect(at: index)
        return NSRect(x: rect.minX, y: rect.minY - 2, width: rect.width,
                      height: ceil(fileNameFont.ascender - fileNameFont.descender) + 7).intersection(bounds)
    }

    private func beginRename(_ url: URL) {
        guard onRename != nil, let window, let index = urls.firstIndex(of: url) else { return }
        guard renameURL != url else { return }
        finishRename(commit: true)
        selectedPaths = [url.path]
        anchorIndex = index

        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let label = appearances[url.path]?.name ?? name
        // Finder aliases can show the extension even when their metadata hides it.
        let hidesExtension = !label.hasSuffix(suffix) && (label == stem ||
            (try? url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension) == true)
        renameSuffix = hidesExtension ? suffix : ""
        let field = NSTextField(frame: renameFrame(at: index))
        field.font = fileNameFont
        field.alignment = mode == .list ? .left : .center
        field.usesSingleLineMode = true
        field.isEditable = true
        field.isSelectable = true
        field.stringValue = renameSuffix.isEmpty ? name : stem
        field.setAccessibilityLabel("重新命名")
        field.delegate = self
        renameURL = url
        renameField = field
        addSubview(field)
        scrollToVisible(field.frame)
        window.makeKey()
        if window.makeFirstResponder(field) {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        } else {
            finishRename(commit: false)
        }
        needsDisplay = true
    }

    private func finishRename(commit: Bool) {
        guard let field = renameField, let url = renameURL else { return }
        let name = (field.currentEditor()?.string ?? field.stringValue) + renameSuffix
        renameField = nil
        renameURL = nil
        field.delegate = nil
        if field.currentEditor() != nil { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        needsDisplay = true
        if commit, name != url.lastPathComponent { onRename?(url, name) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.insertNewline(_:)) {
            finishRename(commit: true)
        } else if command == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(commit: false)
        } else { return false }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = renameField, notification.object as? NSTextField === field else { return }
        finishRename(commit: true)
    }
    @objc private func revealContext() {
        if let url = contextURL {
            onRevealRequested?([url])
            NSWorkspace.shared.activateFileViewerSelecting([url])
            // Restore ordinary list ownership after Finder has selected it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.onRevealEnded?([url]) }
        }
    }

    private func accepts(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              sender.draggingSourceOperationMask.contains(.move) else { return [] }
        dropActive = true; onDropPreview?(true); needsDisplay = true
        return .move
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { accepts(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let event = NSApp.currentEvent { autoscroll(with: event) }
        return accepts(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearDrop() }
    private func clearDrop() { dropActive = false; onDropPreview?(false); needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDrop() }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onFilesDropped?(urls, sender.draggingLocation)
        return true
    }
}
