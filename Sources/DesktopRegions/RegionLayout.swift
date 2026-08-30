// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

/// Finder's desktop icon view settings.  Reading the active Finder values is
/// important here: a hand-tuned “Mac-looking” grid drifts away from the real
/// Clean Up positions as soon as the user changes desktop icon size.
struct FinderDesktopGridMetrics: Equatable {
    var iconSize: CGFloat
    var gridSpacing: CGFloat
    var gridOffsetX: CGFloat
    var gridOffsetY: CGFloat

    var pitch: CGFloat {
        max(72, min(200, iconSize + gridSpacing))
    }

    // Finder leaves a small optical margin in addition to half an icon.
    var horizontalInset: CGFloat { iconSize / 2 + 14 }
    var topInset: CGFloat { iconSize / 2 + 9 }
    var bottomInset: CGFloat { max(1, pitch - topInset) }

    static func current() -> FinderDesktopGridMetrics {
        let fallback = FinderDesktopGridMetrics(
            iconSize: 88,
            gridSpacing: 39,
            gridOffsetX: 0,
            gridOffsetY: 0
        )
        guard
            let desktopSettings = CFPreferencesCopyAppValue(
                "DesktopViewSettings" as CFString,
                "com.apple.finder" as CFString
            ) as? [String: Any],
            let iconSettings = desktopSettings["IconViewSettings"] as? [String: Any]
        else { return fallback }

        func number(_ key: String, fallback value: CGFloat) -> CGFloat {
            guard let number = iconSettings[key] as? NSNumber else { return value }
            return CGFloat(number.doubleValue)
        }

        return FinderDesktopGridMetrics(
            iconSize: max(32, min(160, number("iconSize", fallback: fallback.iconSize))),
            gridSpacing: max(0, min(160, number("gridSpacing", fallback: fallback.gridSpacing))),
            gridOffsetX: number("gridOffsetX", fallback: fallback.gridOffsetX),
            gridOffsetY: number("gridOffsetY", fallback: fallback.gridOffsetY)
        )
    }
}

enum RegionLayout {
    static let cornerRadius: CGFloat = 18
    static let defaultHeaderHeight: CGFloat = 34
    static let defaultIconSpacing: CGFloat = 96
    static let slotSize: CGFloat = 66
    static let minimumIconInset: CGFloat = 48
    static let iconTopInset: CGFloat = 40
    static let iconBottomInset: CGFloat = 80
    /// Matches the approved 262×425, 2×3, 125-pt manual region: the title bar
    /// sits roughly six points above the visible top edge of the first icon.
    static let macHeaderToFirstIconTopGap: CGFloat = 6
    /// Optical alignment measured from the user's Retina screenshot: the
    /// previous top grid frame sat 88 physical pixels above the Calendar widget.
    /// At 2× backing scale that is a 44-point downward shift for every row.
    static let macGridDownwardOffset: CGFloat = 44
    static let titleTextDownwardOffset: CGFloat = 2

    static func headerRect(in bounds: NSRect, height: CGFloat = defaultHeaderHeight) -> NSRect {
        let outer = bounds.insetBy(dx: 1, dy: 1)
        let safeHeight = min(max(28, height), max(28, outer.height))
        return NSRect(
            x: outer.minX,
            y: outer.maxY - safeHeight,
            width: outer.width,
            height: safeHeight
        )
    }

    static func headerRect(
        in bounds: NSRect,
        region: Region,
        metrics: FinderDesktopGridMetrics = .current()
    ) -> NSRect {
        guard region.usesMacGridGeometry else {
            return headerRect(in: bounds, height: CGFloat(region.headerHeight))
        }

        let outer = bounds.insetBy(dx: 1, dy: 1)
        let firstIconCenterY = bounds.maxY - metrics.topInset - metrics.pitch
        let fixedBottom = min(
            outer.maxY - 28,
            max(
                outer.minY,
                firstIconCenterY + metrics.iconSize / 2 + macHeaderToFirstIconTopGap
            )
        )
        let safeHeight = min(
            max(28, CGFloat(region.headerHeight)),
            max(28, outer.maxY - fixedBottom)
        )
        return NSRect(
            x: outer.minX,
            y: fixedBottom,
            width: outer.width,
            height: safeHeight
        )
    }

