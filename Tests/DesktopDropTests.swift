// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import Darwin

@main
struct DesktopDropTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { print("FAIL: \(message)"); exit(1) }
            print("PASS: \(message)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = desktop.appendingPathComponent("Zotero.app")
        try Data("fixture".utf8).write(to: url)
        let store = RegionStore(fileURL: root.appendingPathComponent("regions.json"))
        var region = Region.defaultNewRegion(frame: NSRect(x: 100, y: 100, width: 400, height: 500))
        region.allowsCollapse = true
        region.itemBindings = [RegionItemBinding(path: url.path, slotIndex: 0)]
        store.replace(with: [region])
        let visibility = DesktopItemVisibility(journalURL: root.appendingPathComponent("hidden.json"), desktopURL: desktop)
        try visibility.synchronize(regions: store.regions)
        func hidden() -> Bool {
            var info = stat(); _ = lstat(url.path, &info)
            return info.st_flags & UInt32(UF_HIDDEN) != 0
        }
        check(hidden(), "fixture starts hidden behind the bound icon")
        let delegate = AppDelegate(store: store, desktopVisibility: visibility)
        delegate.beginFileDrag(regionID: region.id, urls: [url])
        check(hidden(), "starting a bound-icon drag must not reveal Finder's stale desktop position")
        delegate.endFileDrag(regionID: region.id, urls: [url], operation: [])
        check(hidden() && store.region(id: region.id)!.itemBindings.count == 1,
              "cancelled/rejected drag keeps the source binding and hidden Finder entry")
        check(!NSApp.windows.contains { $0.title == "饭格桌面拖放接收层" && $0.isVisible },
              "drag receiver is removed after cancellation")

        var destination = region.duplicated(name: "Destination", frame: NSRect(x: 600, y: 100, width: 400, height: 500))
        region.itemBindings = []
        destination.itemBindings = [RegionItemBinding(path: url.path, slotIndex: 1)]
        store.replace(with: [region, destination])
        delegate.endFileDrag(regionID: region.id, urls: [url], operation: .move)
        check(store.region(id: destination.id)!.itemBindings.map(\.path) == [url.path] && hidden(),
              "source ended callback preserves ownership assigned by another region")

        let source = RegionFilesView(frame: .zero) { _ in RegionFileAppearance(icon: NSImage(size: NSSize(width: 16, height: 16)), name: "fixture") }
        source.exportsBoundDesktopItems = true
        let receiver = DesktopDropController()
        let realDesktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let candidate = realDesktop.appendingPathComponent("FangeDropPolicyFixture")
        receiver.acceptsPoint = { $0.x < 400 }
        receiver.begin(urls: [candidate])
        let blank = NSPoint(x: 200, y: 300)
        check(receiver.accepts(urls: [candidate], at: blank, source: source, operation: .move),
              "bound Desktop entry has an explicit accepting desktop destination")
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: []),
              "operation.none cannot be interpreted as a successful desktop drop")
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: .copy),
              "copy-only drag cannot accidentally unbind the source")
        check(!receiver.accepts(urls: [candidate], at: NSPoint(x: 500, y: 300), source: source, operation: .move),
              "regions and native Finder icon hit targets are excluded from the blank desktop receiver")
        source.exportsBoundDesktopItems = false
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: .move),
              "mapped-folder sources retain their native Finder Desktop transfer")
        source.exportsBoundDesktopItems = true
        check(!receiver.accepts(urls: [url], at: blank, source: source, operation: .move) &&
              !receiver.accepts(urls: [candidate], at: blank, source: nil, operation: .move),
              "receiver rejects external sources and non-Desktop URLs")
        receiver.end()
        check(!receiver.accepts(urls: [candidate], at: blank, source: source, operation: .move),
              "a finished session cannot accept a later stale drop")

        delegate.endFileDrag(regionID: destination.id, urls: [url], operation: .copy)
        check(hidden() && store.region(id: destination.id)!.itemBindings.count == 1,
              "an external copy preserves the original hidden source and binding")
        let movedURL = root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: url, to: movedURL)
        delegate.endFileDrag(regionID: destination.id, urls: [url], operation: .move)
        var movedInfo = stat(); _ = lstat(movedURL.path, &movedInfo)
        check(store.region(id: destination.id)!.itemBindings.isEmpty && movedInfo.st_flags & UInt32(UF_HIDDEN) == 0,
              "an external move unbinds the original path and restores visibility at the new location")

        // Real Finder regression, using a disposable alias instead of changing
        // the user's Zotero icon or their saved region configuration.
        if ProcessInfo.processInfo.environment["FANGE_LIVE_DROP_TEST"] == "1" {
            let aliasTarget = root.appendingPathComponent("Zotero.app")
            try FileManager.default.createDirectory(at: aliasTarget, withIntermediateDirectories: true)
            let alias = realDesktop.appendingPathComponent("FangeDropRegression-\(UUID().uuidString).app")
            try URL.writeBookmarkData(aliasTarget.bookmarkData(options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil, relativeTo: nil), to: alias)
            defer { try? FileManager.default.removeItem(at: alias) }
            let liveStore = RegionStore(fileURL: root.appendingPathComponent("live-regions.json"))
            var liveRegion = Region.defaultNewRegion(frame: NSRect(x: -5000, y: -5000, width: 400, height: 500))
            liveRegion.allowsCollapse = true
            liveRegion.itemBindings = [RegionItemBinding(path: alias.path, slotIndex: 0)]
            liveStore.replace(with: [liveRegion])
            let liveVisibility = DesktopItemVisibility(journalURL: root.appendingPathComponent("live-hidden.json"), desktopURL: realDesktop)
            try liveVisibility.synchronize(regions: liveStore.regions)
            let live = AppDelegate(store: liveStore, desktopVisibility: liveVisibility)
            live.beginFileDrag(regionID: liveRegion.id, urls: [alias])
            var info = stat(); _ = lstat(alias.path, &info)
            check(info.st_flags & UInt32(UF_HIDDEN) != 0, "real Finder alias stays hidden throughout drag start")
            live.endFileDrag(regionID: liveRegion.id, urls: [alias], operation: [])
            check(liveStore.region(id: liveRegion.id)!.itemBindings.count == 1,
                  "real alias survives an actual source cancellation callback")
            let point = NSPoint(x: NSScreen.screens.first!.visibleFrame.minX + 200,
                                y: NSScreen.screens.first!.visibleFrame.midY)
            check(live.releaseBoundFilesToDesktop([alias], at: point), "real Finder accepts alias placement while it is hidden")
            live.endFileDrag(regionID: liveRegion.id, urls: [alias], operation: .move)
            _ = lstat(alias.path, &info)
            check(info.st_flags & UInt32(UF_HIDDEN) == 0 && liveStore.region(id: liveRegion.id)!.itemBindings.isEmpty,
                  "accepted desktop drop unhides and unbinds the alias after the source callback")
            let reader = NSAppleScript(source: "tell application \"Finder\" to get desktop position of item \"\(alias.lastPathComponent)\" of desktop")!
            var error: NSDictionary?
            let result = reader.executeAndReturnError(&error)
            let expected = NSPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y)
            check(error == nil && abs(CGFloat(result.atIndex(1)!.int32Value) - expected.x) <= 1 &&
                  abs(CGFloat(result.atIndex(2)!.int32Value) - expected.y) <= 1,
                  "Finder reports the requested drop coordinates, not the original stale position")
            let aliasValues = try alias.resourceValues(forKeys: [.isAliasFileKey])
            check(aliasValues.isAliasFile == true &&
                  FileManager.default.fileExists(atPath: aliasTarget.path), "alias identity and original application target are preserved")
        }
    }
}
