// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

struct FinderDesktopItem: Equatable {
    let url: URL
    let position: NSPoint
}

private struct FinderDesktopSnapshot {
    let itemsByPath: [String: FinderDesktopItem]
    let selectedPaths: Set<String>
}

/// Tracks only the Finder positions that this app explicitly requested. This
/// lets a poll suppress the matching app-driven movement without discarding
/// unrelated user movement that happened in the same Finder snapshot.
struct FinderProgrammaticMoveTracker {
    private struct ExpectedMove {
        let position: NSPoint
        let expiresAt: Date
    }

    private var expectedByPath: [String: ExpectedMove] = [:]

    var pendingPaths: Set<String> {
        Set(expectedByPath.keys)
    }

    mutating func register(
        _ positions: [DesktopIconPosition],
        now: Date = Date(),
        lifetime: TimeInterval = 2.0
    ) {
        let expiresAt = now.addingTimeInterval(lifetime)
        for item in positions {
            let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
            expectedByPath[path] = ExpectedMove(
                position: item.position,
                expiresAt: expiresAt
            )
        }
    }

    mutating func fulfilledPaths(
        in current: [String: FinderDesktopItem],
        now: Date = Date(),
        tolerance: CGFloat = 2
    ) -> Set<String> {
        expectedByPath = expectedByPath.filter { _, expected in
            expected.expiresAt >= now
        }
        return Set(expectedByPath.compactMap { path, expected in
            guard let item = current[path],
                  abs(item.position.x - expected.position.x) <= tolerance,
                  abs(item.position.y - expected.position.y) <= tolerance
            else { return nil }
            return path
        })
    }

    mutating func consume(_ paths: Set<String>) {
        for path in paths {
            expectedByPath.removeValue(
                forKey: URL(fileURLWithPath: path).standardizedFileURL.path
            )
        }
    }

    mutating func cancel(_ paths: Set<String>) {
        consume(paths)
    }

    mutating func clear() {
        expectedByPath.removeAll()
    }
}

final class FinderDesktopMonitor {
    var isEnabled = true
    var onSelectedItemsMoved: (([FinderDesktopItem], [FinderDesktopItem]) -> Void)?
    var onSnapshotUpdated: (([FinderDesktopItem], Set<String>) -> Void)?
    private(set) var currentItems: [FinderDesktopItem] = []
    private(set) var currentSelectedPaths = Set<String>()

    private var timer: Timer?
    private var previousItemsByPath: [String: FinderDesktopItem]?
    private var isReading = false
    private var immediatePollRequested = false
    private var rapidPollDeadline: Date?
    private(set) var trackedMovementPaths = Set<String>()
    private var programmaticMoveTracker = FinderProgrammaticMoveTracker()
    private let readerQueue = DispatchQueue(label: "com.ricey.desktop-regions.finder-reader", qos: .utility)

    func start() {
        guard timer == nil else { return }
        // Prime the Finder baseline before the app becomes interactive. Without
        // this, the first mouse-down can happen while currentItems is empty, so
        // the drag path cannot be protected from binding restoration.
        if previousItemsByPath == nil,
           let snapshot = FinderDesktopReader.snapshot() {
            process(snapshot)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousItemsByPath = nil
        trackedMovementPaths.removeAll()
        programmaticMoveTracker.clear()
        immediatePollRequested = false
        rapidPollDeadline = nil
    }

    func expectProgrammaticMoves(_ positions: [DesktopIconPosition]) {
        programmaticMoveTracker.register(positions)
        requestImmediatePoll()
    }

    func cancelExpectedProgrammaticMoves(for paths: Set<String>) {
        programmaticMoveTracker.cancel(paths)
    }

    func trackMovements(for paths: Set<String>) {
        trackedMovementPaths.formUnion(paths)
    }

    func stopTrackingMovements(for paths: Set<String>) {
        trackedMovementPaths.subtract(paths)
        if trackedMovementPaths.isEmpty {
            rapidPollDeadline = nil
        }
    }

    func clearTrackedMovements() {
        trackedMovementPaths.removeAll()
        rapidPollDeadline = nil
    }

    /// Finder may commit a desktop position just after mouse-up. Queue one
    /// immediate read, or one follow-up read if a poll is already in flight.
    func requestImmediatePoll() {
        rapidPollDeadline = Date().addingTimeInterval(0.65)
        enqueuePoll()
    }

    func itemsForWorkspaceSnapshot() -> [FinderDesktopItem] {
        if previousItemsByPath != nil {
            return currentItems
        }
        guard let snapshot = FinderDesktopReader.snapshot() else { return currentItems }
        return Array(snapshot.itemsByPath.values)
    }

    deinit {
        stop()
    }

    private func poll() {
        guard isEnabled,
              !isReading else {
            return
        }

        isReading = true
        readerQueue.async { [weak self] in
            let snapshot = FinderDesktopReader.snapshot()
            DispatchQueue.main.async {
                self?.finishPoll(with: snapshot)
            }
        }
    }

    private func finishPoll(with snapshot: FinderDesktopSnapshot?) {
        isReading = false
        if isEnabled, let snapshot {
            process(snapshot)
        }
        if immediatePollRequested {
            immediatePollRequested = false
            poll()
            return
        }
        guard let rapidPollDeadline,
              Date() < rapidPollDeadline,
              !trackedMovementPaths.isEmpty else {
            self.rapidPollDeadline = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.enqueuePoll()
        }
    }

    private func enqueuePoll() {
        if isReading {
            immediatePollRequested = true
        } else {
            poll()
        }
    }

    private func process(_ snapshot: FinderDesktopSnapshot) {
        currentItems = Array(snapshot.itemsByPath.values)
        currentSelectedPaths = snapshot.selectedPaths

        guard let previousItemsByPath else {
            self.previousItemsByPath = snapshot.itemsByPath
            onSnapshotUpdated?(currentItems, currentSelectedPaths)
            return
        }

        let fulfilledProgrammaticPaths = programmaticMoveTracker.fulfilledPaths(
            in: snapshot.itemsByPath
        )
        let events = FinderDesktopPollEventPipeline.events(
            previous: previousItemsByPath,
            current: snapshot.itemsByPath,
            selectedPaths: snapshot.selectedPaths,
            trackedMovementPaths: trackedMovementPaths,
            ignoredMovementPaths: fulfilledProgrammaticPaths
        )
        self.previousItemsByPath = snapshot.itemsByPath
        programmaticMoveTracker.consume(fulfilledProgrammaticPaths)
        for event in events {
            switch event {
            case let .movement(items, previousItems):
                onSelectedItemsMoved?(items, previousItems)
            case let .snapshot(items, selectedPaths):
                onSnapshotUpdated?(items, selectedPaths)
            }
        }
    }
}

enum FinderDesktopPollEvent: Equatable {
    case movement(items: [FinderDesktopItem], previousItems: [FinderDesktopItem])
    case snapshot(items: [FinderDesktopItem], selectedPaths: Set<String>)

