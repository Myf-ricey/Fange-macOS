// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

class UnconstrainedRegionWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

struct RegionInteractionPolicy {
    let editMode: Bool

    /// Position snapshots are also needed in edit mode so the transparent
    /// interaction surface can leave holes over every Finder icon.
    var monitorsFinderDesktopPositions: Bool { true }
    var capturesLayoutGestures: Bool { editMode }
    var windowIgnoresMouseEvents: Bool { !editMode }
}

enum SettingsPanelVisibilityState {
    case expanded
    case collapsed
}

enum SettingsPanelVisibilityAction {
    case requestedSettings
    case manualCollapse
    case enteredEditMode
    case leftEditMode
}

enum SettingsPanelVisibilityPolicy {
    static func nextState(
        from current: SettingsPanelVisibilityState,
        action: SettingsPanelVisibilityAction
    ) -> SettingsPanelVisibilityState {
        switch action {
        case .requestedSettings:
            return .expanded
        case .manualCollapse, .enteredEditMode:
            return .collapsed
        case .leftEditMode:
            return current
        }
    }
}

enum SettingsEdgePanelLayout {
    static let handleSize = NSSize(width: 38, height: 110)

    static func handleFrame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - handleSize.width,
            y: visibleFrame.midY - handleSize.height / 2,
            width: handleSize.width,
            height: handleSize.height
        )
    }

    static func restoredWindowFrame(_ savedFrame: NSRect, in visibleFrame: NSRect) -> NSRect {
        let width = min(savedFrame.width, visibleFrame.width)
        let height = min(savedFrame.height, visibleFrame.height)
        return NSRect(
            x: min(max(savedFrame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(savedFrame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }
}

struct RegionWindowLayerPolicy {
    let editMode: Bool

    /// The painted window never rises above Finder's desktop icon layer.
    var keepsVisualWindowBelowFinderIcons: Bool { true }
    /// Editing is handled by a separate clear window, so it can receive mouse
    /// gestures without painting over the desktop icons.
    var usesTransparentInteractionOverlay: Bool { editMode }

    /// The special top grid position puts the real title bar underneath the
    /// menu-bar band. Keep the painted region at desktop level, but raise only
    /// its completely transparent edit surface so that title dragging and the
    /// ellipsis remain interactive without drawing a duplicate title lower down.
    var interactionWindowLevel: NSWindow.Level {
        editMode ? .statusBar : .normal
    }
}

struct RegionInteractionSurfacePolicy {
    let editMode: Bool

    /// Make the input contract explicit instead of depending on NSWindow's
    /// defaults, which are easy to lose when swapping window implementations.
    var ignoresMouseEvents: Bool { !editMode }

    /// A fully clear window can be omitted from WindowServer hit testing on
    /// some macOS compositor paths. This is visually imperceptible, but gives
    /// the edit overlay a stable composited surface for mouse gestures.
    // Keep this above one 8-bit alpha step so the compositor cannot quantize
    // the whole surface back to fully transparent.
    var hitCaptureAlpha: CGFloat { 0.005 }
}

enum FinderDragPreviewPolicy {
    static func shouldActivate(
        editMode: Bool,
        finderIsFrontmost: Bool,
        hasDesktopItemCandidate: Bool
    ) -> Bool {
        guard finderIsFrontmost else { return false }
        return !editMode || hasDesktopItemCandidate
    }
}

enum FinderIconHitTarget {
    /// Finder's clickable item includes both the icon and the one/two-line name
    /// underneath it. Keep that whole target transparent to mouse input while
    /// the rest of an edit-region remains draggable.
    static func contains(
        _ point: NSPoint,
        iconCenter: NSPoint,
        iconSize: CGFloat
    ) -> Bool {
        let horizontalRadius = iconSize / 2 + 14
        let topRadius = iconSize / 2 + 10
        let bottomRadius = iconSize / 2 + 40
        return point.x >= iconCenter.x - horizontalRadius &&
            point.x <= iconCenter.x + horizontalRadius &&
            point.y >= iconCenter.y - bottomRadius &&
            point.y <= iconCenter.y + topRadius
    }
}

struct FinderDragCandidate {
    let path: String
    let iconCenter: NSPoint
}

enum FinderDragCandidatePolicy {
    /// Finder allows a drag to begin from either the icon or its one/two-line
    /// label. Use exactly that asymmetric hit target here instead of a smaller
    /// circular distance threshold, otherwise the bound source slot remains
    /// falsely occupied until the next Finder poll.
    static func candidatePaths(
        at point: NSPoint,
        candidates: [FinderDragCandidate],
        iconSize: CGFloat
    ) -> Set<String> {
        let matching = candidates.filter {
            FinderIconHitTarget.contains(
                point,
                iconCenter: $0.iconCenter,
                iconSize: iconSize
            )
        }
        guard let nearest = matching.min(by: {
            hypot($0.iconCenter.x - point.x, $0.iconCenter.y - point.y)
                < hypot($1.iconCenter.x - point.x, $1.iconCenter.y - point.y)
        }) else { return [] }
        return [nearest.path]
    }
}

struct FinderDragAvailabilityState {
    private(set) var activePaths = Set<String>()
    private(set) var pendingConfirmationPaths = Set<String>()

    mutating func beginPress(candidatePaths: Set<String>) {
        activePaths = candidatePaths
    }

    mutating func beginDrag(candidatePaths: Set<String>) {
        activePaths = candidatePaths
        pendingConfirmationPaths.formUnion(candidatePaths)
    }

    mutating func endDrag() {
        activePaths.removeAll()
    }

    mutating func confirm(paths: Set<String>) {
        activePaths.subtract(paths)
        pendingConfirmationPaths.subtract(paths)
    }

    mutating func clearPendingConfirmation() {
        pendingConfirmationPaths.removeAll()
    }

    func excludedPaths(selectedPaths: Set<String>) -> Set<String> {
        selectedPaths
            .union(activePaths)
            .union(pendingConfirmationPaths)
    }
}

enum RegionEditPassthroughPolicy {
    /// The elevated edit surface may only capture otherwise-empty desktop
    /// space. Finder icons and any visible app control window must stay above
    /// it from an input perspective, even when their WindowServer levels differ.
    static func shouldIgnoreMouseEvents(
        isOverFinderIcon: Bool,
        isOverControlWindow: Bool
    ) -> Bool {
        isOverFinderIcon || isOverControlWindow
    }
}

struct EditModeMenuPresentation {
    let title = "编辑模式"
    let state: NSControl.StateValue

    init(editMode: Bool) {
        state = editMode ? .on : .off
    }
}

enum RegionGestureGeometry {
    static func globalPoint(windowFrame: NSRect, eventLocationInWindow: NSPoint) -> NSPoint {
        NSPoint(
            x: windowFrame.minX + eventLocationInWindow.x,
            y: windowFrame.minY + eventLocationInWindow.y
        )
    }

    static func movedFrame(from frame: NSRect, dx: CGFloat, dy: CGFloat) -> NSRect {
        var result = frame
        result.origin.x += dx
        result.origin.y += dy
        return result
    }

    static func resizedFrameFromBottomRight(
        from frame: NSRect,
        dx: CGFloat,
        dy: CGFloat,
        minimumSize: NSSize = NSSize(width: 240, height: 180)
    ) -> NSRect {
        var result = frame
        result.size.width = max(minimumSize.width, frame.width + dx)
        let newHeight = max(minimumSize.height, frame.height - dy)
        result.origin.y = frame.maxY - newHeight
        result.size.height = newHeight
        return result
    }
}

enum MacGridTopOverflowIntent {
    static func shouldPreferTopOverflow(
        dragStartY: CGFloat,
        currentY: CGFloat,
        proposedFrameMaxY: CGFloat,
        visibleFrameMaxY: CGFloat
    ) -> Bool {
        let pointerReachedTopEdge = currentY >= visibleFrameMaxY - 12
        let clearlyDraggedUpward = currentY - dragStartY >= 24
        let regionReachedTopEdge = proposedFrameMaxY >= visibleFrameMaxY - 24
        return pointerReachedTopEdge || (clearlyDraggedUpward && regionReachedTopEdge)
    }
}

enum BoundItemRepositionReason {
    case regionGeometryChanged
    case restoreBindings
    case finderDrift

    var canSkipItemsMatchingFinderSnapshot: Bool {
        self != .regionGeometryChanged
    }
}

enum FinderBindingDriftPolicy {
    static func hasDrift(
        current: NSPoint?,
        target: (x: Int, y: Int),
        isSelected: Bool,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard !isSelected, let current else { return false }
        return abs(current.x - CGFloat(target.x)) > tolerance ||
            abs(current.y - CGFloat(target.y)) > tolerance
    }
}
