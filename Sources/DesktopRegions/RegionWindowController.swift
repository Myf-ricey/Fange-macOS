// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

final class RegionWindowController: NSWindowController, NSWindowDelegate {
    private(set) var region: Region
    private let regionView: RegionView
    private let interactionView: RegionView
    private let interactionWindow: RegionInteractionWindow
    private let containerView: NSView
    private let visualEffectView: NSVisualEffectView
    private let fileScrollView = RegionFileScrollView()
    private let filesView: RegionFilesView
    private var loadedBindings: [RegionItemBinding]?
    private var loadedSort: RegionFileSort?
    private var loadedDisplayMode: RegionDisplayMode?
    private let collapseButton = NSButton()
    private let moreButton = NSButton()
    private var currentEditMode = false
    private var applyingModelFrame = false
    private var snapPreviewWindow: NSWindow?
    private var snapPreviewView: MacGridSkeletonView?

    var onSortChanged: ((UUID, RegionFileSort) -> Void)?
    var onCollapseRequested: ((UUID) -> Void)?
    var onFilesDragStarted: (([URL]) -> Void)?
    var onFilesRevealRequested: (([URL]) -> Void)?
    var onFilesDragEnded: ((UUID, [URL], NSDragOperation) -> Void)?
    var onFrameChanged: ((UUID, NSRect) -> Void)?
    var onFilesDropped: ((UUID, [URL], NSPoint) -> Void)?
    var onMoreRequested: ((UUID) -> Void)?
    var onMacGridFrameRequested: ((UUID, NSRect, Bool) -> NSRect)?
    var onInteractionMouseMoved: ((NSPoint) -> Void)?

    var editSurfaceIgnoresMouseEvents: Bool {
        interactionWindow.ignoresMouseEvents
    }

    init(region: Region, editMode: Bool,
         appearanceLoader: @escaping (URL) -> RegionFileAppearance = RegionFileAppearance.load) {
        self.region = region
        self.filesView = RegionFilesView(frame: .zero, appearanceLoader: appearanceLoader)
        self.regionView = RegionView(region: region)
        self.interactionView = RegionView(region: region, rendersVisuals: false)
        self.interactionWindow = RegionInteractionWindow(
            contentRect: region.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.containerView = RegionBackgroundContainer(frame: NSRect(origin: .zero, size: region.frame.size))
        self.visualEffectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: region.frame.size))