    static func titleTextRect(
        in headerRect: NSRect,
        titleHeight: CGFloat,
        editMode: Bool
    ) -> NSRect {
        NSRect(
            x: headerRect.minX + (editMode ? 42 : 16),
            y: headerRect.midY - titleHeight / 2 - titleTextDownwardOffset,
            width: headerRect.width - (editMode ? 84 : 32),
            height: titleHeight
        )
    }

    /// Editing must use the exact same title geometry as normal presentation.
    /// The transparent input window is elevated above the menu bar separately;
    /// moving this rect creates a visibly detached duplicate title strip.
    static func editingHeaderRect(
        in bounds: NSRect,
        region: Region,
        visibleFrame: NSRect,
        metrics: FinderDesktopGridMetrics = .current()
    ) -> NSRect {
        _ = visibleFrame
        return headerRect(in: bounds, region: region, metrics: metrics)
    }

    /// Mac-grid windows keep some transparent space above the title so their
    /// Finder-row anchor remains stable. Only the portion beginning at the
    /// title bar's top is visible or considered occupied.
    static func visualRegionRect(
        in bounds: NSRect,
        region: Region,
        metrics: FinderDesktopGridMetrics = .current()
    ) -> NSRect {
        guard region.usesMacGridGeometry else { return bounds }
        let header = headerRect(in: bounds, region: region, metrics: metrics)
        return NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: header.maxY - bounds.minY
        )
    }

    /// Converts a stored window frame into the footprint users can actually
    /// see.  Snap collision checks use this instead of the full backing window,
    /// allowing vertically adjacent regions to share the otherwise empty row
    /// above a title bar without letting their visible surfaces overlap.
    static func visualCollisionFrame(
        for region: Region,
        metrics: FinderDesktopGridMetrics = .current()
    ) -> NSRect {
        guard region.usesMacGridGeometry else { return region.frame }
        var localRegion = region
        let localBounds = NSRect(origin: .zero, size: region.frame.size)
        localRegion.setFrame(localBounds)
        return visualRegionRect(in: localBounds, region: localRegion, metrics: metrics)
            .offsetBy(dx: region.frame.minX, dy: region.frame.minY)
    }

    /// Finder drops must be classified against what the user can actually see.
    /// Mac-grid windows may contain a transparent anchor row above the title;
    /// treating that backing area as part of the region makes an apparently
    /// dragged-out icon snap back into its old binding.
    static func dropTargetRegion(
        at point: NSPoint,
        in regions: [Region],
        metrics: FinderDesktopGridMetrics = .current()
    ) -> Region? {
        regions.last {
            visualCollisionFrame(for: $0, metrics: metrics).contains(point)
        }
    }

    static func minimumRegionSize(
        columns: Int,
        rows: Int,
        headerHeight: CGFloat = defaultHeaderHeight,
        iconSpacing: CGFloat = defaultIconSpacing
    ) -> NSSize {
        let safeColumns = CGFloat(max(1, columns))
        let safeRows = CGFloat(max(1, rows))
        // The spacing slider controls the preferred layout, not the window's
        // interactive minimum. A compact grid is allowed to compress its step.
        let compactStep: CGFloat = 72
        let compactInsets: CGFloat = 96
        return NSSize(
            width: max(240, (safeColumns - 1) * compactStep + compactInsets),
            height: max(220, headerHeight + (safeRows - 1) * compactStep + compactInsets)
        )
    }

    static func globalSlotCenters(in region: Region) -> [NSPoint] {
        if region.usesMacGridGeometry {
            return macGridSlotCenters(in: region, metrics: .current())
        }

        let frame = region.frame
        let columns = max(1, min(12, region.gridColumns))
        let rows = max(1, min(12, region.gridRows))
        let requestedSpacing = CGFloat(max(72, min(180, region.iconSpacing)))
        let contentTop = frame.maxY - CGFloat(region.headerHeight)
        let availableWidth = max(0, frame.width - minimumIconInset * 2)
        let availableHeight = max(0, contentTop - frame.minY - iconTopInset - iconBottomInset)
        let horizontalStep = columns == 1 ? 0 : min(requestedSpacing, availableWidth / CGFloat(columns - 1))
        let verticalStep = rows == 1 ? 0 : min(requestedSpacing, availableHeight / CGFloat(rows - 1))
        let gridWidth = CGFloat(columns - 1) * horizontalStep
        let gridHeight = CGFloat(rows - 1) * verticalStep
        let firstX = frame.midX - gridWidth / 2
        let usableBottom = frame.minY + iconBottomInset
        let usableTop = contentTop - iconTopInset
        let firstY = usableBottom + (usableTop - usableBottom + gridHeight) / 2

        return (0..<(columns * rows)).map { index in
            let column = index % columns
            let row = index / columns
            return NSPoint(
                x: firstX + CGFloat(column) * horizontalStep,
                y: firstY - CGFloat(row) * verticalStep
            )
        }
    }

    /// A Mac-grid region normally occupies one complete Finder row for its
    /// title bar, followed by the requested number of icon rows.  The topmost
    /// snap position is the one exception: that reserved title row may extend
    /// above the desktop so icons can use Finder's very first row.
    static func macGridFrameSize(
        for region: Region,
        metrics: FinderDesktopGridMetrics = .current()
    ) -> NSSize {
        let columns = CGFloat(max(1, min(12, region.gridColumns)))
        let rows = CGFloat(max(1, min(12, region.gridRows)))
        let bottomExtension = CGFloat(max(0, min(80, region.macGridBottomExtension)))
        return NSSize(
            width: (columns - 1) * metrics.pitch + metrics.horizontalInset * 2,
            height: (rows + 1) * metrics.pitch + bottomExtension
        )
    }

    static func macGridSlotCenters(
        in region: Region,
        metrics: FinderDesktopGridMetrics = .current()
    ) -> [NSPoint] {
        let columns = max(1, min(12, region.gridColumns))
        let rows = max(1, min(12, region.gridRows))
        let firstX = region.frame.minX + metrics.horizontalInset
        // The title bar owns the first Finder row; icons begin one pitch below.
        let firstY = region.frame.maxY - metrics.topInset - metrics.pitch
        return (0..<(columns * rows)).map { index in
            let column = index % columns
            let row = index / columns
            return NSPoint(
                x: firstX + CGFloat(column) * metrics.pitch,
                y: firstY - CGFloat(row) * metrics.pitch
            )
        }
    }

    /// Returns the closest Finder-lattice frame. `occupiedFrames` contains the
    /// real visible footprints of existing regions, rather than their backing
    /// windows' transparent title-anchor area.
    static func snappedMacGridFrame(
        near proposedFrame: NSRect,
        region: Region,
        visibleFrame: NSRect,
        metrics: FinderDesktopGridMetrics = .current(),
        avoiding occupiedFrames: [NSRect] = [],
        prefersTopOverflow: Bool = false
    ) -> NSRect {
        let size = macGridFrameSize(for: region, metrics: metrics)
        let anchorX = visibleFrame.maxX - metrics.horizontalInset + metrics.gridOffsetX
        let anchorY = visibleFrame.maxY
            - metrics.topInset
            - metrics.gridOffsetY
            - macGridDownwardOffset
        let desiredRightCenter = proposedFrame.maxX - metrics.horizontalInset
        let desiredHeaderCenter = proposedFrame.maxY - metrics.topInset
        let baseColumn = Int(round((anchorX - desiredRightCenter) / metrics.pitch))
        let baseRow = Int(round((anchorY - desiredHeaderCenter) / metrics.pitch))

        struct Candidate {
            let frame: NSRect
            let score: CGFloat
            let overlaps: Bool
            let gridRow: Int
        }

        var candidates: [Candidate] = []
        for rowDelta in -12...12 {
            for columnDelta in -12...12 {
                let column = baseColumn + columnDelta
                let row = baseRow + rowDelta
                let rightCenter = anchorX - CGFloat(column) * metrics.pitch
                let headerCenter = anchorY - CGFloat(row) * metrics.pitch
                let frame = NSRect(
                    x: rightCenter + metrics.horizontalInset - size.width,
                    y: headerCenter + metrics.topInset - size.height,
                    width: size.width,
                    height: size.height
                )
                guard macGridCandidateFits(
                    frame,
                    gridRow: row,
                    visibleFrame: visibleFrame,
                    metrics: metrics,
                    bottomExtension: CGFloat(max(0, min(80, region.macGridBottomExtension)))
                ) else { continue }
                var candidateRegion = region
                candidateRegion.setFrame(frame)
                let candidateFootprint = visualCollisionFrame(
                    for: candidateRegion,
                    metrics: metrics
                )
                let dx = frame.midX - proposedFrame.midX
                let dy = frame.midY - proposedFrame.midY
                candidates.append(Candidate(
                    frame: frame,
                    score: dx * dx + dy * dy,
                    overlaps: occupiedFrames.contains { $0.intersects(candidateFootprint) },
                    gridRow: row
                ))
            }
        }

        let collisionFree = candidates.filter { !$0.overlaps }
        let viable = collisionFree.isEmpty ? candidates : collisionFree
        if prefersTopOverflow,
           let topCandidate = viable.filter({ $0.gridRow == -1 }).min(by: { $0.score < $1.score }) {
            return topCandidate.frame
        }
        return viable.min { $0.score < $1.score }?.frame
            ?? clampedFrame(proposedFrame, size: size, inside: visibleFrame)
    }

    static func nearestAvailableSlot(
        to point: NSPoint,
        in region: Region,
        excluding occupiedIndices: Set<Int>
    ) -> Int? {
        let centers = globalSlotCenters(in: region)
        return centers.indices
            .filter { !occupiedIndices.contains($0) }
            .min { lhs, rhs in
                distanceSquared(from: centers[lhs], to: point)
                    < distanceSquared(from: centers[rhs], to: point)
            }
    }

    static func finderIconPositions(
        in region: Region,
        screenFrame: NSRect,
        count: Int
    ) -> [(x: Int, y: Int)] {
        let centers = globalSlotCenters(in: region)
        let capacity = centers.count
        let safeCount = min(max(count, 1), capacity)

        return centers.prefix(safeCount).map { center in
            return (
                x: Int(center.x - screenFrame.minX),
                y: Int(screenFrame.maxY - center.y)
            )
        }
    }

    private static func distanceSquared(from lhs: NSPoint, to rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
        inner.minX >= outer.minX && inner.maxX <= outer.maxX &&
            inner.minY >= outer.minY && inner.maxY <= outer.maxY
    }

    private static func macGridCandidateFits(
        _ frame: NSRect,
        gridRow: Int,
        visibleFrame: NSRect,
        metrics: FinderDesktopGridMetrics,
        bottomExtension: CGFloat
    ) -> Bool {
        guard frame.minX >= visibleFrame.minX,
              frame.maxX <= visibleFrame.maxX,
              frame.minY >= visibleFrame.minY - metrics.bottomInset - bottomExtension
        else { return false }

        if gridRow == -1 {
            // One intentional overflow only: the invisible row normally
            // reserved above the first icon row may sit outside the desktop.
            // The visible title bar itself remains immediately above Finder's
            // first icon row and is clipped naturally by the physical screen.
            return frame.maxY <= visibleFrame.maxY + metrics.pitch + 0.5
        }
        guard gridRow >= 0 else { return false }
        return frame.maxY <= visibleFrame.maxY
    }

    private static func clampedFrame(_ proposed: NSRect, size: NSSize, inside visible: NSRect) -> NSRect {
        NSRect(
            x: min(max(proposed.minX, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(proposed.minY, visible.minY), max(visible.minY, visible.maxY - size.height)),
            width: min(size.width, visible.width),
            height: min(size.height, visible.height)
        )
    }
}
