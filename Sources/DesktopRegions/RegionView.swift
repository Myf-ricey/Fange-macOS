// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

final class RegionView: NSView {
    enum Gesture {
        case move
        case resize
    }

    var region: Region {
        didSet { needsDisplay = true }
    }
    var editMode = false {
        didSet { needsDisplay = true }
    }
    var onFrameChanged: ((NSRect) -> Void)?
    var onLiveFrameChanged: ((NSRect) -> Void)?
    var onFilesDropped: (([URL], NSPoint) -> Void)?
    var onMoreRequested: (() -> Void)?
    var resolveMacGridFrame: ((NSRect, Bool) -> NSRect)?
    var onMacGridPreviewChanged: ((NSRect?) -> Void)?
    var onInteractionMouseMoved: ((NSPoint) -> Void)?
    var onFileDragPreviewChanged: ((Bool, NSPoint?) -> Void)?
    private let rendersVisuals: Bool

    private var gesture: Gesture?
    private var dragStart: NSPoint?
    private var frameAtDragStart: NSRect?
    private var isDropTarget = false
    private var finderDragPreviewActive = false
    private var availableSlotIndices = Set<Int>()
    private var hoveredSlotIndex: Int?
    private var feedbackWorkItem: DispatchWorkItem?
    private var pendingMacGridFrame: NSRect?
    private var pointerTrackingArea: NSTrackingArea?

    init(region: Region, rendersVisuals: Bool = true) {
        self.region = region
        self.rendersVisuals = rendersVisuals
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard editMode, let window else { return }
        onInteractionMouseMoved?(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard rendersVisuals else { return }

        let visualBounds = RegionLayout.visualRegionRect(in: bounds, region: region)
        let outer = visualBounds.insetBy(dx: 1, dy: 1)
        let outerPath = NSBezierPath(
            roundedRect: outer,
            xRadius: RegionLayout.cornerRadius,
            yRadius: RegionLayout.cornerRadius
        )
        drawSurface(in: outerPath, rect: outer)

        drawBorder(around: outer)

        if isDropTarget || finderDragPreviewActive {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: outer.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
            drawAvailableSlots()
        }

        // Never draw the elevated hit target as a second title strip. The
        // visible title stays attached to the region's real top edge.
        let headerRect = RegionLayout.headerRect(in: bounds, region: region)
        drawHeader(in: headerRect, clippedTo: outerPath)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: CGFloat(region.titleFontSize),
                weight: region.titleFontWeight.fontWeight
            ),
            .foregroundColor: NSColor(hex: region.titleColorHex).withAlphaComponent(0.96),
            .paragraphStyle: paragraphStyle
        ]

        let font = titleAttributes[.font] as! NSFont
        let titleHeight = ceil(font.ascender - font.descender + font.leading + 2)
        let titleRect = RegionLayout.titleTextRect(
            in: headerRect,
            titleHeight: titleHeight,
            editMode: editMode
        )
        (region.name as NSString).draw(in: titleRect, withAttributes: titleAttributes)