        let window = UnconstrainedRegionWindow(
            contentRect: region.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.title = region.name
        window.setAccessibilityTitle(region.name)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        interactionWindow.isOpaque = false
        interactionWindow.backgroundColor = .clear
        interactionWindow.hasShadow = false
        interactionWindow.level = RegionWindowLayerPolicy(editMode: editMode)
            .interactionLevel(paintsContent: region.ownsFileSurface)
        interactionWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        interactionWindow.isReleasedWhenClosed = false
        interactionWindow.title = "\(region.name) 编辑层"
        interactionWindow.setAccessibilityTitle("\(region.name) 编辑层")
        interactionView.frame = NSRect(origin: .zero, size: region.frame.size)
        interactionView.autoresizingMask = [.width, .height]
        interactionView.layer?.isOpaque = false
        interactionView.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(RegionInteractionSurfacePolicy(editMode: editMode).hitCaptureAlpha)
            .cgColor
        interactionWindow.contentView = interactionView
        interactionWindow.setFrame(region.frame, display: false)

        containerView.wantsLayer = true
        containerView.autoresizingMask = [.width, .height]
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.isEmphasized = false
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = RegionLayout.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        regionView.frame = containerView.bounds
        regionView.autoresizingMask = [.width, .height]
        containerView.addSubview(visualEffectView)
        containerView.addSubview(regionView)
        window.contentView = containerView
        window.setFrame(region.frame, display: false)

        super.init(window: window)

        window.delegate = self
        regionView.drawsMoreIndicator = false
        collapseButton.bezelStyle = .inline
        collapseButton.isBordered = false
        collapseButton.imagePosition = .imageOnly
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        interactionView.addSubview(collapseButton)
        moreButton.bezelStyle = .inline
        moreButton.isBordered = false
        moreButton.imagePosition = .imageOnly
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多设置")
        moreButton.identifier = NSUserInterfaceItemIdentifier("region-more")
        moreButton.setAccessibilityLabel("更多设置")
        moreButton.toolTip = "更多设置：外观、网格与文件排序"
        moreButton.target = self
        moreButton.action = #selector(showMore)
        interactionView.addSubview(moreButton)
        fileScrollView.drawsBackground = false
        fileScrollView.contentView.drawsBackground = false
        fileScrollView.borderType = .noBorder
        fileScrollView.hasVerticalScroller = true
        fileScrollView.autohidesScrollers = true
        fileScrollView.documentView = filesView
        fileScrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resizeFiles),
            name: NSView.frameDidChangeNotification, object: fileScrollView.contentView)
        interactionView.addSubview(fileScrollView, positioned: .below, relativeTo: collapseButton)
        filesView.onFilesDropped = { [weak self] urls, point in
            guard let self else { return }
            self.onFilesDropped?(self.region.id, urls, self.interactionWindow.convertPoint(toScreen: point))
        }
        filesView.onSortChanged = { [weak self] options in
            guard let self else { return }; self.onSortChanged?(self.region.id, options)
        }
        filesView.onDragStarted = { [weak self] urls in self?.onFilesDragStarted?(urls) }
        filesView.onRevealRequested = { [weak self] urls in self?.onFilesRevealRequested?(urls) }
        filesView.onDragEnded = { [weak self] urls, operation in
            guard let self else { return }
            self.onFilesDragEnded?(self.region.id, urls, operation)
        }
        filesView.onDropPreview = { [weak self] active in self?.regionView.setExternalFileDragPreview(active: active, at: nil) }
        layoutFileSurface()

        interactionView.onFrameChanged = { [weak self] frame in
            guard let self else { return }
            self.onFrameChanged?(self.region.id, frame)
        }
        interactionView.onLiveFrameChanged = { [weak self] frame in
            self?.showLiveFrame(frame)
        }
        interactionView.onFilesDropped = { [weak self] urls, windowPoint in
            guard let self else { return }
            self.onFilesDropped?(
                self.region.id,
                urls,
                self.interactionWindow.convertPoint(toScreen: windowPoint)
            )
        }
        interactionView.onMoreRequested = { [weak self] in
            guard let self else { return }
            self.onMoreRequested?(self.region.id)
        }
        interactionView.resolveMacGridFrame = { [weak self] proposedFrame, prefersTopOverflow in
            guard let self else { return proposedFrame }
            return self.onMacGridFrameRequested?(
                self.region.id,
                proposedFrame,
                prefersTopOverflow
            ) ?? proposedFrame
        }
        interactionView.onMacGridPreviewChanged = { [weak self] frame in
            self?.showMacGridPreview(frame)
        }
        interactionView.onInteractionMouseMoved = { [weak self] point in
            self?.onInteractionMouseMoved?(point)
        }
        interactionView.onFileDragPreviewChanged = { [weak self] active, point in
            self?.regionView.setExternalFileDragPreview(active: active, at: point)
        }
        updateBackdrop(for: region)
        setEditMode(editMode)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with updatedRegion: Region) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        region = updatedRegion
        regionView.region = updatedRegion
        interactionView.region = updatedRegion
        snapPreviewView?.region = updatedRegion
        window?.title = updatedRegion.name
        window?.setAccessibilityTitle(updatedRegion.name)
        interactionWindow.title = "\(updatedRegion.name) 编辑层"
        interactionWindow.setAccessibilityTitle("\(updatedRegion.name) 编辑层")
        if let window, window.frame != updatedRegion.frame {
            applyingModelFrame = true
            window.setFrame(updatedRegion.frame, display: true)
            applyingModelFrame = false
        }
        if interactionWindow.frame != updatedRegion.frame {
            interactionWindow.setFrame(updatedRegion.frame, display: true)
        }
        updateBackdrop(for: updatedRegion)
        layoutFileSurface()
        applyInteractionLayer()
        interactionWindow.displayIfNeeded()
    }

    func setEditMode(_ enabled: Bool) {
        currentEditMode = enabled
        regionView.editMode = enabled
        interactionView.editMode = enabled
        window?.ignoresMouseEvents = true
        applyInteractionLayer()
        layoutFileSurface()
        if !enabled { showMacGridPreview(nil) }
    }

    private func applyInteractionLayer() {
        interactionWindow.level = RegionWindowLayerPolicy(editMode: currentEditMode)
            .interactionLevel(paintsContent: region.ownsFileSurface)
        interactionWindow.acceptsMouseMovedEvents = true
        interactionView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.01).cgColor
        if region.ownsFileSurface {
            // Background, title and files must commit in the same window. Two
            // independently refreshed windows leave a stale icon-only frame.
            if containerView.superview !== interactionView {
                window?.contentView = nil
                containerView.frame = interactionView.bounds
                interactionView.addSubview(containerView, positioned: .below, relativeTo: fileScrollView)
            }
            window?.orderOut(nil)
        } else {
            if window?.contentView !== containerView {
                containerView.removeFromSuperview()
                window?.contentView = containerView
            }
            window?.orderFrontRegardless()
        }
        interactionWindow.orderFrontRegardless()
        if !currentEditMode {
            updateEditInteractionPassthrough(at: NSEvent.mouseLocation, desktopIconCenters: [], iconSize: 0, isOverControlWindow: false)
        }
    }

    private func layoutFileSurface(for layoutRegion: Region? = nil) {
        let region = layoutRegion ?? self.region
        let bounds = NSRect(origin: .zero, size: region.frame.size)
        let header = RegionLayout.headerRect(in: bounds, region: region)
        collapseButton.frame = NSRect(x: header.minX + 7, y: header.midY - 12, width: 26, height: 24)
        collapseButton.image = NSImage(systemSymbolName: region.isCollapsed ? "chevron.down" : "chevron.up",
                                       accessibilityDescription: region.isCollapsed ? "展开分区" : "收起分区")
        collapseButton.contentTintColor = NSColor(hex: region.titleColorHex)
        collapseButton.isHidden = !region.allowsCollapse
        collapseButton.toolTip = region.isCollapsed ? "展开分区" : "收起分区"
        moreButton.frame = NSRect(x: header.maxX - 42, y: header.midY - 16, width: 40, height: 32)
        moreButton.contentTintColor = NSColor(hex: region.titleColorHex)
        moreButton.isHidden = !currentEditMode
        // Use expanded geometry even while collapsed so the cached document
        // never shrinks/reloads/scrolls when the title is clicked.
        var expanded = region; expanded.isCollapsed = false
        let expandedHeader = RegionLayout.headerRect(in: bounds, region: expanded)
        fileScrollView.frame = region.rendersBoundIcons
            ? NSRect(x: 0, y: 0, width: bounds.width, height: max(1, expandedHeader.minY))
            : NSRect(x: 6, y: 8, width: max(1, bounds.width - 12), height: max(1, expandedHeader.minY - 10))
        fileScrollView.isHidden = !region.ownsFileSurface || region.isCollapsed
        fileScrollView.hasVerticalScroller = !region.rendersBoundIcons
        filesView.desktopLayout = region.rendersBoundIcons
            ? BoundDesktopIconLayout(region: expanded, viewport: fileScrollView.frame) : nil
        filesView.editsRegionLayout = currentEditMode
        if filesView.mode != region.displayMode {
            filesView.mode = region.displayMode
            filesView.scroll(.zero)
        }
        filesView.sortOptions = region.fileSort
        filesView.titleColor = NSColor(hex: region.titleColorHex)
        if !region.isMapped && region.ownsFileSurface,
           loadedBindings != region.itemBindings || loadedSort != region.fileSort || loadedDisplayMode != region.displayMode {
            let urls = region.itemBindings.filter(\.isExplicit).map { URL(fileURLWithPath: $0.path) }
                .filter { FolderFileOperations.entryExists(at: $0) }
            setFiles(region.rendersBoundIcons ? urls : RegionFileSorting.sorted(urls, by: region.fileSort))
            loadedBindings = region.itemBindings
            loadedSort = region.fileSort
            loadedDisplayMode = region.displayMode
        }
        filesView.resizeContent()
    }

    func setFiles(_ urls: [URL], message: String? = nil) {
        if filesView.urls != urls { filesView.urls = urls }
        filesView.message = message
    }

    @objc private func toggleCollapse() { onCollapseRequested?(region.id) }
    @objc private func showMore() { onMoreRequested?(region.id) }
    @objc private func resizeFiles() { filesView.resizeContent() }

    func showDropFeedback() {
        regionView.showDropFeedback()
    }

    func setAvailableSlots(_ indices: Set<Int>) {
        regionView.setAvailableSlots(indices)
        interactionView.setAvailableSlots(indices)
    }

    func setFinderDragPreview(active: Bool, hoveredSlotIndex: Int? = nil) {
        regionView.setFinderDragPreview(active: active, hoveredSlotIndex: hoveredSlotIndex)
    }

    func show() {
        applyInteractionLayer()
    }

    func activateInteractionSurface() {
        guard interactionView.editMode else { return }
        interactionWindow.makeKeyAndOrderFront(nil)
    }

    func updateEditInteractionPassthrough(
        at mousePoint: NSPoint,
        desktopIconCenters: [NSPoint],
        iconSize: CGFloat,
        isOverControlWindow: Bool
    ) {
        if !currentEditMode {
            let local = NSPoint(x: mousePoint.x - region.frame.minX, y: mousePoint.y - region.frame.minY)
            let bounds = NSRect(origin: .zero, size: region.frame.size)
            let header = RegionLayout.headerRect(in: bounds, region: region)
            let ownsHeader = region.allowsCollapse && header.contains(local)
            let ownsBody = region.ownsFileSurface && !region.isCollapsed &&
                RegionLayout.visualCollisionFrame(for: region).contains(mousePoint)
            interactionWindow.ignoresMouseEvents = isOverControlWindow || !(ownsHeader || ownsBody)
            return
        }
        let isOverFinderIcon = region.frame.contains(mousePoint) &&
            desktopIconCenters.contains {
                FinderIconHitTarget.contains(
                    mousePoint,
                    iconCenter: $0,
                    iconSize: iconSize
                )
            }
        interactionWindow.ignoresMouseEvents = RegionEditPassthroughPolicy.shouldIgnoreMouseEvents(
            isOverFinderIcon: !region.ownsFileSurface && !region.isCollapsed && isOverFinderIcon,
            isOverControlWindow: isOverControlWindow
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard !region.usesMacDefaultGrid || region.presentsOwnFiles else { return }
        notifyFrameChangedIfNeeded()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        notifyFrameChangedIfNeeded()
    }

    private func notifyFrameChangedIfNeeded() {
        guard !applyingModelFrame, let frame = window?.frame else { return }
        onFrameChanged?(region.id, frame)
    }

    private func updateBackdrop(for region: Region) {
        let requestsBackdrop = region.usesFrostedGlass || region.surfaceStyle == .layeredGlass
        visualEffectView.isHidden = region.surfaceStyle.isPaper || !requestsBackdrop
        let localBounds = NSRect(origin: .zero, size: region.frame.size)
        visualEffectView.frame = RegionLayout.visualRegionRect(in: localBounds, region: region)
    }

    private func showLiveFrame(_ frame: NSRect) {
        guard let window else { return }
        var liveRegion = region
        liveRegion.setFrame(frame)
        regionView.region = liveRegion
        applyingModelFrame = true
        window.setFrame(frame, display: true)
        applyingModelFrame = false
        updateBackdrop(for: liveRegion)
        layoutFileSurface(for: liveRegion)
    }

    private func showMacGridPreview(_ frame: NSRect?) {
        guard let frame else {
            snapPreviewWindow?.orderOut(nil)
            return
        }

        let previewWindow: NSWindow
        let previewView: MacGridSkeletonView
        if let existingWindow = snapPreviewWindow, let existingView = snapPreviewView {
            previewWindow = existingWindow
            previewView = existingView
        } else {
            previewView = MacGridSkeletonView(region: region)
            previewWindow = UnconstrainedRegionWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            previewWindow.isOpaque = false
            previewWindow.backgroundColor = .clear
            previewWindow.hasShadow = false
            previewWindow.ignoresMouseEvents = true
            previewWindow.level = .floating
            previewWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            previewWindow.isReleasedWhenClosed = false
            previewWindow.contentView = previewView
            snapPreviewWindow = previewWindow
            snapPreviewView = previewView
        }

        previewView.region = region
        previewWindow.setFrame(frame, display: true)
        previewWindow.orderFrontRegardless()
    }

    override func close() {
        NotificationCenter.default.removeObserver(self)
        interactionWindow.orderOut(nil)
        interactionWindow.close()
        snapPreviewWindow?.orderOut(nil)
        snapPreviewWindow?.close()
        snapPreviewWindow = nil
        snapPreviewView = nil
        super.close()
    }
}

