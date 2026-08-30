// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

struct DesktopIconPosition: Equatable {
    let path: String
    let position: NSPoint

    init(path: String, position: NSPoint) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.position = position
    }

    init(item: FinderDesktopItem) {
        self.init(path: item.url.path, position: item.position)
    }
}

struct WorkspaceSnapshot: Equatable {
    let regions: [Region]
    let desktopIconPositions: [DesktopIconPosition]
    let usesMacDefaultGrid: Bool

    init(
        regions: [Region],
        desktopIconPositions: [DesktopIconPosition],
        usesMacDefaultGrid: Bool
    ) {
        self.regions = regions
        self.desktopIconPositions = desktopIconPositions.sorted { $0.path < $1.path }
        self.usesMacDefaultGrid = usesMacDefaultGrid
    }
}

struct WorkspaceUndoStep: Equatable {
    let title: String
    let snapshot: WorkspaceSnapshot
}

struct WorkspaceUndoHistory {
    let limit: Int
    private(set) var steps: [WorkspaceUndoStep] = []

    init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    var nextStep: WorkspaceUndoStep? { steps.last }

    mutating func record(title: String, snapshot: WorkspaceSnapshot) {
        guard steps.last?.snapshot != snapshot else { return }
        steps.append(WorkspaceUndoStep(title: title, snapshot: snapshot))
        if steps.count > limit {
            steps.removeFirst(steps.count - limit)
        }
    }

    @discardableResult
    mutating func popLast() -> WorkspaceUndoStep? {
        steps.popLast()
    }
}
