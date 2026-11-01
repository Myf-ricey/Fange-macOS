// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

/// A bound icon is already a Desktop entry. Dropping its URL back into the
/// same directory is not a filesystem move, so Finder is not the receiver for
/// this operation. Accept it explicitly instead of interpreting a failed or
/// cancelled NSDraggingSession as a successful release.
final class DesktopDropController {
    var acceptsPoint: (NSPoint) -> Bool = { _ in false }
    var onDrop: ([URL], NSPoint) -> Bool = { _, _ in false }
    private(set) var activePaths = Set<String>()
    private(set) var windows: [NSWindow] = []

    func begin(urls: [URL]) {
        end()
        activePaths = Set(urls.map { $0.standardizedFileURL.path })
        for screen in NSScreen.screens {
            let window = UnconstrainedRegionWindow(contentRect: screen.visibleFrame,
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.hasShadow = false
            window.backgroundColor = NSColor.white.withAlphaComponent(0.005)
            // Stay above Finder even if it reorders its desktop during a drag.
            // At the back of this level, region surfaces remain above us;
            // ordinary application windows keep their own drop destinations.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.title = "饭格桌面拖放接收层"
            let view = DesktopDropView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.005).cgColor
            view.controller = self
            window.contentView = view
            window.ignoresMouseEvents = true
            windows.append(window)
            window.orderBack(nil)
        }
        update(at: NSEvent.mouseLocation)
    }

    func update(at point: NSPoint) {
        for window in windows {
            // Leave Finder folders/icons and every region to their own target.
            window.ignoresMouseEvents = !window.frame.contains(point) || !acceptsPoint(point)
        }
    }

    func end() {
        windows.forEach { $0.close() }
        windows.removeAll()
        activePaths.removeAll()
    }

    func accepts(urls: [URL], at point: NSPoint, source: Any?, operation: NSDragOperation) -> Bool {
        guard let source = source as? RegionFilesView, source.exportsBoundDesktopItems,
              operation.contains(.move), !urls.isEmpty, acceptsPoint(point) else { return false }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.standardizedFileURL
        return urls.allSatisfy {
            $0.standardizedFileURL.deletingLastPathComponent() == desktop &&
                activePaths.contains($0.standardizedFileURL.path)
        }
    }
}

final class DesktopDropView: NSView {
    weak var controller: DesktopDropController?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func payload(_ sender: NSDraggingInfo) -> ([URL], NSPoint)? {
        guard let window, let controller,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return nil }
        let point = window.convertPoint(toScreen: sender.draggingLocation)
        guard controller.accepts(urls: urls, at: point, source: sender.draggingSource,
                                 operation: sender.draggingSourceOperationMask) else { return nil }
        return (urls, point)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return payload(sender) == nil ? [] : .move
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return payload(sender) != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (urls, point) = payload(sender) else { return false }
        return controller?.onDrop(urls, point) ?? false
    }
}