private final class RegionBackgroundContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class RegionInteractionWindow: UnconstrainedRegionWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A noninteractive landing preview used while a Mac-grid region is dragged.
/// It displays only the region's visible footprint, its title row, and every
/// Finder slot. The transparent anchor area above the title is intentionally
/// omitted from the dashed preview.
private final class MacGridSkeletonView: NSView {
    var region: Region {
        didSet { needsDisplay = true }
    }

    init(region: Region) {
        self.region = region
        super.init(frame: region.frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var localRegion = region
        localRegion.setFrame(bounds)
        let visualBounds = RegionLayout.visualRegionRect(in: bounds, region: localRegion)
        let outer = visualBounds.insetBy(dx: 2, dy: 2)
        let outerPath = NSBezierPath(
            roundedRect: outer,
            xRadius: RegionLayout.cornerRadius,
            yRadius: RegionLayout.cornerRadius
        )
        NSColor.systemGray.withAlphaComponent(0.13).setFill()
        outerPath.fill()
        NSColor.systemGray.withAlphaComponent(0.82).setStroke()
        outerPath.lineWidth = 2
        outerPath.setLineDash([8, 6], count: 2, phase: 0)
        outerPath.stroke()

        let header = RegionLayout.headerRect(in: bounds, region: localRegion)
        let headerPath = NSBezierPath(roundedRect: header.insetBy(dx: 5, dy: 4), xRadius: 9, yRadius: 9)
        NSColor.systemGray.withAlphaComponent(0.25).setFill()
        headerPath.fill()
        NSColor.systemGray.withAlphaComponent(0.62).setStroke()
        headerPath.lineWidth = 1.25
        headerPath.stroke()

        let metrics = FinderDesktopGridMetrics.current()
        for center in RegionLayout.macGridSlotCenters(in: localRegion, metrics: metrics) {
            let size = min(RegionLayout.slotSize, metrics.iconSize)
            let rect = NSRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
            NSColor.systemGray.withAlphaComponent(0.18).setFill()
            path.fill()
            NSColor.systemGray.withAlphaComponent(0.72).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
