// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

enum StatusBarIconFactory {
    static let canvasSize = NSSize(width: 18, height: 18)

    /// A resolution-independent macOS template icon based on the user's bowl
    /// sketch: a hollow, top-wide bowl with a solid semicircular serving above.
    static func makeRiceBowlIcon() -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            NSColor.black.setFill()
            NSColor.black.setStroke()

            let solidTop = NSBezierPath()
            let domeCenter = NSPoint(x: 9, y: 10.25)
            let domeRadius: CGFloat = 5.2
            solidTop.move(to: NSPoint(x: domeCenter.x + domeRadius, y: domeCenter.y))
            solidTop.appendArc(
                withCenter: domeCenter,
                radius: domeRadius,
                startAngle: 0,
                endAngle: 180
            )
            solidTop.close()
            solidTop.fill()

            let bowl = NSBezierPath()
            bowl.move(to: NSPoint(x: 2.1, y: 9.3))
            bowl.line(to: NSPoint(x: 15.9, y: 9.3))
            bowl.line(to: NSPoint(x: 13.25, y: 2.55))
            bowl.line(to: NSPoint(x: 4.75, y: 2.55))
            bowl.close()
            bowl.lineWidth = 1.65
            bowl.lineCapStyle = .round
            bowl.lineJoinStyle = .round
            bowl.stroke()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "饭格饭碗"
        return image
    }
}