        if editMode {
            drawMoreIndicator(
                in: moreIndicatorRect(headerRect: headerRect),
                color: NSColor(hex: region.titleColorHex)
            )
            if !region.usesMacDefaultGrid {
                drawResizeIndicator()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard editMode, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let headerRect = effectiveHeaderRect()
        if moreIndicatorRect(headerRect: headerRect).insetBy(dx: -8, dy: -7).contains(point) {
            onMoreRequested?()
            return
        }
        gesture = region.usesMacDefaultGrid
            ? .move
            : ((point.x > bounds.maxX - 48 && point.y < 48) ? .resize : .move)
        dragStart = RegionGestureGeometry.globalPoint(
            windowFrame: window.frame,
            eventLocationInWindow: event.locationInWindow
        )
        frameAtDragStart = window.frame
        pendingMacGridFrame = nil
        onMacGridPreviewChanged?(nil)
        window.isMovableByWindowBackground = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard editMode,
              let gesture,
              let dragStart,
              let frameAtDragStart,
              let window else { return }

        let current = RegionGestureGeometry.globalPoint(
            windowFrame: window.frame,
            eventLocationInWindow: event.locationInWindow
        )
        let dx = current.x - dragStart.x
        let dy = current.y - dragStart.y
        let newFrame: NSRect
        switch gesture {
        case .move:
            newFrame = RegionGestureGeometry.movedFrame(from: frameAtDragStart, dx: dx, dy: dy)
        case .resize:
            newFrame = RegionGestureGeometry.resizedFrameFromBottomRight(
                from: frameAtDragStart,
                dx: dx,
                dy: dy,
                minimumSize: RegionLayout.minimumRegionSize(
                    columns: region.gridColumns,
                    rows: region.gridRows,
                    headerHeight: CGFloat(region.headerHeight),
                    iconSpacing: CGFloat(region.iconSpacing)
                )
            )
        }

        window.setFrame(newFrame, display: true)
        onLiveFrameChanged?(newFrame)
        if region.usesMacDefaultGrid {
            let wantsTop = prefersTopOverflow(
                dragStart: dragStart,
                current: current,
                proposedFrame: newFrame
            )
            let snappedFrame = resolveMacGridFrame?(
                newFrame,
                wantsTop
            ) ?? newFrame
            pendingMacGridFrame = snappedFrame
            onMacGridPreviewChanged?(snappedFrame)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard editMode else { return }
        let finalMacFrame = region.usesMacDefaultGrid ? pendingMacGridFrame : nil
        gesture = nil
        dragStart = nil
        frameAtDragStart = nil
        pendingMacGridFrame = nil
        onMacGridPreviewChanged?(nil)
        if let window {
            if let finalMacFrame {
                window.setFrame(finalMacFrame, display: true)
                onLiveFrameChanged?(finalMacFrame)
            }
            onFrameChanged?(window.frame)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        isDropTarget = true
        updateHoveredSlot(forWindowPoint: sender.draggingLocation)
        onFileDragPreviewChanged?(true, globalPoint(forWindowPoint: sender.draggingLocation))
        needsDisplay = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHoveredSlot(forWindowPoint: sender.draggingLocation)
        onFileDragPreviewChanged?(true, globalPoint(forWindowPoint: sender.draggingLocation))
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
        hoveredSlotIndex = nil
        onFileDragPreviewChanged?(false, nil)
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            isDropTarget = false
            hoveredSlotIndex = nil
            onFileDragPreviewChanged?(false, nil)
            needsDisplay = true
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        onFilesDropped?(urls, sender.draggingLocation)
        return true
    }

    func setAvailableSlots(_ indices: Set<Int>) {
        availableSlotIndices = indices
        needsDisplay = true
    }

    func setFinderDragPreview(active: Bool, hoveredSlotIndex: Int? = nil) {
        finderDragPreviewActive = active
        self.hoveredSlotIndex = hoveredSlotIndex
        needsDisplay = true
    }

    func setExternalFileDragPreview(active: Bool, at globalPoint: NSPoint?) {
        isDropTarget = active
        if active, let globalPoint {
            hoveredSlotIndex = nearestAvailableSlot(to: globalPoint)
        } else {
            hoveredSlotIndex = nil
        }
        needsDisplay = true
    }

    func showDropFeedback() {
        feedbackWorkItem?.cancel()
        isDropTarget = true
        needsDisplay = true
        let workItem = DispatchWorkItem { [weak self] in
            self?.isDropTarget = false
            self?.needsDisplay = true
        }
        feedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func moreIndicatorRect(headerRect: NSRect) -> NSRect {
        NSRect(x: headerRect.maxX - 34, y: headerRect.midY - 12, width: 24, height: 24)
    }

    private func effectiveHeaderRect() -> NSRect {
        let standard = RegionLayout.headerRect(in: bounds, region: region)
        guard editMode,
              let visibleFrame = (window?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        else { return standard }
        return RegionLayout.editingHeaderRect(
            in: bounds,
            region: region,
            visibleFrame: visibleFrame
        )
    }

    private func drawSurface(in path: NSBezierPath, rect: NSRect) {
        switch region.surfaceStyle {
        case .macNative:
            drawConfiguredFill(in: path)
        case .layeredGlass:
            drawLayeredGlass(in: path, rect: rect)
        case .monochromeFilm:
            drawMonochromeFilm(in: path, rect: rect)
        case .brushedMetal:
            drawBrushedMetal(in: path, rect: rect)
        case .blueprintGrid:
            drawBlueprintGrid(in: path, rect: rect)
        case .matteCeramic:
            drawMatteCeramic(in: path, rect: rect)
        case .wovenFiber:
            drawWovenFiber(in: path, rect: rect)
        case .liquidLight:
            drawLiquidLight(in: path, rect: rect)
        case .ricePaper:
            drawRicePaper(in: path, rect: rect)
        case .kraftArchivePaper:
            drawKraftArchivePaper(in: path, rect: rect)
        case .holographicFoil:
            drawHolographicFoil(in: path, rect: rect)
        case .liquidChrome:
            drawLiquidChrome(in: path, rect: rect)
        case .etchedCircuit:
            drawEtchedCircuit(in: path, rect: rect)
        }
    }

    private func drawConfiguredFill(
        in path: NSBezierPath,
        opacityScale: CGFloat = 1,
        forceGlassAttenuation: Bool? = nil
    ) {
        let usesGlassAttenuation = forceGlassAttenuation ?? region.usesFrostedGlass
        let glassScale: CGFloat = usesGlassAttenuation ? 0.52 : 1
        let alpha = clamped(CGFloat(region.opacity) * glassScale * opacityScale)
        let primary = NSColor(hex: region.colorHex).withAlphaComponent(alpha)
        guard region.gradientDirection != .solid else {
            primary.setFill()
            path.fill()
            return
        }

        let secondary = NSColor(hex: region.secondaryColorHex).withAlphaComponent(alpha)
        if let gradient = NSGradient(starting: primary, ending: secondary) {
            gradient.draw(in: path, angle: region.gradientDirection.gradientAngle)
        } else {
            primary.setFill()
            path.fill()
        }
    }

    private func drawLayeredGlass(in path: NSBezierPath, rect: NSRect) {
        drawConfiguredFill(in: path, opacityScale: 0.82, forceGlassAttenuation: true)
        let intensity = materialIntensity

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        let diagonalSheen = NSBezierPath()
        diagonalSheen.move(to: NSPoint(x: rect.minX - rect.width * 0.05, y: rect.maxY))
        diagonalSheen.line(to: NSPoint(x: rect.minX + rect.width * 0.56, y: rect.maxY))
        diagonalSheen.line(to: NSPoint(x: rect.minX + rect.width * 0.30, y: rect.minY))
        diagonalSheen.line(to: NSPoint(x: rect.minX - rect.width * 0.20, y: rect.minY))
        diagonalSheen.close()
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.16 * intensity),
            ending: NSColor.white.withAlphaComponent(0.015 * intensity)
        )?.draw(in: diagonalSheen, angle: 0)

        let lowerShade = NSBezierPath(rect: NSRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height * 0.42
        ))
        NSGradient(
            starting: NSColor(calibratedWhite: 0.05, alpha: 0.10 * intensity),
            ending: NSColor.clear
        )?.draw(in: lowerShade, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        drawInnerRim(in: rect, lightAlpha: 0.28 * intensity, darkAlpha: 0.10 * intensity)
    }

    private func drawMonochromeFilm(in path: NSBezierPath, rect: NSRect) {
        let alpha = clamped(CGFloat(region.opacity) * (region.usesFrostedGlass ? 0.52 : 1))
        let primary = monochrome(NSColor(hex: region.colorHex)).withAlphaComponent(alpha)
        let secondarySource = region.gradientDirection == .solid
            ? NSColor(hex: region.colorHex)
            : NSColor(hex: region.secondaryColorHex)
        let secondary = monochrome(secondarySource).withAlphaComponent(alpha)
        let angle = region.gradientDirection == .solid ? CGFloat(270) : region.gradientDirection.gradientAngle
        NSGradient(starting: primary, ending: secondary)?.draw(in: path, angle: angle)

        let intensity = materialIntensity
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(
            starting: NSColor.clear,
            ending: NSColor(calibratedWhite: 0.03, alpha: 0.32 * intensity)
        )?.draw(
            fromCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: 0,
            toCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: max(rect.width, rect.height) * 0.72,
            options: []
        )
        drawDeterministicGrain(in: rect, count: 130, intensity: intensity)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBrushedMetal(in path: NSBezierPath, rect: NSRect) {
        let alpha = clamped(CGFloat(region.opacity) * (region.usesFrostedGlass ? 0.52 : 1))
        let primary = NSColor(hex: region.colorHex)
        let secondary = NSColor(hex: region.secondaryColorHex)
        let bright = (primary.blended(withFraction: 0.34, of: .white) ?? primary)
            .withAlphaComponent(alpha)
        let dark = (secondary.blended(withFraction: 0.28, of: NSColor(calibratedWhite: 0.04, alpha: 1)) ?? secondary)
            .withAlphaComponent(alpha)
        let angle = region.gradientDirection == .solid ? CGFloat(270) : region.gradientDirection.gradientAngle
        NSGradient(starting: bright, ending: dark)?.draw(in: path, angle: angle)

        let intensity = materialIntensity
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let darkLines = NSBezierPath()
        let lightLines = NSBezierPath()
        var row = 0
        var y = rect.minY + 1
        while y < rect.maxY {
            let target = row.isMultiple(of: 4) ? lightLines : darkLines
            target.move(to: NSPoint(x: rect.minX, y: y))
            target.line(to: NSPoint(x: rect.maxX, y: y))
            row += 1
            y += 3
        }
        NSColor(calibratedWhite: 0.04, alpha: 0.11 * intensity).setStroke()
        darkLines.lineWidth = 0.45
        darkLines.stroke()
        NSColor.white.withAlphaComponent(0.16 * intensity).setStroke()
        lightLines.lineWidth = 0.55
        lightLines.stroke()

        let centerSheen = NSBezierPath(rect: NSRect(
            x: rect.minX,
            y: rect.midY - rect.height * 0.09,
            width: rect.width,
            height: rect.height * 0.18
        ))
        NSGradient(
            starting: NSColor.clear,
            ending: NSColor.white.withAlphaComponent(0.08 * intensity)
        )?.draw(in: centerSheen, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.15 * intensity, darkAlpha: 0.14 * intensity)
    }

    private func drawBlueprintGrid(in path: NSBezierPath, rect: NSRect) {
        drawConfiguredFill(in: path, opacityScale: 1.06)
        let intensity = materialIntensity

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let minorLines = NSBezierPath()
        let majorLines = NSBezierPath()
        let spacing: CGFloat = 18
        var index = 0
        var x = rect.minX
        while x <= rect.maxX {
            let target = index.isMultiple(of: 4) ? majorLines : minorLines
            target.move(to: NSPoint(x: x, y: rect.minY))
            target.line(to: NSPoint(x: x, y: rect.maxY))
            index += 1
            x += spacing
        }
        index = 0
        var y = rect.minY
        while y <= rect.maxY {
            let target = index.isMultiple(of: 4) ? majorLines : minorLines
            target.move(to: NSPoint(x: rect.minX, y: y))
            target.line(to: NSPoint(x: rect.maxX, y: y))
            index += 1
            y += spacing
        }
        NSColor.white.withAlphaComponent(0.11 * intensity).setStroke()
        minorLines.lineWidth = 0.55
        minorLines.stroke()
        NSColor.white.withAlphaComponent(0.23 * intensity).setStroke()
        majorLines.lineWidth = 0.9
        majorLines.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMatteCeramic(in path: NSBezierPath, rect: NSRect) {
        drawConfiguredFill(in: path, opacityScale: 1.10)
        let intensity = materialIntensity

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let highlightCenter = NSPoint(
            x: rect.minX + rect.width * 0.30,
            y: rect.maxY - rect.height * 0.18
        )
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.18 * intensity),
            ending: NSColor.clear
        )?.draw(
            fromCenter: highlightCenter,
            radius: 0,
            toCenter: highlightCenter,
            radius: max(rect.width, rect.height) * 0.72,
            options: []
        )
        drawDeterministicGrain(in: rect, count: 88, intensity: intensity * 0.62)
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.18 * intensity, darkAlpha: 0.08 * intensity)
    }

    private func drawWovenFiber(in path: NSBezierPath, rect: NSRect) {
        drawConfiguredFill(in: path)
        let intensity = materialIntensity

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let rising = NSBezierPath()
        let falling = NSBezierPath()
        let spacing: CGFloat = 7
        var offset = -rect.height
        while offset < rect.width + rect.height {
            rising.move(to: NSPoint(x: rect.minX + offset, y: rect.minY))
            rising.line(to: NSPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
            falling.move(to: NSPoint(x: rect.minX + offset, y: rect.maxY))
            falling.line(to: NSPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += spacing
        }
        NSColor.white.withAlphaComponent(0.105 * intensity).setStroke()
        rising.lineWidth = 0.65
        rising.stroke()
        NSColor(calibratedWhite: 0.03, alpha: 0.13 * intensity).setStroke()
        falling.lineWidth = 0.65
        falling.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLiquidLight(in path: NSBezierPath, rect: NSRect) {
        drawConfiguredFill(in: path, opacityScale: 0.72)
        let intensity = materialIntensity
        let primary = NSColor(hex: region.colorHex)
        let secondary = NSColor(hex: region.secondaryColorHex)
        let blobs: [(NSPoint, CGFloat, NSColor, CGFloat)] = [
            (NSPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.18),
             max(rect.width, rect.height) * 0.55, primary, 0.36),
            (NSPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.28),
             max(rect.width, rect.height) * 0.62, secondary, 0.34),
            (NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.08),
             max(rect.width, rect.height) * 0.40, NSColor.white, 0.13)
        ]

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        for (center, radius, color, alpha) in blobs {
            NSGradient(
                starting: color.withAlphaComponent(alpha * intensity),
                ending: color.withAlphaComponent(0)
            )?.draw(
                fromCenter: center,
                radius: 0,
                toCenter: center,
                radius: radius,
                options: []
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.12 * intensity, darkAlpha: 0.08 * intensity)
    }

    private func drawRicePaper(in path: NSBezierPath, rect: NSRect) {
        drawOpaquePaperBase(
            in: path,
            start: NSColor(deviceRed: 0.93, green: 0.91, blue: 0.84, alpha: 1),
            end: NSColor(deviceRed: 0.84, green: 0.81, blue: 0.72, alpha: 1),
            tintScale: 0.34
        )
        let intensity = paperTextureIntensity

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawUnryuFibers(in: rect, intensity: intensity)
        drawDeterministicGrain(in: rect, count: 46, intensity: intensity * 0.22)
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.11 * intensity, darkAlpha: 0.14 * intensity)
    }

    private func drawKraftArchivePaper(in path: NSBezierPath, rect: NSRect) {
        drawOpaquePaperBase(
            in: path,
            start: NSColor(deviceRed: 0.80, green: 0.64, blue: 0.43, alpha: 1),
            end: NSColor(deviceRed: 0.65, green: 0.47, blue: 0.28, alpha: 1),
            tintScale: 0.24
        )
        let intensity = paperTextureIntensity

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawRecycledKraftPulp(in: rect, intensity: intensity)
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.13 * intensity, darkAlpha: 0.22 * intensity)
    }

    private func drawHolographicFoil(in path: NSBezierPath, rect: NSRect) {
        drawConfiguredFill(in: path, opacityScale: 1.08)
        let intensity = max(0.42, materialIntensity)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(calibratedWhite: 0.03, alpha: 0.16 + 0.12 * intensity).setFill()
        path.fill()

        let spectrum = [
            NSColor(deviceRed: 0.98, green: 0.24, blue: 0.32, alpha: 0.18 * intensity),
            NSColor(deviceRed: 1.00, green: 0.72, blue: 0.22, alpha: 0.20 * intensity),
            NSColor(deviceRed: 0.32, green: 0.92, blue: 0.73, alpha: 0.20 * intensity),
            NSColor(deviceRed: 0.28, green: 0.72, blue: 1.00, alpha: 0.21 * intensity),
            NSColor(deviceRed: 0.76, green: 0.44, blue: 0.98, alpha: 0.18 * intensity),
            NSColor(deviceRed: 0.98, green: 0.24, blue: 0.54, alpha: 0.17 * intensity)
        ]
        NSGradient(colors: spectrum)?.draw(in: path, angle: 18)

        let interference = NSBezierPath()
        var offset = -rect.height
        while offset < rect.width + rect.height {
            interference.move(to: NSPoint(x: rect.minX + offset, y: rect.minY))
            interference.line(to: NSPoint(x: rect.minX + offset + rect.height * 0.58, y: rect.maxY))
            offset += 13
        }
        NSColor.white.withAlphaComponent(0.075 * intensity).setStroke()
        interference.lineWidth = 0.6
        interference.stroke()

        let prism = NSBezierPath()
        prism.move(to: NSPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY))
        prism.line(to: NSPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        prism.line(to: NSPoint(x: rect.minX + rect.width * 0.70, y: rect.minY))
        prism.line(to: NSPoint(x: rect.minX + rect.width * 0.48, y: rect.minY))
        prism.close()
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.28 * intensity),
            ending: NSColor.white.withAlphaComponent(0)
        )?.draw(in: prism, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.34 * intensity, darkAlpha: 0.20 * intensity)
    }

    private func drawLiquidChrome(in path: NSBezierPath, rect: NSRect) {
        let primary = NSColor(hex: region.colorHex)
        let secondary = NSColor(hex: region.secondaryColorHex)
        let alpha = clamped(0.30 + CGFloat(region.opacity) * 0.88)
        let deep = (primary.blended(withFraction: 0.78, of: .black) ?? primary)
            .withAlphaComponent(alpha)
        let mid = (secondary.blended(withFraction: 0.42, of: NSColor(calibratedWhite: 0.52, alpha: 1)) ?? secondary)
            .withAlphaComponent(alpha)
        let bright = (primary.blended(withFraction: 0.86, of: .white) ?? primary)
            .withAlphaComponent(alpha)
        let dark = NSColor(calibratedWhite: 0.025, alpha: alpha)
        let angle = region.gradientDirection == .solid ? CGFloat(270) : region.gradientDirection.gradientAngle
        NSGradient(colors: [dark, bright, mid, deep, bright, dark])?.draw(in: path, angle: angle)

        let intensity = max(0.50, materialIntensity)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        for index in 0..<6 {
            let unit = CGFloat(index) / 5
            let y = rect.minY + rect.height * (0.12 + unit * 0.74)
            let amplitude = rect.height * (0.025 + CGFloat(index % 3) * 0.012)
            let ribbon = NSBezierPath()
            ribbon.move(to: NSPoint(x: rect.minX - 4, y: y))
            ribbon.curve(
                to: NSPoint(x: rect.midX, y: y + amplitude * (index.isMultiple(of: 2) ? 1 : -1)),
                controlPoint1: NSPoint(x: rect.minX + rect.width * 0.18, y: y + amplitude),
                controlPoint2: NSPoint(x: rect.minX + rect.width * 0.38, y: y - amplitude)
            )
            ribbon.curve(
                to: NSPoint(x: rect.maxX + 4, y: y - amplitude * 0.25),
                controlPoint1: NSPoint(x: rect.minX + rect.width * 0.68, y: y + amplitude * 1.3),
                controlPoint2: NSPoint(x: rect.minX + rect.width * 0.84, y: y - amplitude)
            )
            ribbon.lineCapStyle = .round
            let color = index.isMultiple(of: 2)
                ? NSColor.white.withAlphaComponent(0.20 * intensity)
                : NSColor.black.withAlphaComponent(0.22 * intensity)
            color.setStroke()
            ribbon.lineWidth = index.isMultiple(of: 3) ? 4.2 : 2.1
            ribbon.stroke()
        }

        let verticalFlash = NSBezierPath(rect: NSRect(
            x: rect.minX + rect.width * 0.57,
            y: rect.minY,
            width: rect.width * 0.12,
            height: rect.height
        ))
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0),
            ending: NSColor.white.withAlphaComponent(0.24 * intensity)
        )?.draw(in: verticalFlash, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.42 * intensity, darkAlpha: 0.32 * intensity)
    }

    private func drawEtchedCircuit(in path: NSBezierPath, rect: NSRect) {
        let primary = NSColor(hex: region.colorHex)
        let secondary = NSColor(hex: region.secondaryColorHex)
        let alpha = clamped(0.18 + CGFloat(region.opacity) * (region.usesFrostedGlass ? 0.58 : 0.96))
        let darkPrimary = (primary.blended(withFraction: 0.72, of: .black) ?? primary)
            .withAlphaComponent(alpha)
        let darkSecondary = (secondary.blended(withFraction: 0.80, of: .black) ?? secondary)
            .withAlphaComponent(alpha)
        let angle = region.gradientDirection == .solid ? CGFloat(270) : region.gradientDirection.gradientAngle
        NSGradient(starting: darkPrimary, ending: darkSecondary)?.draw(in: path, angle: angle)

        let intensity = max(0.50, materialIntensity)
        let accentBase = primary.blended(
            withFraction: 0.62,
            of: NSColor(deviceRed: 0.33, green: 0.88, blue: 0.86, alpha: 1)
        ) ?? NSColor(deviceRed: 0.33, green: 0.88, blue: 0.86, alpha: 1)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let microGrid = NSBezierPath()
        var x = rect.minX
        while x <= rect.maxX {
            microGrid.move(to: NSPoint(x: x, y: rect.minY))
            microGrid.line(to: NSPoint(x: x, y: rect.maxY))
            x += 22
        }
        var y = rect.minY
        while y <= rect.maxY {
            microGrid.move(to: NSPoint(x: rect.minX, y: y))
            microGrid.line(to: NSPoint(x: rect.maxX, y: y))
            y += 22
        }
        accentBase.withAlphaComponent(0.035 * intensity).setStroke()
        microGrid.lineWidth = 0.5
        microGrid.stroke()

        let traces = NSBezierPath()
        var pads: [NSPoint] = []
        for index in 0..<42 {
            let unitX = CGFloat((index * 79 + 17) % 997) / 997
            let unitY = CGFloat((index * 149 + 41) % 991) / 991
            let lengthUnit = CGFloat((index * 53 + 11) % 983) / 983
            let start = NSPoint(
                x: rect.minX + rect.width * unitX,
                y: rect.minY + rect.height * unitY
            )
            let horizontal = 14 + 42 * lengthUnit
            let vertical = CGFloat((index * 31 + 7) % 29) - 14
            let direction: CGFloat = index.isMultiple(of: 4) ? -1 : 1
            let elbow = NSPoint(x: start.x + direction * horizontal * 0.58, y: start.y)
            let end = NSPoint(x: start.x + direction * horizontal, y: start.y + vertical)
            traces.move(to: start)
            traces.line(to: elbow)
            traces.line(to: NSPoint(x: elbow.x, y: end.y))
            traces.line(to: end)
            if index.isMultiple(of: 3) { pads.append(end) }
        }
        traces.lineJoinStyle = .round
        traces.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.34 * intensity).setStroke()
        traces.lineWidth = 1.8
        traces.stroke()
        accentBase.withAlphaComponent(0.42 * intensity).setStroke()
        traces.lineWidth = 0.72
        traces.stroke()

        accentBase.withAlphaComponent(0.52 * intensity).setFill()
        for pad in pads {
            NSBezierPath(ovalIn: NSRect(x: pad.x - 1.45, y: pad.y - 1.45, width: 2.9, height: 2.9)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        drawInnerRim(in: rect, lightAlpha: 0.20 * intensity, darkAlpha: 0.28 * intensity)
    }

    private func drawOpaquePaperBase(
        in path: NSBezierPath,
        start: NSColor,
        end: NSColor,
        tintScale: CGFloat
    ) {
        NSGradient(starting: start, ending: end)?.draw(in: path, angle: 270)

        // Opacity has a different, explicit meaning for paper: it adjusts how
        // strongly the selected colors dye an already opaque sheet.
        let tintAlpha = clamped(0.05 + CGFloat(region.opacity) * tintScale)
        let primary = NSColor(hex: region.colorHex).withAlphaComponent(tintAlpha)
        if region.gradientDirection == .solid {
            primary.setFill()
            path.fill()
            return
        }
        let secondary = NSColor(hex: region.secondaryColorHex).withAlphaComponent(tintAlpha)
        NSGradient(starting: primary, ending: secondary)?
            .draw(in: path, angle: region.gradientDirection.gradientAngle)
    }

    private func drawRecycledKraftPulp(in rect: NSRect, intensity: CGFloat) {
        let palePulp = NSBezierPath()
        let darkPulp = NSBezierPath()
        for index in 0..<190 {
            let unitX = CGFloat((index * 97 + 23) % 1009) / 1009
            let unitY = CGFloat((index * 181 + 53) % 1013) / 1013
            let lengthUnit = CGFloat((index * 61 + 17) % 1019) / 1019
            let curveUnit = CGFloat((index * 43 + 29) % 1021) / 1021 - 0.5
            let start = NSPoint(x: rect.minX + rect.width * unitX, y: rect.minY + rect.height * unitY)
            let length = 3 + 10 * lengthUnit
            let pulp = index.isMultiple(of: 5) ? palePulp : darkPulp
            pulp.move(to: start)
            pulp.curve(
                to: NSPoint(x: start.x + length, y: start.y + curveUnit * 4),
                controlPoint1: NSPoint(x: start.x + length * 0.30, y: start.y + curveUnit * 8),
                controlPoint2: NSPoint(x: start.x + length * 0.70, y: start.y - curveUnit * 7)
            )
        }
        palePulp.lineCapStyle = .round
        darkPulp.lineCapStyle = .round
        NSColor(deviceRed: 0.98, green: 0.86, blue: 0.65, alpha: 0.20 * intensity).setStroke()
        palePulp.lineWidth = 0.68
        palePulp.stroke()
        NSColor(deviceRed: 0.28, green: 0.16, blue: 0.07, alpha: 0.20 * intensity).setStroke()
        darkPulp.lineWidth = 0.52
        darkPulp.stroke()

        for index in 0..<46 {
            let unitX = CGFloat((index * 139 + 17) % 997) / 997
            let unitY = CGFloat((index * 211 + 43) % 991) / 991
            let fleck = NSRect(
                x: rect.minX + rect.width * unitX,
                y: rect.minY + rect.height * unitY,
                width: 0.8 + CGFloat(index % 3) * 0.7,
                height: 0.6 + CGFloat(index % 4) * 0.38
            )
            NSColor(deviceRed: 0.20, green: 0.11, blue: 0.045, alpha: 0.22 * intensity).setFill()
            NSBezierPath(ovalIn: fleck).fill()
        }
    }

    private func drawUnryuFibers(in rect: NSRect, intensity: CGFloat) {
        for index in 0..<76 {
            let unitX = CGFloat((index * 83 + 37) % 1009) / 1009
            let unitY = CGFloat((index * 157 + 71) % 1013) / 1013
            let lengthUnit = CGFloat((index * 47 + 19) % 1019) / 1019
            let curveUnit = CGFloat((index * 67 + 13) % 1021) / 1021 - 0.5
            let start = NSPoint(
                x: rect.minX + rect.width * unitX,
                y: rect.minY + rect.height * unitY
            )
            let length = 34 + 96 * lengthUnit
            let direction: CGFloat = index.isMultiple(of: 5) ? -1 : 1
            let end = NSPoint(
                x: start.x + direction * length,
                y: start.y + curveUnit * 54
            )
            let fiber = NSBezierPath()
            fiber.move(to: start)
            fiber.curve(
                to: end,
                controlPoint1: NSPoint(
                    x: start.x + direction * length * 0.28,
                    y: start.y + curveUnit * 70 + CGFloat((index % 3) - 1) * 8
                ),
                controlPoint2: NSPoint(
                    x: start.x + direction * length * 0.72,
                    y: end.y - curveUnit * 62
                )
            )
            fiber.lineCapStyle = .round
            let isPaleFiber = index.isMultiple(of: 4)
            let fiberColor = isPaleFiber
                ? NSColor.white.withAlphaComponent((0.16 + 0.10 * lengthUnit) * intensity)
                : NSColor(deviceRed: 0.26, green: 0.21, blue: 0.13,
                          alpha: (0.065 + 0.055 * lengthUnit) * intensity)
            fiberColor.setStroke()
            fiber.lineWidth = isPaleFiber ? 1.15 + lengthUnit : 0.55 + lengthUnit * 0.75
            fiber.stroke()
        }

        for index in 0..<22 {
            let unitX = CGFloat((index * 139 + 17) % 997) / 997
            let unitY = CGFloat((index * 211 + 43) % 991) / 991
            let fleck = NSRect(
                x: rect.minX + rect.width * unitX,
                y: rect.minY + rect.height * unitY,
                width: 1.2 + CGFloat(index % 4),
                height: 0.7 + CGFloat(index % 3) * 0.45
            )
            NSColor(deviceRed: 0.24, green: 0.16, blue: 0.08,
                    alpha: 0.10 * intensity).setFill()
            NSBezierPath(roundedRect: fleck, xRadius: 0.6, yRadius: 0.6).fill()
        }
    }

    private func drawPaperFibers(
        in rect: NSRect,
        count: Int,
        minimumLength: CGFloat,
        maximumLength: CGFloat,
        verticalDrift: CGFloat,
        intensity: CGFloat
    ) {
        let lightFibers = NSBezierPath()
        let darkFibers = NSBezierPath()
        for index in 0..<count {
            let unitX = CGFloat((index * 83 + 29) % 1009) / 1009
            let unitY = CGFloat((index * 157 + 61) % 1013) / 1013
            let lengthUnit = CGFloat((index * 47 + 13) % 1019) / 1019
            let driftUnit = CGFloat((index * 37 + 17) % 1031) / 1031 - 0.5
            let length = minimumLength + (maximumLength - minimumLength) * lengthUnit
            let start = NSPoint(
                x: rect.minX + rect.width * unitX,
                y: rect.minY + rect.height * unitY
            )
            let fiber = index.isMultiple(of: 4) ? lightFibers : darkFibers
            fiber.move(to: start)
            fiber.line(to: NSPoint(
                x: min(rect.maxX, start.x + length),
                y: min(rect.maxY, max(rect.minY, start.y + driftUnit * verticalDrift))
            ))
        }
        NSColor.white.withAlphaComponent(0.12 * intensity).setStroke()
        lightFibers.lineWidth = 0.55
        lightFibers.stroke()
        NSColor(calibratedWhite: 0.06, alpha: 0.10 * intensity).setStroke()
        darkFibers.lineWidth = 0.45
        darkFibers.stroke()
    }

    private func drawInnerRim(in rect: NSRect, lightAlpha: CGFloat, darkAlpha: CGFloat) {
        let innerRect = rect.insetBy(dx: 3, dy: 3)
        let rim = NSBezierPath(
            roundedRect: innerRect,
            xRadius: max(1, RegionLayout.cornerRadius - 3),
            yRadius: max(1, RegionLayout.cornerRadius - 3)
        )
        NSColor.white.withAlphaComponent(lightAlpha).setStroke()
        rim.lineWidth = 1
        rim.stroke()

        let lowerEdge = NSBezierPath()
        lowerEdge.move(to: NSPoint(x: innerRect.minX + 12, y: innerRect.minY))
        lowerEdge.line(to: NSPoint(x: innerRect.maxX - 12, y: innerRect.minY))
        NSColor(calibratedWhite: 0.03, alpha: darkAlpha).setStroke()
        lowerEdge.lineWidth = 1
        lowerEdge.stroke()
    }

    private func drawDeterministicGrain(in rect: NSRect, count: Int, intensity: CGFloat) {
        for index in 0..<count {
            let unitX = CGFloat((index * 73 + 19) % 997) / 997
            let unitY = CGFloat((index * 151 + 47) % 991) / 991
            let size = CGFloat(index % 3) * 0.22 + 0.55
            let dotRect = NSRect(
                x: rect.minX + rect.width * unitX,
                y: rect.minY + rect.height * unitY,
                width: size,
                height: size
            )
            let color = index.isMultiple(of: 3)
                ? NSColor.white.withAlphaComponent(0.16 * intensity)
                : NSColor(calibratedWhite: 0.03, alpha: 0.14 * intensity)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    private func monochrome(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return NSColor(calibratedWhite: 0.45, alpha: 1)
        }
        let luminance = clamped(0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent)
        return NSColor(calibratedWhite: luminance, alpha: 1)
    }

    private var materialIntensity: CGFloat {
        clamped(CGFloat(region.opacity) * 2.8)
    }

    private var paperTextureIntensity: CGFloat {
        // Paper remains tactile even when the tint slider is at its minimum.
        clamped(0.78 + CGFloat(region.opacity) * 0.30)
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private func drawHeader(in rect: NSRect, clippedTo outerPath: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        outerPath.addClip()

        let standardPath = NSBezierPath(rect: rect)
        switch region.headerStyle {
        case .macNative:
            NSColor(calibratedWhite: 0.035, alpha: editMode ? 0.62 : 0.50).setFill()
            standardPath.fill()
        case .ink:
            NSColor(calibratedWhite: 0.035, alpha: editMode ? 0.94 : 0.88).setFill()
            standardPath.fill()
        case .porcelain:
            NSColor(calibratedWhite: 0.96, alpha: editMode ? 0.96 : 0.90).setFill()
            standardPath.fill()
        case .graphite:
            let gradient = NSGradient(
                starting: NSColor(calibratedWhite: 0.24, alpha: editMode ? 0.94 : 0.86),
                ending: NSColor(calibratedWhite: 0.075, alpha: editMode ? 0.96 : 0.90)
            )
            gradient?.draw(in: standardPath, angle: 270)
        case .colorTint:
            let base = NSColor(hex: region.colorHex)
            // Keep even very light user colors dark enough for the preset's
            // white title treatment to retain readable contrast.
            let start = (base.blended(withFraction: 0.48, of: .black) ?? base)
                .withAlphaComponent(editMode ? 0.94 : 0.84)
            let end = (base.blended(withFraction: 0.68, of: .black) ?? base)
                .withAlphaComponent(editMode ? 0.96 : 0.88)
            NSGradient(starting: start, ending: end)?.draw(in: standardPath, angle: 270)
        case .paperLabel:
            NSGradient(
                starting: NSColor(deviceRed: 0.94, green: 0.93, blue: 0.88, alpha: 1),
                ending: NSColor(deviceRed: 0.80, green: 0.79, blue: 0.73, alpha: 1)
            )?.draw(in: standardPath, angle: 270)
            drawPaperFibers(
                in: rect,
                count: 54,
                minimumLength: 3,
                maximumLength: 17,
                verticalDrift: 1.8,
                intensity: editMode ? 0.90 : 0.72
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.minX, y: rect.minY))
        divider.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        let usesDarkDivider = region.headerStyle == .porcelain || region.headerStyle == .paperLabel
        let dividerColor = usesDarkDivider
            ? NSColor(calibratedWhite: 0.08, alpha: 1)
            : NSColor.white
        dividerColor.withAlphaComponent(editMode ? 0.16 : 0.10).setStroke()
        divider.lineWidth = 1
        divider.stroke()
    }

    private func drawMoreIndicator(in rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.84).setFill()
        for offset in [-6, 0, 6] as [CGFloat] {
            NSBezierPath(ovalIn: NSRect(x: rect.midX + offset - 1.5, y: rect.midY - 1.5, width: 3, height: 3)).fill()
        }
    }

    private func drawResizeIndicator() {
        let northWest = NSPoint(x: bounds.maxX - 25, y: 25)
        let southEast = NSPoint(x: bounds.maxX - 9, y: 9)
        let arrow = NSBezierPath()
        arrow.move(to: northWest)
        arrow.line(to: southEast)
        arrow.move(to: northWest)
        arrow.line(to: NSPoint(x: northWest.x + 7, y: northWest.y))
        arrow.move(to: northWest)
        arrow.line(to: NSPoint(x: northWest.x, y: northWest.y - 7))
        arrow.move(to: southEast)
        arrow.line(to: NSPoint(x: southEast.x - 7, y: southEast.y))
        arrow.move(to: southEast)
        arrow.line(to: NSPoint(x: southEast.x, y: southEast.y + 7))
        NSColor.white.withAlphaComponent(0.72).setStroke()
        arrow.lineWidth = 1.6
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
    }

    private func drawAvailableSlots() {
        let centers = RegionLayout.globalSlotCenters(in: region)
        for index in availableSlotIndices.sorted() where centers.indices.contains(index) {
            let center = centers[index]
            let localCenter = NSPoint(x: center.x - region.frame.minX, y: center.y - region.frame.minY)
            let rect = NSRect(
                x: localCenter.x - RegionLayout.slotSize / 2,
                y: localCenter.y - RegionLayout.slotSize / 2,
                width: RegionLayout.slotSize,
                height: RegionLayout.slotSize
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
            if index == hoveredSlotIndex {
                NSColor.systemGray.withAlphaComponent(0.28).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.78).setStroke()
                path.lineWidth = 2
            } else {
                NSColor.systemGray.withAlphaComponent(0.62).setStroke()
                path.lineWidth = 1.5
            }
            path.stroke()
        }
    }

    private func drawBorder(around rect: NSRect) {
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: RegionLayout.cornerRadius,
            yRadius: RegionLayout.cornerRadius
        )
        if region.borderStyle == .none {
            guard editMode else { return }
            NSColor.white.withAlphaComponent(0.30).setStroke()
            path.lineWidth = 1
            path.setLineDash([3, 5], count: 2, phase: 0)
            path.stroke()
            return
        }

        NSColor(hex: region.borderColorHex)
            .withAlphaComponent(editMode ? 0.96 : 0.82)
            .setStroke()
        path.lineWidth = editMode ? 1.7 : 1.25
        path.lineCapStyle = .round
        if !region.borderStyle.dashPattern.isEmpty {
            let pattern = region.borderStyle.dashPattern
            path.setLineDash(pattern, count: pattern.count, phase: 0)
        }
        path.stroke()
    }

    private func updateHoveredSlot(forWindowPoint point: NSPoint) {
        guard let globalPoint = globalPoint(forWindowPoint: point) else { return }
        hoveredSlotIndex = nearestAvailableSlot(to: globalPoint)
    }

    private func globalPoint(forWindowPoint point: NSPoint) -> NSPoint? {
        window?.convertPoint(toScreen: point)
    }

    private func nearestAvailableSlot(to globalPoint: NSPoint) -> Int? {
        RegionLayout.nearestAvailableSlot(
            to: globalPoint,
            in: region,
            excluding: Set(RegionLayout.globalSlotCenters(in: region).indices).subtracting(availableSlotIndices)
        )
    }

    private func prefersTopOverflow(
        dragStart: NSPoint,
        current: NSPoint,
        proposedFrame: NSRect
    ) -> Bool {
        guard region.usesMacDefaultGrid else { return false }
        let screen = NSScreen.screens.first { $0.frame.contains(current) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return false }
        return MacGridTopOverflowIntent.shouldPreferTopOverflow(
            dragStartY: dragStart.y,
            currentY: current.y,
            proposedFrameMaxY: proposedFrame.maxY,
            visibleFrameMaxY: screen.visibleFrame.maxY
        )
    }
}
