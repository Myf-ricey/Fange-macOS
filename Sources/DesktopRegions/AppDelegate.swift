// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PreferenceKey {
        static let usesMacDefaultGrid = "usesMacDefaultGridGlobally"
    }

    let store = RegionStore()
    private var regionWindows: [UUID: RegionWindowController] = [:]
    private var statusItem: NSStatusItem!
    private let finderDesktopMonitor = FinderDesktopMonitor()
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var editMode = false
    private var editMenuItem: NSMenuItem?
    private var repositionWorkItems: [UUID: DispatchWorkItem] = [:]
    private var lastRepositionDates: [UUID: Date] = [:]
    private var hasRestoredBindings = false
    private var globalDragPreviewMonitor: Any?
    private var localInteractionPriorityMonitor: Any?
    private var finderDragPreviewActive = false
    private var draggedItemCandidatePaths = Set<String>()
    private var dragAvailabilityState = FinderDragAvailabilityState()
    private var pendingDragCleanupWorkItem: DispatchWorkItem?
    private(set) var usesMacDefaultGrid = false
    private let loginItemManager = LoginItemManager()
    private var undoHistory = WorkspaceUndoHistory(limit: 50)
    private var isApplyingUndo = false

    var loginItemState: LoginItemState {
        loginItemManager.state
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(activateFromDuplicateLaunch(_:)),
            name: AppInstanceCoordinator.activationNotification,
            object: AppInstanceCoordinator.bundleIdentifier,
            suspensionBehavior: .deliverImmediately
        )
        loginItemManager.refreshEnabledItemPath()

        if store.isEmpty {
            let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            store.replace(with: RegionStore.defaultRegions(in: frame))
        }

        loadAndApplyGlobalGridPreference()

        setupStatusItem()
        rebuildRegionWindows()
        finderDesktopMonitor.onSelectedItemsMoved = { [weak self] items, previousItems in
            self?.handleMovedDesktopItems(items, previousItems: previousItems)
        }
        finderDesktopMonitor.onSnapshotUpdated = { [weak self] items, selectedPaths in
            self?.handleFinderSnapshot(items: items, selectedPaths: selectedPaths)
        }
        finderDesktopMonitor.start()
        installGlobalDragPreviewMonitor()
        installLocalInteractionPriorityMonitor()
        if CommandLine.arguments.contains("--enable-login-item") {
            DispatchQueue.main.async { [weak self] in
                self?.setLaunchAtLoginEnabled(true)
            }
        }
        let hasShownWelcomeKey = "hasShownWelcomeForInteractiveDesktopRegions"
        if CommandLine.arguments.contains("--settings") || !UserDefaults.standard.bool(forKey: hasShownWelcomeKey) {
            UserDefaults.standard.set(true, forKey: hasShownWelcomeKey)
            DispatchQueue.main.async { [weak self] in
                self?.openSettings()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(appDelegate: self)
        }
        settingsWindow?.refresh()
        settingsWindow?.setEditMode(editMode)
        settingsWindow?.expandFromEdge()
    }

    @objc func toggleEditMode() {
        editMode.toggle()
        finderDesktopMonitor.isEnabled = RegionInteractionPolicy(editMode: editMode).monitorsFinderDesktopPositions
        regionWindows.values.forEach { $0.setEditMode(editMode) }
        if editMode {
            endFinderDragPreview()
        }
        updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
        let editMenuPresentation = EditModeMenuPresentation(editMode: editMode)
        editMenuItem?.title = editMenuPresentation.title
        editMenuItem?.state = editMenuPresentation.state
        settingsWindow?.setEditMode(editMode)
        settingsWindow?.setStatus(editMode ? "编辑模式已开启：拖动区块或把桌面文件拖入区块" : "编辑模式已关闭")
        if editMode {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let controller = self.store.regions
                    .first(where: { !$0.itemBindings.isEmpty })
                    .flatMap { self.regionWindows[$0.id] }
                    ?? self.regionWindows.values.first
                controller?.activateInteractionSurface()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingDragCleanupWorkItem?.cancel()
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: AppInstanceCoordinator.activationNotification,
            object: AppInstanceCoordinator.bundleIdentifier
        )
        if let globalDragPreviewMonitor {
            NSEvent.removeMonitor(globalDragPreviewMonitor)
        }
        if let localInteractionPriorityMonitor {
            NSEvent.removeMonitor(localInteractionPriorityMonitor)
        }
    }

    @objc private func activateFromDuplicateLaunch(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    @objc func undoLastAction() {
        guard let step = undoHistory.nextStep else { return }

        repositionWorkItems.values.forEach { $0.cancel() }
        repositionWorkItems.removeAll()
        lastRepositionDates.removeAll()
        pendingDragCleanupWorkItem?.cancel()
        pendingDragCleanupWorkItem = nil
        isApplyingUndo = true
        defer { isApplyingUndo = false }

        if let error = restoreDesktopIconPositionsProgrammatically(
            step.snapshot.desktopIconPositions
        ) {
            showError(error)
            return
        }

        _ = undoHistory.popLast()
        usesMacDefaultGrid = step.snapshot.usesMacDefaultGrid
        UserDefaults.standard.set(
            usesMacDefaultGrid,
            forKey: PreferenceKey.usesMacDefaultGrid
        )
        store.replace(with: step.snapshot.regions)
        dragAvailabilityState.endDrag()
        dragAvailabilityState.clearPendingConfirmation()
        finderDesktopMonitor.clearTrackedMovements()
        draggedItemCandidatePaths.removeAll()
        finderDragPreviewActive = false
        rebuildRegionWindows()
        settingsWindow?.refresh()
        settingsWindow?.setMacDefaultGridEnabled(usesMacDefaultGrid)
        settingsWindow?.setStatus("已撤销：\(step.title)")
        rebuildStatusMenu()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            let state = try loginItemManager.setEnabled(enabled)
            settingsWindow?.setLaunchAtLoginState(state)
            switch state {
            case .enabled:
                settingsWindow?.setStatus("饭格将在登录 Mac 时自动启动")
            case .disabled:
                settingsWindow?.setStatus("已关闭登录时自动启动")
            case .unavailable:
                settingsWindow?.setStatus("暂时无法修改登录项，请重新打开饭格后再试")
            }
        } catch {
            settingsWindow?.setLaunchAtLoginState(loginItemManager.state)
            showError(error)
        }
    }

    func addRegion() {
        let undoSnapshot = makeWorkspaceSnapshot()
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let base = store.regions.last?.frame ?? NSRect(
            x: screenFrame.minX + 48,
            y: screenFrame.minY + 48,
            width: 262,
            height: 425
        )
        let cascadeOffset = CGFloat((store.regions.count % 5) * 24)
        let defaultSize = NSSize(width: 262, height: 425)
        let desiredFrame = NSRect(
            x: base.minX + cascadeOffset,
            y: base.minY - cascadeOffset,
            width: defaultSize.width,
            height: defaultSize.height
        )
        let newFrame = frame(desiredFrame, clampedInside: screenFrame)
        var region = Region.defaultNewRegion(frame: newFrame)
        region.usesMacDefaultGrid = usesMacDefaultGrid
        if usesMacDefaultGrid {
            let metrics = FinderDesktopGridMetrics.current()
            region.setFrame(RegionLayout.snappedMacGridFrame(
                near: newFrame,
                region: region,
                visibleFrame: screenFrame,
                metrics: metrics,
                avoiding: store.regions.map { RegionLayout.visualCollisionFrame(for: $0, metrics: metrics) }
            ))
        }
        store.add(region)
        recordUndoStep(title: "新增分区", snapshot: undoSnapshot)
        rebuildRegionWindows()
        settingsWindow?.refresh()
    }

    func duplicateRegion(id: UUID) {
        guard let source = store.region(id: id) else { return }
        let undoSnapshot = makeWorkspaceSnapshot()
        let screenFrame = (
            screen(containing: source.frame) ?? NSScreen.main ?? NSScreen.screens.first
        )?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let desiredFrame = source.frame.offsetBy(dx: 24, dy: -24)
        var duplicate = source.duplicated(
            name: "\(source.name) 副本",
            frame: frame(desiredFrame, clampedInside: screenFrame)
        )
        duplicate.usesMacDefaultGrid = usesMacDefaultGrid
        if usesMacDefaultGrid {
            let metrics = FinderDesktopGridMetrics.current()
            duplicate.setFrame(RegionLayout.snappedMacGridFrame(
                near: duplicate.frame,
                region: duplicate,
                visibleFrame: screenFrame,
                metrics: metrics,
                avoiding: store.regions.map {
                    RegionLayout.visualCollisionFrame(for: $0, metrics: metrics)
                }
            ))
        }
        store.add(duplicate)
        recordUndoStep(title: "复制分区", snapshot: undoSnapshot)
        rebuildRegionWindows()
        settingsWindow?.refresh()
        settingsWindow?.setStatus("已创建“\(duplicate.name)”")
    }

    func mutateRegion(
        id: UUID,
        actionName: String = "修改分区",
        _ mutation: (inout Region) -> Void
    ) {
        guard let previous = store.region(id: id) else { return }
        let undoSnapshot = makeWorkspaceSnapshot()
        let metrics = FinderDesktopGridMetrics.current()
        let occupiedFrames = store.regions
            .filter { $0.id != id }
            .map { RegionLayout.visualCollisionFrame(for: $0, metrics: metrics) }
        store.mutate(id: id) { region in
            mutation(&region)
            region.usesMacDefaultGrid = self.usesMacDefaultGrid
            if MacDefaultGridPreferencePolicy.shouldExitPreservedGeometry(
                previous: previous,
                updated: region
            ) {
                region.preservesMacGridGeometry = false
            }
            normalizeBindings(in: &region)
            if region.usesMacDefaultGrid {
                let screen = self.screen(containing: region.frame) ?? NSScreen.main ?? NSScreen.screens.first
                if let screen {
                    region.setFrame(RegionLayout.snappedMacGridFrame(
                        near: region.frame,
                        region: region,
                        visibleFrame: screen.visibleFrame,
                        metrics: metrics,
                        avoiding: occupiedFrames
                    ))
                }
            }
        }
        guard let updated = store.region(id: id) else { return }
        if updated != previous {
            recordUndoStep(title: actionName, snapshot: undoSnapshot)
        }
        regionWindows[id]?.update(with: updated)
        settingsWindow?.updateRegionRow(updated)
        settingsWindow?.updateAdvancedEditor(updated)
        rebuildStatusMenu()
        refreshAvailableSlots()

        if RegionLayout.globalSlotCenters(in: previous)
            != RegionLayout.globalSlotCenters(in: updated) {
            scheduleBoundItemReposition(regionID: id, reason: .regionGeometryChanged)
        }
    }

    func setMacDefaultGridEnabled(_ enabled: Bool) {
        guard enabled != usesMacDefaultGrid else {
            settingsWindow?.setMacDefaultGridEnabled(enabled)
            return
        }
        let undoSnapshot = makeWorkspaceSnapshot()
        usesMacDefaultGrid = enabled
        UserDefaults.standard.set(enabled, forKey: PreferenceKey.usesMacDefaultGrid)
        applyGlobalGridPreference(repositionBoundItems: true)
        settingsWindow?.setMacDefaultGridEnabled(enabled)
        settingsWindow?.refresh()
        for region in store.regions {
            settingsWindow?.updateAdvancedEditor(region)
        }
        recordUndoStep(
            title: enabled ? "启用 Mac 默认网格" : "关闭 Mac 默认网格",
            snapshot: undoSnapshot
        )
        settingsWindow?.setStatus(
            enabled
                ? "所有分区已采用 Finder 桌面默认网格"
                : "已关闭 Finder 网格；分区尺寸与间距现在可单独调整"
        )
    }

    func openAdvancedSettings(for id: UUID) {
        openSettings()
        settingsWindow?.expandFromEdge()
        settingsWindow?.showAdvancedSettings(for: id)
    }

    func deleteRegion(id: UUID) {
        guard store.regions.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "至少保留一个区域"
            alert.informativeText = "饭格需要一个背景区域才能正常工作。"
            alert.runModal()
            return
        }
        let undoSnapshot = makeWorkspaceSnapshot()
        regionWindows[id]?.close()
        regionWindows.removeValue(forKey: id)
        repositionWorkItems[id]?.cancel()
        repositionWorkItems.removeValue(forKey: id)
        lastRepositionDates.removeValue(forKey: id)
        store.remove(id: id)
        recordUndoStep(title: "删除分区", snapshot: undoSnapshot)
        settingsWindow?.refresh()
        rebuildStatusMenu()
        refreshAvailableSlots()
    }

    private func rebuildRegionWindows() {
        let ids = Set(store.regions.map(\.id))
        for (id, controller) in regionWindows where !ids.contains(id) {
            controller.close()
            regionWindows.removeValue(forKey: id)
        }

        for region in store.regions {
            if let controller = regionWindows[region.id] {
                controller.update(with: region)
                controller.setEditMode(editMode)
            } else {
                let controller = RegionWindowController(region: region, editMode: editMode)
                controller.onFrameChanged = { [weak self] id, frame in
                    self?.regionFrameChanged(id: id, frame: frame)
                }
                controller.onFilesDropped = { [weak self] id, urls, globalPoint in
                    self?.filesDropped(urls, into: id, near: globalPoint)
                }
                controller.onMoreRequested = { [weak self] id in
                    self?.openAdvancedSettings(for: id)
                }
                controller.onMacGridFrameRequested = { [weak self] id, proposedFrame, prefersTopOverflow in
                    self?.resolvedMacGridFrame(
                        regionID: id,
                        near: proposedFrame,
                        prefersTopOverflow: prefersTopOverflow
                    ) ?? proposedFrame
                }
                controller.onInteractionMouseMoved = { [weak self] point in
                    self?.updateEditInteractionHitTesting(at: point)
                }
                regionWindows[region.id] = controller
                controller.show()
            }
        }
        updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
        refreshAvailableSlots()
        rebuildStatusMenu()
    }

    private func regionFrameChanged(id: UUID, frame: NSRect) {
        mutateRegion(id: id, actionName: "移动或缩放分区") { region in
            region.setFrame(frame)
        }
    }

    private func resolvedMacGridFrame(
        regionID: UUID,
        near proposedFrame: NSRect,
        prefersTopOverflow: Bool
    ) -> NSRect {
        guard var region = store.region(id: regionID) else { return proposedFrame }
        region.setFrame(proposedFrame)
        guard let screen = screen(containing: proposedFrame) ?? NSScreen.main ?? NSScreen.screens.first else {
            return proposedFrame
        }
        let metrics = FinderDesktopGridMetrics.current()
        return RegionLayout.snappedMacGridFrame(
            near: proposedFrame,
            region: region,
            visibleFrame: screen.visibleFrame,
            metrics: metrics,
            avoiding: store.regions
                .filter { $0.id != regionID }
                .map { RegionLayout.visualCollisionFrame(for: $0, metrics: metrics) },
            prefersTopOverflow: prefersTopOverflow
        )
    }

    private func loadAndApplyGlobalGridPreference() {
        let defaults = UserDefaults.standard
        let hasPersistedValue = defaults.object(forKey: PreferenceKey.usesMacDefaultGrid) != nil
        let persistedValue = hasPersistedValue
            ? defaults.bool(forKey: PreferenceKey.usesMacDefaultGrid)
            : nil
        // One-time migration from the short-lived per-region version.  If any
        // region had it enabled, preserve the user's choice globally.
        usesMacDefaultGrid = MacDefaultGridPreferencePolicy.resolvedValue(
            persistedValue: persistedValue,
            regions: store.regions
        )
        if !hasPersistedValue {
            defaults.set(usesMacDefaultGrid, forKey: PreferenceKey.usesMacDefaultGrid)
        }
        applyGlobalGridPreference(repositionBoundItems: false)
    }

    private func applyGlobalGridPreference(repositionBoundItems: Bool) {
        let metrics = FinderDesktopGridMetrics.current()
        let previousRegions = Dictionary(uniqueKeysWithValues: store.regions.map { ($0.id, $0) })
        var occupiedFrames: [NSRect] = []
        let synchronizedRegions = MacDefaultGridPreferencePolicy.synchronizing(
            store.regions,
            enabled: usesMacDefaultGrid
        )
        let updatedRegions = synchronizedRegions.map { storedRegion -> Region in
            var region = storedRegion
            if usesMacDefaultGrid,
               let screen = screen(containing: region.frame) ?? NSScreen.main ?? NSScreen.screens.first {
                region.setFrame(RegionLayout.snappedMacGridFrame(
                    near: region.frame,
                    region: region,
                    visibleFrame: screen.visibleFrame,
                    metrics: metrics,
                    avoiding: occupiedFrames
                ))
            }
            occupiedFrames.append(RegionLayout.visualCollisionFrame(for: region, metrics: metrics))
            return region
        }
        store.replace(with: updatedRegions)

        for region in updatedRegions {
            regionWindows[region.id]?.update(with: region)
            settingsWindow?.updateRegionRow(region)
            if repositionBoundItems,
               let previous = previousRegions[region.id],
               RegionLayout.globalSlotCenters(in: previous)
                != RegionLayout.globalSlotCenters(in: region) {
                scheduleBoundItemReposition(regionID: region.id, reason: .regionGeometryChanged)
            }
        }
        refreshAvailableSlots()
        rebuildStatusMenu()
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { lhs, rhs in
                lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
                    < rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
            }
    }

    private func frame(_ proposed: NSRect, clampedInside visible: NSRect) -> NSRect {
        let width = min(proposed.width, visible.width)
        let height = min(proposed.height, visible.height)
        return NSRect(
            x: min(max(proposed.minX, visible.minX), visible.maxX - width),
            y: min(max(proposed.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }

    private func filesDropped(_ urls: [URL], into id: UUID, near globalPoint: NSPoint) {
        guard let region = store.region(id: id),
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        guard RegionLayout.dropTargetRegion(
            at: globalPoint,
            in: store.regions
        )?.id == id else { return }
        let uniqueURLs = uniqueDesktopURLs(urls)
        guard !uniqueURLs.isEmpty, uniqueURLs.allSatisfy(isDesktopURL) else {
            showError(desktopOnlyError())
            return
        }
        let movingPaths = Set(uniqueURLs.map { $0.standardizedFileURL.path })
        var occupied = occupiedSlotIndices(in: region, excludingPaths: movingPaths)
        var slotIndices: [Int] = []
        for _ in uniqueURLs {
            guard let slot = RegionLayout.nearestAvailableSlot(
                to: globalPoint,
                in: region,
                excluding: occupied
            ) else {
                showError(noFreeSlotError(for: region))
                return
            }
            occupied.insert(slot)
            slotIndices.append(slot)
        }
        let undoSnapshot = makeWorkspaceSnapshot()
        if let error = moveDesktopItemsProgrammatically(
            uniqueURLs,
            toSlotIndices: slotIndices,
            in: region,
            screen: screen
        ) {
            showError(error)
            return
        }
        commitBindings(regionID: id, urls: uniqueURLs, slotIndices: slotIndices)
        dragAvailabilityState.confirm(paths: movingPaths)
        finderDesktopMonitor.stopTrackingMovements(for: movingPaths)
        if dragAvailabilityState.pendingConfirmationPaths.isEmpty {
            pendingDragCleanupWorkItem?.cancel()
            pendingDragCleanupWorkItem = nil
        }
        recordUndoStep(title: "把图标放入分区", snapshot: undoSnapshot)
        regionWindows[id]?.showDropFeedback()
        settingsWindow?.setStatus("已将 \(uniqueURLs.count) 个桌面图标放入“\(region.name)”")
    }

    private func handleMovedDesktopItems(
        _ items: [FinderDesktopItem],
        previousItems: [FinderDesktopItem]
    ) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let undoSnapshot = makeWorkspaceSnapshot(finderItems: previousItems)
        let movingPaths = Set(items.map { $0.url.standardizedFileURL.path })
        let temporarilyReleasedPaths = dragAvailabilityState.excludedPaths(
            selectedPaths: movingPaths
        )
        var occupiedByRegion = Dictionary(uniqueKeysWithValues: store.regions.map {
            ($0.id, occupiedSlotIndices(in: $0, excludingPaths: temporarilyReleasedPaths))
        })
        var placements: [UUID: [(item: FinderDesktopItem, slotIndex: Int)]] = [:]
        var pathsToUnbind = Set<String>()

        for item in items {
            let path = item.url.standardizedFileURL.path
            let globalPoint = globalPoint(forFinderPosition: item.position, screen: screen)
            guard let region = RegionLayout.dropTargetRegion(
                at: globalPoint,
                in: store.regions
            ) else {
                pathsToUnbind.insert(path)
                continue
            }
            let occupied = occupiedByRegion[region.id] ?? []
            guard let slotIndex = RegionLayout.nearestAvailableSlot(
                to: globalPoint,
                in: region,
                excluding: occupied
            ) else {
                showError(noFreeSlotError(for: region))
                continue
            }
            occupiedByRegion[region.id, default: []].insert(slotIndex)
            placements[region.id, default: []].append((item, slotIndex))
        }

        var successfulPlacements: [(regionID: UUID, urls: [URL], slots: [Int])] = []
        for (regionID, values) in placements {
            guard let region = store.region(id: regionID) else { continue }
            let urls = values.map(\.item.url)
            let slots = values.map(\.slotIndex)
            if let error = moveDesktopItemsProgrammatically(
                urls,
                toSlotIndices: slots,
                in: region,
                screen: screen
            ) {
                showError(error)
                continue
            }
            successfulPlacements.append((regionID, urls, slots))
            regionWindows[regionID]?.showDropFeedback()
            settingsWindow?.setStatus("已将 \(urls.count) 个桌面图标吸附到“\(region.name)”")
        }

        let placedPaths = Set(successfulPlacements.flatMap { $0.urls.map { $0.standardizedFileURL.path } })
        pathsToUnbind.subtract(placedPaths)
        if !pathsToUnbind.isEmpty {
            removeBindings(forPaths: pathsToUnbind)
            settingsWindow?.setStatus("已解除 \(pathsToUnbind.count) 个桌面图标与分区的绑定")
        }
        for placement in successfulPlacements {
            commitBindings(regionID: placement.regionID, urls: placement.urls, slotIndices: placement.slots)
        }
        if !successfulPlacements.isEmpty || !pathsToUnbind.isEmpty {
            recordUndoStep(title: "移动桌面图标", snapshot: undoSnapshot)
        }
        dragAvailabilityState.confirm(paths: movingPaths)
        finderDesktopMonitor.stopTrackingMovements(for: movingPaths)
        if dragAvailabilityState.pendingConfirmationPaths.isEmpty {
            pendingDragCleanupWorkItem?.cancel()
            pendingDragCleanupWorkItem = nil
        }
        refreshAvailableSlots()
    }

    private func handleFinderSnapshot(items: [FinderDesktopItem], selectedPaths: Set<String>) {
        let isInitialSnapshot = !hasRestoredBindings
        if !hasRestoredBindings {
            hasRestoredBindings = true
            pruneMissingBindings(using: items)
            store.regions.forEach {
                scheduleBoundItemReposition(regionID: $0.id, reason: .restoreBindings)
            }
        }
        if !isInitialSnapshot {
            restoreDriftedBindings(items: items, selectedPaths: selectedPaths)
        }
        if finderDragPreviewActive {
            updateFinderDragPreview(at: NSEvent.mouseLocation)
        } else {
            refreshAvailableSlots()
        }
        updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
    }

    private func restoreDriftedBindings(
        items: [FinderDesktopItem],
        selectedPaths: Set<String>
    ) {
        guard !editMode,
              !isApplyingUndo,
              let screen = NSScreen.main ?? NSScreen.screens.first
        else { return }

        let currentByPath = Dictionary(uniqueKeysWithValues: items.map {
            ($0.url.standardizedFileURL.path, $0.position)
        })
        let protectedPaths = dragAvailabilityState.excludedPaths(
            selectedPaths: selectedPaths
        )
        for region in store.regions where !region.itemBindings.isEmpty {
            let targets = RegionLayout.finderIconPositions(
                in: region,
                screenFrame: screen.frame,
                count: Int.max
            )
            let hasDrift = region.itemBindings.contains { binding in
                guard binding.isExplicit,
                      targets.indices.contains(binding.slotIndex)
                else { return false }
                return FinderBindingDriftPolicy.hasDrift(
                    current: currentByPath[binding.path],
                    target: targets[binding.slotIndex],
                    isSelected: protectedPaths.contains(binding.path)
                )
            }
            if hasDrift {
                scheduleBoundItemReposition(regionID: region.id, reason: .finderDrift)
            }
        }
    }

    private func installGlobalDragPreviewMonitor() {
        guard globalDragPreviewMonitor == nil else { return }
        globalDragPreviewMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleGlobalMouseEvent(event)
            }
        }
    }

    private func installLocalInteractionPriorityMonitor() {
        guard localInteractionPriorityMonitor == nil else { return }
        localInteractionPriorityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
        case .leftMouseDown:
            updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
            draggedItemCandidatePaths = desktopItemPaths(near: NSEvent.mouseLocation)
            // Protect the source binding immediately. A launch-time restore or
            // drift repair can otherwise run between mouse-down and the first
            // dragged event and pull the icon back before Finder commits it.
            dragAvailabilityState.beginPress(candidatePaths: draggedItemCandidatePaths)
        case .leftMouseDragged:
            updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
            let finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
            guard FinderDragPreviewPolicy.shouldActivate(
                editMode: editMode,
                finderIsFrontmost: finderIsFrontmost,
                hasDesktopItemCandidate: !draggedItemCandidatePaths.isEmpty
            ) else {
                if finderDragPreviewActive || !draggedItemCandidatePaths.isEmpty {
                    endFinderDragPreview()
                }
                return
            }
            pendingDragCleanupWorkItem?.cancel()
            pendingDragCleanupWorkItem = nil
            dragAvailabilityState.beginDrag(candidatePaths: draggedItemCandidatePaths)
            finderDesktopMonitor.trackMovements(for: draggedItemCandidatePaths)
            finderDragPreviewActive = true
            updateFinderDragPreview(at: NSEvent.mouseLocation)
        case .leftMouseUp:
            endFinderDragPreview()
            updateEditInteractionHitTesting(at: NSEvent.mouseLocation)
        default:
            break
        }
    }

    private func updateFinderDragPreview(at mousePoint: NSPoint) {
        let excludedPaths = dragAvailabilityState.excludedPaths(
            selectedPaths: finderDesktopMonitor.currentSelectedPaths
                .union(draggedItemCandidatePaths)
        )
        refreshAvailableSlots(excludingPaths: excludedPaths)
        let hoveredRegion = RegionLayout.dropTargetRegion(
            at: mousePoint,
            in: store.regions
        )
        for region in store.regions {
            let occupied = occupiedSlotIndices(in: region, excludingPaths: excludedPaths)
            let hoveredSlot = hoveredRegion?.id == region.id
                ? RegionLayout.nearestAvailableSlot(to: mousePoint, in: region, excluding: occupied)
                : nil
            regionWindows[region.id]?.setFinderDragPreview(
                active: hoveredRegion?.id == region.id,
                hoveredSlotIndex: hoveredSlot
            )
        }
    }

    private func endFinderDragPreview() {
        guard finderDragPreviewActive || !draggedItemCandidatePaths.isEmpty else { return }
        let needsMovementConfirmation = !dragAvailabilityState.pendingConfirmationPaths.isEmpty
        finderDragPreviewActive = false
        dragAvailabilityState.endDrag()
        draggedItemCandidatePaths.removeAll()
        regionWindows.values.forEach { $0.setFinderDragPreview(active: false) }
        refreshAvailableSlots()
        schedulePendingDragCleanup()
        if needsMovementConfirmation {
            finderDesktopMonitor.requestImmediatePoll()
        }
    }

    private func desktopItemPaths(near mousePoint: NSPoint) -> Set<String> {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return [] }
        let candidates = finderDesktopMonitor.currentItems.map { item in
            FinderDragCandidate(
                path: item.url.standardizedFileURL.path,
                iconCenter: globalPoint(forFinderPosition: item.position, screen: screen)
            )
        }
        return FinderDragCandidatePolicy.candidatePaths(
            at: mousePoint,
            candidates: candidates,
            iconSize: FinderDesktopGridMetrics.current().iconSize
        )
    }

    private func schedulePendingDragCleanup() {
        pendingDragCleanupWorkItem?.cancel()
        guard !dragAvailabilityState.pendingConfirmationPaths.isEmpty else {
            pendingDragCleanupWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dragAvailabilityState.clearPendingConfirmation()
            self.finderDesktopMonitor.clearTrackedMovements()
            self.pendingDragCleanupWorkItem = nil
            self.refreshAvailableSlots()
        }
        pendingDragCleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func updateEditInteractionHitTesting(at mousePoint: NSPoint) {
        guard editMode,
              let screen = NSScreen.main ?? NSScreen.screens.first
        else { return }
        let metrics = FinderDesktopGridMetrics.current()
        let iconCenters = finderDesktopMonitor.currentItems.map {
            globalPoint(forFinderPosition: $0.position, screen: screen)
        }
        let isOverControlWindow = NSApp.windows.contains { window in
            window.isVisible &&
                !window.ignoresMouseEvents &&
                !(window is UnconstrainedRegionWindow) &&
                window.frame.contains(mousePoint)
        }
        regionWindows.values.forEach {
            $0.updateEditInteractionPassthrough(
                at: mousePoint,
                desktopIconCenters: iconCenters,
                iconSize: metrics.iconSize,
                isOverControlWindow: isOverControlWindow
            )
        }
    }

    private func refreshAvailableSlots(excludingPaths: Set<String> = []) {
        let effectiveExcludedPaths = dragAvailabilityState.excludedPaths(
            selectedPaths: excludingPaths
        )
        for region in store.regions {
            let capacity = min(12, max(1, region.gridColumns)) * min(12, max(1, region.gridRows))
            let allSlots = Set(0..<capacity)
            let occupied = occupiedSlotIndices(in: region, excludingPaths: effectiveExcludedPaths)
            regionWindows[region.id]?.setAvailableSlots(allSlots.subtracting(occupied))
        }
    }

    private func occupiedSlotIndices(in region: Region, excludingPaths: Set<String>) -> Set<Int> {
        RegionBindingPolicy.occupiedSlotIndices(in: region, excludingPaths: excludingPaths)
    }

    private func commitBindings(regionID: UUID, urls: [URL], slotIndices: [Int]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        var regions = store.regions
        for index in regions.indices {
            regions[index].itemBindings.removeAll { paths.contains($0.path) }
        }
        guard let targetIndex = regions.firstIndex(where: { $0.id == regionID }) else { return }
        for (url, slotIndex) in zip(urls, slotIndices) {
            regions[targetIndex].itemBindings.append(
                RegionItemBinding(path: url.standardizedFileURL.path, slotIndex: slotIndex)
            )
        }
        normalizeBindings(in: &regions[targetIndex])
        store.replace(with: regions)
        syncRegionsAfterStoreChange()
    }

    private func removeBindings(forPaths paths: Set<String>) {
        guard !paths.isEmpty else { return }
        var regions = store.regions
        var changed = false
        for index in regions.indices {
            let oldCount = regions[index].itemBindings.count
            regions[index].itemBindings.removeAll { paths.contains($0.path) }
            changed = changed || oldCount != regions[index].itemBindings.count
        }
        guard changed else { return }
        store.replace(with: regions)
        syncRegionsAfterStoreChange()
    }

    private func normalizeBindings(in region: inout Region) {
        let capacity = min(12, max(1, region.gridColumns)) * min(12, max(1, region.gridRows))
        var usedSlots = Set<Int>()
        var seenPaths = Set<String>()
        var normalized: [RegionItemBinding] = []
        for binding in region.itemBindings where binding.isExplicit {
            guard !seenPaths.contains(binding.path) else { continue }
            let slot: Int?
            if (0..<capacity).contains(binding.slotIndex), !usedSlots.contains(binding.slotIndex) {
                slot = binding.slotIndex
            } else {
                slot = (0..<capacity).first(where: { !usedSlots.contains($0) })
            }
            guard let slot else { break }
            seenPaths.insert(binding.path)
            usedSlots.insert(slot)
            normalized.append(
                RegionItemBinding(
                    path: binding.path,
                    slotIndex: slot,
                    isExplicit: binding.isExplicit
                )
            )
        }
        region.itemBindings = normalized
    }

    private func syncRegionsAfterStoreChange() {
        for region in store.regions {
            regionWindows[region.id]?.update(with: region)
            settingsWindow?.updateRegionRow(region)
            settingsWindow?.updateAdvancedEditor(region)
        }
        refreshAvailableSlots()
    }

    private func pruneMissingBindings(using items: [FinderDesktopItem]) {
        let existingPaths = Set(items.map { $0.url.standardizedFileURL.path })
        var regions = store.regions
        var changed = false
        for index in regions.indices {
            let capacity = min(12, max(1, regions[index].gridColumns)) * min(12, max(1, regions[index].gridRows))
            let validated = RegionBindingPolicy.validBindings(
                regions[index].itemBindings,
                existingPaths: existingPaths,
                capacity: capacity
            )
            changed = changed || validated != regions[index].itemBindings
            regions[index].itemBindings = validated
        }
        if changed {
            store.replace(with: regions)
            syncRegionsAfterStoreChange()
        }
    }

    private func scheduleBoundItemReposition(
        regionID: UUID,
        reason: BoundItemRepositionReason
    ) {
        repositionWorkItems[regionID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.repositionWorkItems.removeValue(forKey: regionID)
            self?.lastRepositionDates[regionID] = Date()
            self?.repositionBoundItems(regionID: regionID, reason: reason)
        }
        repositionWorkItems[regionID] = workItem
        let elapsed = Date().timeIntervalSince(lastRepositionDates[regionID] ?? .distantPast)
        let delay = max(0, 0.14 - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func repositionBoundItems(
        regionID: UUID,
        reason: BoundItemRepositionReason
    ) {
        guard let region = store.region(id: regionID),
              !region.itemBindings.isEmpty,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let finderPositions = RegionLayout.finderIconPositions(in: region, screenFrame: screen.frame, count: Int.max)
        let currentByPath = Dictionary(uniqueKeysWithValues: finderDesktopMonitor.currentItems.map {
            ($0.url.standardizedFileURL.path, $0.position)
        })
        let validBindings = region.itemBindings.filter {
            $0.isExplicit &&
            finderPositions.indices.contains($0.slotIndex) &&
            FileManager.default.fileExists(atPath: $0.path) &&
            !dragAvailabilityState.excludedPaths(
                selectedPaths: finderDesktopMonitor.currentSelectedPaths
            ).contains($0.path)
        }
        let bindingsToMove: [RegionItemBinding]
        if reason.canSkipItemsMatchingFinderSnapshot {
            bindingsToMove = validBindings.filter { binding in
                guard let current = currentByPath[binding.path] else { return true }
                let target = finderPositions[binding.slotIndex]
                return abs(current.x - CGFloat(target.x)) > 2 || abs(current.y - CGFloat(target.y)) > 2
            }
        } else {
            bindingsToMove = validBindings
        }
        guard !bindingsToMove.isEmpty else { return }
        let urls = bindingsToMove.map { URL(fileURLWithPath: $0.path) }
        let slots = bindingsToMove.map(\.slotIndex)
        if let error = moveDesktopItemsProgrammatically(
            urls,
            toSlotIndices: slots,
            in: region,
            screen: screen
        ) {
            showError(error)
        }
    }

    private func moveDesktopItemsProgrammatically(
        _ urls: [URL],
        toSlotIndices slotIndices: [Int],
        in region: Region,
        screen: NSScreen
    ) -> Error? {
        let targets = RegionLayout.finderIconPositions(
            in: region,
            screenFrame: screen.frame,
            count: Int.max
        )
        let expectedPositions = zip(urls, slotIndices).compactMap { url, slotIndex -> DesktopIconPosition? in
            guard targets.indices.contains(slotIndex) else { return nil }
            let target = targets[slotIndex]
            return DesktopIconPosition(
                path: url.standardizedFileURL.path,
                position: NSPoint(x: target.x, y: target.y)
            )
        }
        finderDesktopMonitor.expectProgrammaticMoves(expectedPositions)
        let error = DesktopArranger.moveDesktopItems(
            urls,
            toSlotIndices: slotIndices,
            in: region,
            screen: screen
        )
        if error != nil {
            finderDesktopMonitor.cancelExpectedProgrammaticMoves(
                for: Set(expectedPositions.map(\.path))
            )
        }
        return error
    }

    private func restoreDesktopIconPositionsProgrammatically(
        _ positions: [DesktopIconPosition]
    ) -> Error? {
        finderDesktopMonitor.expectProgrammaticMoves(positions)
        let error = DesktopArranger.restoreDesktopIconPositions(positions)
        if error != nil {
            finderDesktopMonitor.cancelExpectedProgrammaticMoves(
                for: Set(positions.map(\.path))
            )
        }
        return error
    }

    private func uniqueDesktopURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    private func isDesktopURL(_ url: URL) -> Bool {
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return false
        }
        return url.deletingLastPathComponent().standardizedFileURL.path == desktopURL.standardizedFileURL.path
    }

    private func globalPoint(forFinderPosition position: NSPoint, screen: NSScreen) -> NSPoint {
        NSPoint(
            x: screen.frame.minX + position.x,
            y: screen.frame.maxY - position.y
        )
    }

    private func noFreeSlotError(for region: Region) -> Error {
        NSError(
            domain: "DesktopRegions",
            code: 1005,
            userInfo: [NSLocalizedDescriptionKey: "“\(region.name)”没有空余位置，请增加网格行列数后再试。"]
        )
    }

    private func desktopOnlyError() -> Error {
        NSError(
            domain: "DesktopRegions",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "请从桌面上的文件图标拖入区域。其他位置的文件不会被移动到桌面。"]
        )
    }

    @objc private func screenParametersChanged() {
        for region in store.regions {
            regionWindows[region.id]?.show()
        }
    }

    private func makeWorkspaceSnapshot(
        finderItems: [FinderDesktopItem]? = nil
    ) -> WorkspaceSnapshot {
        let items = finderItems ?? finderDesktopMonitor.itemsForWorkspaceSnapshot()
        return WorkspaceSnapshot(
            regions: store.regions,
            desktopIconPositions: items.map(DesktopIconPosition.init(item:)),
            usesMacDefaultGrid: usesMacDefaultGrid
        )
    }

    private func recordUndoStep(title: String, snapshot: WorkspaceSnapshot) {
        guard !isApplyingUndo else { return }
        undoHistory.record(title: title, snapshot: snapshot)
        rebuildStatusMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusBarIconFactory.makeRiceBowlIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.toolTip = "饭格"
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        let header = NSMenuItem(title: "饭格", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let countItem = NSMenuItem(title: "文件仍由 Finder 管理", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        menu.addItem(countItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "打开设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let undoTitle = undoHistory.nextStep.map { "撤销：\($0.title)" } ?? "撤销"
        let undoItem = NSMenuItem(
            title: undoTitle,
            action: #selector(undoLastAction),
            keyEquivalent: "z"
        )
        undoItem.target = self
        undoItem.isEnabled = undoHistory.nextStep != nil
        undoItem.image = NSImage(
            systemSymbolName: "arrow.uturn.backward",
            accessibilityDescription: "撤销上一步"
        )
        menu.addItem(undoItem)

        let editMenuPresentation = EditModeMenuPresentation(editMode: editMode)
        let editItem = NSMenuItem(title: editMenuPresentation.title, action: #selector(toggleEditMode), keyEquivalent: "e")
        editItem.target = self
        editItem.state = editMenuPresentation.state
        editMenuItem = editItem
        menu.addItem(editItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出饭格", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
