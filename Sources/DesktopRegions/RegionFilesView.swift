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
        return NSRect(x: icon.midX - labelWidth / 2, y: icon.maxY + 5,
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
               content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                    ?? event.locationInWindow) === view {
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
final class RegionFilesView: NSView, NSDraggingSource {
    var desktopLayout: BoundDesktopIconLayout? { didSet { if desktopLayout != oldValue { resizeContent() } } }
    var editsRegionLayout = false
    var mode: RegionDisplayMode = .icons { didSet { resizeContent() } }
    var titleColor = NSColor.white { didSet { needsDisplay = true } }
    var urls: [URL] = [] {
        didSet {
            selectedPaths.formIntersection(Set(urls.map(\.path)))
            let paths = Set(urls.map(\.path))
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
    var onRevealRequested: (([URL]) -> Void)?
    var onDragEnded: (([URL], NSDragOperation) -> Void)?
    var onDropPreview: ((Bool) -> Void)?
    private(set) var selectedPaths = Set<String>()
    private var mouseDownPoint: NSPoint?
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
        anchorIndex = nil
        mouseDownPoint = nil
        guard !selectedPaths.isEmpty else { return }
        selectedPaths.removeAll()
        needsDisplay = true
    }

    private var columns: Int { mode == .list ? 1 : max(1, Int(bounds.width / 104)) }
    private var cellHeight: CGFloat { mode == .list ? 30 : 112 }
    func resizeContent() {
        guard let clip = enclosingScrollView?.contentView else { needsDisplay = true; return }
        let width = max(1, clip.bounds.width)
        if desktopLayout != nil {
            let size = NSSize(width: width, height: clip.bounds.height)
            if frame.size != size { setFrameSize(size) }
            needsDisplay = true
            return
        }
        let count = mode == .list ? 1 : max(1, Int(width / 104))
        let rows = (urls.count + count - 1) / count
        let size = NSSize(width: width, height: max(clip.bounds.height, CGFloat(rows) * cellHeight + 12))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    private func cell(_ index: Int) -> NSRect {
        if let layout = desktopLayout, let icon = layout.iconRect(for: urls[index].path),
           let text = layout.textRect(for: urls[index].path) {
            return icon.union(text).insetBy(dx: -3, dy: -3)
        }
        let width = bounds.width / CGFloat(columns)
        return NSRect(x: CGFloat(index % columns) * width + 4,
                      y: CGFloat(index / columns) * cellHeight + 4,
                      width: width - 8, height: cellHeight - 4)
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
            guard rect.intersects(dirtyRect) else { continue }
            let url = urls[i]
            let selected = selectedPaths.contains(url.path)
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.65).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            }
            guard let appearance = appearances[url.path] else { continue }
            let iconRect = desktopLayout?.iconRect(for: url.path) ?? (mode == .list
                ? NSRect(x: rect.minX + 6, y: rect.midY - 9, width: 18, height: 18)
                : NSRect(x: rect.midX - 30, y: rect.minY + 4, width: 60, height: 60))
            appearance.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = mode == .list ? .left : .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            let textRect = desktopLayout?.textRect(for: url.path) ?? (mode == .list
                ? NSRect(x: rect.minX + 32, y: rect.midY - 8, width: max(1, rect.width - 38), height: 18)
                : NSRect(x: rect.minX + 2, y: rect.minY + 69, width: rect.width - 4, height: 34))
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: desktopLayout?.textSize ?? (mode == .list ? 12 : 11)),
                .foregroundColor: selected || desktopLayout != nil ? NSColor.white : titleColor, .paragraphStyle: paragraph]
            if desktopLayout != nil {
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
                attributes[.shadow] = shadow
            }
            (appearance.name as NSString).draw(in: textRect, withAttributes: attributes)
        }
        if dropActive {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(roundedRect: visibleRect.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        guard let i = index(at: mouseDownPoint!) else {
            clearSelection(); return
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

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        draggedURLs = urls.filter { selectedPaths.contains($0.path) }
        guard !draggedURLs.isEmpty else { return }
        onDragStarted?(draggedURLs)
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
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(draggedURLs, operation)
        draggedURLs = []
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
            contextURL = urls[i]
            menu.addItem(withTitle: "打开", action: #selector(openContext), keyEquivalent: "").target = self
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
    @objc private func openContext() { if let url = contextURL { NSWorkspace.shared.open(url) } }
    @objc private func revealContext() {
        if let url = contextURL {
            onRevealRequested?([url])
            NSWorkspace.shared.activateFileViewerSelecting([url])
            // Restore ordinary list ownership after Finder has selected it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.onDragEnded?([url], []) }
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
