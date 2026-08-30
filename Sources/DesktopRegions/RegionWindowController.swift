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
    private var applyingModelFrame = false
    private var snapPreviewWindow: NSWindow?
    private var snapPreviewView: MacGridSkeletonView?

    var onFrameChanged: ((UUID, NSRect) -> Void)?
    var onFilesDropped: ((UUID, [URL], NSPoint) -> Void)?
    var onMoreRequested: ((UUID) -> Void)?
    var onMacGridFrameRequested: ((UUID, NSRect, Bool) -> NSRect)?
    var onInteractionMouseMoved: ((NSPoint) -> Void)?

    var editSurfaceIgnoresMouseEvents: Bool {
        interactionWindow.ignoresMouseEvents
    }

    init(region: Region, editMode: Bool) {
        self.region = region
        self.regionView = RegionView(region: region)
        self.interactionView = RegionView(region: region, rendersVisuals: false)
        self.interactionWindow = RegionInteractionWindow(
            contentRect: region.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.containerView = NSView(frame: NSRect(origin: .zero, size: region.frame.size))
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
        interactionWindow.level = RegionWindowLayerPolicy(editMode: editMode).interactionWindowLevel
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
    }

    func setEditMode(_ enabled: Bool) {
        let layerPolicy = RegionWindowLayerPolicy(editMode: enabled)
        let surfacePolicy = RegionInteractionSurfacePolicy(editMode: enabled)
        regionView.editMode = enabled
        interactionView.editMode = enabled
        window?.ignoresMouseEvents = true
        interactionWindow.ignoresMouseEvents = surfacePolicy.ignoresMouseEvents
        interactionWindow.level = layerPolicy.interactionWindowLevel
        interactionWindow.acceptsMouseMovedEvents = enabled
        interactionView.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(surfacePolicy.hitCaptureAlpha)
            .cgColor
        if layerPolicy.keepsVisualWindowBelowFinderIcons {
            window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        window?.orderFrontRegardless()
        if layerPolicy.usesTransparentInteractionOverlay {
            if let frame = window?.frame {
                interactionWindow.setFrame(frame, display: false)
            }
            interactionWindow.orderFrontRegardless()
        } else {
            interactionWindow.orderOut(nil)
            showMacGridPreview(nil)
        }
    }

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
        window?.orderFrontRegardless()
        if interactionView.editMode {
            interactionWindow.orderFrontRegardless()
        }
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
        guard interactionView.editMode else { return }
        let isOverFinderIcon = region.frame.contains(mousePoint) &&
            desktopIconCenters.contains {
                FinderIconHitTarget.contains(
                    mousePoint,
                    iconCenter: $0,
                    iconSize: iconSize
                )
            }
        interactionWindow.ignoresMouseEvents = RegionEditPassthroughPolicy.shouldIgnoreMouseEvents(
            isOverFinderIcon: isOverFinderIcon,
            isOverControlWindow: isOverControlWindow
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard !region.usesMacDefaultGrid else { return }
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
        interactionWindow.orderOut(nil)
        interactionWindow.close()
        snapPreviewWindow?.orderOut(nil)
        snapPreviewWindow?.close()
        snapPreviewWindow = nil
        snapPreviewView = nil
        super.close()
    }
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