    var isMovement: Bool {
        if case .movement = self { return true }
        return false
    }

    var isSnapshot: Bool {
        if case .snapshot = self { return true }
        return false
    }
}

enum FinderDesktopPollEventPipeline {
    static func events(
        previous: [String: FinderDesktopItem],
        current: [String: FinderDesktopItem],
        selectedPaths: Set<String>,
        trackedMovementPaths: Set<String>,
        ignoredMovementPaths: Set<String> = []
    ) -> [FinderDesktopPollEvent] {
        let currentItems = current.values.sorted { $0.url.path < $1.url.path }
        let changedItems = FinderDesktopChangeDetector.changedItems(
            previous: previous,
            current: current,
            selectedPaths: selectedPaths,
            trackedMovementPaths: trackedMovementPaths,
            ignoredMovementPaths: ignoredMovementPaths
        )
        var events: [FinderDesktopPollEvent] = []
        if !changedItems.isEmpty {
            events.append(.movement(
                items: changedItems,
                previousItems: previous.values.sorted { $0.url.path < $1.url.path }
            ))
        }
        // Movement must be delivered first so AppDelegate can remove or update
        // the old binding before its snapshot handler considers drift repair.
        events.append(.snapshot(items: currentItems, selectedPaths: selectedPaths))
        return events
    }
}

enum FinderDesktopChangeDetector {
    static func changedItems(
        previous: [String: FinderDesktopItem],
        current: [String: FinderDesktopItem],
        selectedPaths: Set<String>,
        trackedMovementPaths: Set<String> = [],
        ignoredMovementPaths: Set<String> = []
    ) -> [FinderDesktopItem] {
        current.compactMap { path, item in
            // A file dragged from a Finder window onto the Desktop is not always
            // left selected. Treat every newly appearing desktop item as a drop.
            guard let oldItem = previous[path] else { return item }
            guard !ignoredMovementPaths.contains(path) else { return nil }
            let isUserMovement = selectedPaths.contains(path) || trackedMovementPaths.contains(path)
            guard isUserMovement, oldItem.position != item.position else { return nil }
            return item
        }.sorted { $0.url.path < $1.url.path }
    }
}

private enum FinderDesktopReader {
    private static let script: NSAppleScript? = {
        let source = """
        tell application "Finder"
            set output to ""
            set selectedItems to selection
            repeat with selectedItem in selectedItems
                try
                    set output to output & "S" & tab & (POSIX path of (selectedItem as alias)) & linefeed
                end try
            end repeat
            set desktopItems to every item of desktop
            set desktopURLs to URL of every item of desktop
            set desktopPositions to desktop position of every item of desktop
            repeat with itemIndex from 1 to count desktopURLs
                set itemPosition to item itemIndex of desktopPositions
                set output to output & "I" & tab & (item itemIndex of desktopURLs) & tab & ((item 1 of itemPosition) as integer) & tab & ((item 2 of itemPosition) as integer) & linefeed
            end repeat
            return output
        end tell
        """
        return NSAppleScript(source: source)
    }()

    static func snapshot() -> FinderDesktopSnapshot? {
        var error: NSDictionary?
        guard let script else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue else { return nil }
        var itemsByPath: [String: FinderDesktopItem] = [:]
        var selectedPaths = Set<String>()
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL.path
        for line in value.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let itemURL: URL
            if let fileURL = URL(string: fields[1]), fileURL.isFileURL {
                itemURL = fileURL.standardizedFileURL
            } else {
                itemURL = URL(fileURLWithPath: fields[1]).standardizedFileURL
            }
            let path = itemURL.path
            if fields[0] == "S" {
                selectedPaths.insert(path)
            } else if fields[0] == "I",
                      fields.count >= 4,
                      let x = Double(fields[2]),
                      let y = Double(fields[3]) {
                let url = itemURL
                guard url.deletingLastPathComponent().path == desktopPath else { continue }
                itemsByPath[path] = FinderDesktopItem(url: url, position: NSPoint(x: x, y: y))
            }
        }
        return FinderDesktopSnapshot(itemsByPath: itemsByPath, selectedPaths: selectedPaths)
    }
}
