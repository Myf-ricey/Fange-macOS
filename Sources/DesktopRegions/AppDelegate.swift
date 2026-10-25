// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PreferenceKey {
        static let usesMacDefaultGrid = "usesMacDefaultGridGlobally"
    }

    let store: RegionStore

    init(store: RegionStore = RegionStore()) {
        self.store = store
        super.init()
    }
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
    private let desktopVisibility = DesktopItemVisibility()
    private var folderSessions: [UUID: MappedFolderSession] = [:]
    private let fileOperationQueue = DispatchQueue(label: "com.ricey.desktop-regions.moves", qos: .userInitiated)
    private var fileMoveInProgress = false
    private var fileTransferProtectedPaths = Set<String>()
    private var terminateAfterFileOperation = false

    @MainActor private lazy var updateManager = AppUpdateManager { [weak self] in
        guard let self else { throw UpdatePolicy.error("应用正在退出，请重新打开后重试。") }
        guard !self.fileMoveInProgress else { throw UpdatePolicy.error("文件正在移动，请等待完成后再次更新。") }
        try self.desktopVisibility.restoreAll()
    }

    @MainActor @objc func checkForUpdates() { updateManager.check(manual: true) }

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

        _ = synchronizeFilePresentation()
        setupStatusItem()
        rebuildRegionWindows()
        updateManager.didLaunch()
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
        updateManager.cancel()
        pendingDragCleanupWorkItem?.cancel()
        folderSessions.removeAll()
        do { try desktopVisibility.restoreAll() } catch { NSLog("图标恢复失败：%@", error.localizedDescription) }
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
        guard !fileMoveInProgress, let step = undoHistory.nextStep else { return }
        do { try desktopVisibility.restore(paths: Set(step.fileMoves.map(\.destination))) }
        catch { showError(error); return }
        guard !step.fileMoves.isEmpty else { applyWorkspaceUndo(step); return }
        fileMoveInProgress = true
        rebuildStatusMenu()
        settingsWindow?.setStatus("正在把文件移回原位置…")
        let accessSessions = Array(folderSessions.values)
        fileOperationQueue.async { [weak self, accessSessions] in
            let result = Result { try FolderFileOperations.undo(step.fileMoves) }
            DispatchQueue.main.async { [weak self, accessSessions] in
                _ = accessSessions
                guard let self else { return }
                self.fileMoveInProgress = false
                switch result {
                case .success: self.applyWorkspaceUndo(step)
                case .failure(let error):
                    _ = self.synchronizeFilePresentation()
                    self.showError(error)
                }
                self.folderSessions.values.forEach { $0.reload() }
                self.rebuildStatusMenu()
                self.finishPendingTermination()
            }
        }
    }

    private func applyWorkspaceUndo(_ step: WorkspaceUndoStep) {
        repositionWorkItems.values.forEach { $0.cancel() }
        repositionWorkItems.removeAll()
        lastRepositionDates.removeAll()
        pendingDragCleanupWorkItem?.cancel()
        pendingDragCleanupWorkItem = nil
        isApplyingUndo = true
        defer { isApplyingUndo = false }

        let hiddenPaths = Set(step.snapshot.regions.filter(\.hidesDesktopItems).flatMap {
            $0.itemBindings.filter(\.isExplicit).map(\.path)
        })
        if let error = restoreDesktopIconPositionsProgrammatically(
            step.snapshot.desktopIconPositions.filter { !hiddenPaths.contains($0.path) }
        ) {
            // File moves have already been undone; consume the step and
            // restore configuration even if Finder positioning was denied.
            settingsWindow?.setStatus("文件已恢复；Finder 图标位置恢复失败：\(error.localizedDescription)")
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
        guard canChangeWorkspace() else { return }
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
        guard canChangeWorkspace() else { return }
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
        guard canChangeWorkspace(), let previous = store.region(id: id) else { return }
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
            if region.usesMacDefaultGrid && !region.presentsOwnFiles {
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
        let presentationChanged = previous.hidesDesktopItems != updated.hidesDesktopItems ||
            previous.itemBindings != updated.itemBindings || previous.fileSort != updated.fileSort ||
            previous.mappedFolderPath != updated.mappedFolderPath || previous.mappedFolderBookmark != updated.mappedFolderBookmark
        guard !presentationChanged || synchronizeFilePresentation() else {
            store.mutate(id: id) { $0 = previous }
            _ = synchronizeFilePresentation()
            settingsWindow?.updateRegionRow(previous)
            settingsWindow?.updateAdvancedEditor(previous)
            return
        }
        if updated != previous { recordUndoStep(title: actionName, snapshot: undoSnapshot) }
        regionWindows[id]?.update(with: updated)
        settingsWindow?.updateRegionRow(updated)
        settingsWindow?.updateAdvancedEditor(updated)
        rebuildStatusMenu()
        refreshAvailableSlots()

        if RegionLayout.globalSlotCenters(in: previous) != RegionLayout.globalSlotCenters(in: updated) {
            scheduleBoundItemReposition(regionID: id, reason: .regionGeometryChanged)
        } else if previous.hidesDesktopItems && !updated.hidesDesktopItems {
            // Finder retains desktop positions while hidden. Let its next
            // snapshot confirm them and repair actual drift only; rewriting
            // every icon here blocks the main thread on redundant Apple events.
            finderDesktopMonitor.requestImmediatePoll()
        }
    }

    func setMacDefaultGridEnabled(_ enabled: Bool) {
        guard canChangeWorkspace() else { return }
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
        settingsWindow?.showAdvancedSettings(for: id)
    }

    func deleteRegion(id: UUID) {
        guard canChangeWorkspace() else { return }
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
        _ = synchronizeFilePresentation()
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
                controller.onSortChanged = { [weak self] id, options in
                    self?.mutateRegion(id: id, actionName: "修改文件排序") { $0.fileSort = options }
                }
                controller.onCollapseRequested = { [weak self] id in
                    self?.mutateRegion(id: id, actionName: "展开或收起分区") {
                        if $0.allowsCollapse { $0.isCollapsed.toggle() }
                    }
                }
                let revealForFinder: ([URL]) -> Void = { [weak self] urls in
                    guard let self else { return }
                    let paths = Set(urls.map(\.path))
                    self.desktopVisibility.temporarilyVisiblePaths.formUnion(paths)
                    do { try self.desktopVisibility.restore(paths: paths) } catch { self.showError(error) }
                }
                controller.onFilesDragStarted = revealForFinder
                controller.onFilesRevealRequested = revealForFinder
                controller.onFilesDragEnded = { [weak self] id, urls, operation in
                    guard let self else { return }
                    let paths = Set(urls.map(\.path))
                    if operation.contains(.move), self.store.region(id: id)?.isMapped == false,
                       RegionLayout.dropTargetRegion(at: NSEvent.mouseLocation, in: self.store.regions)?.id != id {
                        self.removeBindings(forPaths: paths)
                    }
                    self.desktopVisibility.temporarilyVisiblePaths.subtract(paths.subtracting(self.fileTransferProtectedPaths))
                    _ = self.synchronizeFilePresentation()
                }
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
        _ = synchronizeFilePresentation()
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
            if usesMacDefaultGrid, !region.presentsOwnFiles,
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
        if region.isMapped {
            moveFilesIntoMappedFolder(urls, regionID: id)
            return
        }
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
            if region.isMapped {
                moveFilesIntoMappedFolder([item.url], regionID: region.id)
                continue
            }
            if region.isCollapsed { continue }
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
        // Hidden entries can still be renamed/moved by Finder when the user
        // enables hidden files. Follow their identity rather than leaving an
        // invisible stale binding behind.
        let relocated = desktopVisibility.relocatedEntries
        if !relocated.isEmpty {
            var regions = store.regions
            for index in regions.indices {
                regions[index].itemBindings = regions[index].itemBindings.compactMap { binding in
                    guard let path = relocated[binding.path] else { return binding }
                    let url = URL(fileURLWithPath: path)
                    guard isDesktopURL(url) else { return nil }
                    return RegionItemBinding(path: path, slotIndex: binding.slotIndex, isExplicit: binding.isExplicit)
                }
            }
            store.replace(with: regions)
            syncRegionsAfterStoreChange()
        }
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
        for region in store.regions where !region.itemBindings.isEmpty && !region.hidesDesktopItems && !region.isMapped {
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
        _ = synchronizeFilePresentation()
        refreshAvailableSlots()
    }

    private func pruneMissingBindings(using items: [FinderDesktopItem]) {
        // Hidden ordinary-list/collapsed entries are absent from Finder's
        // desktop enumeration; filesystem existence is authoritative for them.
        let managedPaths = store.regions.flatMap { $0.itemBindings.map(\.path) }.filter {
            var info = stat()
            return lstat($0, &info) == 0
        }
        let existingPaths = Set(items.map { $0.url.standardizedFileURL.path }).union(managedPaths)
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
              !region.hidesDesktopItems, !region.isMapped,
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
        // Managed file layers move their cached cells immediately. Finder
        // positioning is only needed for a region displaying native icons.
        guard !region.ownsFileSurface else { return nil }
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

    func requestFolderMapping(for id: UUID, from view: NSView) {
        guard let region = store.region(id: id) else { return }
        if !region.isMapped { chooseFolder(for: id); return }
        let menu = NSMenu()
        for (title, action) in [("更换映射文件夹…", #selector(selectFolderFromMenu(_:))),
                                ("在访达中打开", #selector(revealMappedFolder(_:))),
                                ("解除映射", #selector(clearFolderMapping(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = id; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }

    private func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "选择映射文件夹"
        panel.message = "分区将实时显示该文件夹；拖入分区的文件会真正移到此文件夹。"
        panel.prompt = "映射文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        if let path = store.region(id: id)?.mappedFolderPath { panel.directoryURL = URL(fileURLWithPath: path) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Verify actual directory access before saving a relationship.
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let bookmark = try MappedFolderSession.bookmark(for: url)
            mutateRegion(id: id, actionName: "映射文件夹") {
                $0.mappedFolderPath = url.standardizedFileURL.path
                $0.mappedFolderBookmark = bookmark
                $0.itemBindings = []
            }
            settingsWindow?.setStatus("已映射到“\(url.lastPathComponent)”；拖入文件会移动到该目录")
        } catch { showError(error) }
    }

    @objc private func addRegionFromMenu() { addRegion(); openSettings() }
    @objc private func selectFolderFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID { chooseFolder(for: id) }
    }
    @objc private func revealMappedFolder(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let url = folderSessions[id]?.folderURL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func clearFolderMapping(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        mutateRegion(id: id, actionName: "解除文件夹映射") {
            $0.mappedFolderPath = nil; $0.mappedFolderBookmark = nil
        }
    }
    @objc private func collapseRegionFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        mutateRegion(id: id, actionName: "展开或收起分区") {
            if $0.allowsCollapse { $0.isCollapsed.toggle() }
        }
    }
    @objc private func displayModeFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        mutateRegion(id: id, actionName: "切换图标显示方式") { $0.displayMode = item.tag == 0 ? .icons : .list }
    }

    @discardableResult
    private func synchronizeFilePresentation() -> Bool {
        finderDesktopMonitor.boundDesktopPaths = Set(store.regions.filter { !$0.isMapped }.flatMap {
            $0.itemBindings.filter(\.isExplicit).map(\.path)
        })
        do { try desktopVisibility.synchronize(regions: store.regions) }
        catch { showError(error); return false }
        for (id, session) in folderSessions {
            let region = store.region(id: id)
            if region?.mappedFolderPath != session.savedPath || region?.mappedFolderBookmark != session.bookmark {
                folderSessions.removeValue(forKey: id)
            }
        }
        for region in store.regions {
            if let session = folderSessions[region.id] { session.sortOptions = region.fileSort }
            guard let path = region.mappedFolderPath, folderSessions[region.id] == nil else { continue }
            let session = MappedFolderSession(path: path, bookmark: region.mappedFolderBookmark, sortOptions: region.fileSort)
            session.onChange = { [weak self, weak session] urls, error in
                guard let self, let session, self.folderSessions[region.id] === session else { return }
                self.regionWindows[region.id]?.setFiles(urls, message: error)
                if error == nil, self.store.region(id: region.id)?.mappedFolderPath != session.folderURL.path {
                    let renewedBookmark = (try? MappedFolderSession.bookmark(for: session.folderURL)) ?? session.bookmark
                    self.store.mutate(id: region.id) {
                        $0.mappedFolderPath = session.folderURL.path
                        $0.mappedFolderBookmark = renewedBookmark
                    }
                    if let updated = self.store.region(id: region.id) { self.settingsWindow?.updateRegionRow(updated) }
                }
            }
            folderSessions[region.id] = session
            regionWindows[region.id]?.setFiles([], message: "正在读取文件夹…")
            session.start()
        }
        return true
    }

    private func moveFilesIntoMappedFolder(_ urls: [URL], regionID: UUID) {
        guard !fileMoveInProgress else {
            settingsWindow?.setStatus("正在移动文件，请稍候再拖入")
            return
        }
        guard let session = folderSessions[regionID] else { return }
        let snapshot = makeWorkspaceSnapshot()
        let sourcePaths = Set(urls.map { $0.standardizedFileURL.path })
        desktopVisibility.temporarilyVisiblePaths.formUnion(sourcePaths)
        do { try desktopVisibility.restore(paths: sourcePaths) }
        catch { desktopVisibility.temporarilyVisiblePaths.subtract(sourcePaths); showError(error); return }
        fileTransferProtectedPaths.formUnion(sourcePaths)
        fileMoveInProgress = true
        rebuildStatusMenu()
        settingsWindow?.setStatus("正在移动 \(urls.count) 个文件…")
        fileOperationQueue.async { [weak self, session] in
            let result: Result<[FileMove], Error> = Result {
                let moves = try FolderFileOperations.planMove(urls, into: session.folderURL)
                try FolderFileOperations.execute(moves)
                return moves
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fileMoveInProgress = false
                self.fileTransferProtectedPaths.subtract(sourcePaths)
                self.desktopVisibility.temporarilyVisiblePaths.subtract(sourcePaths)
                switch result {
                case .success(let moves):
                    self.removeBindings(forPaths: Set(moves.map(\.source)))
                    if !moves.isEmpty { self.recordUndoStep(title: "移动文件到映射文件夹", snapshot: snapshot, fileMoves: moves) }
                    self.regionWindows[regionID]?.showDropFeedback()
                    self.settingsWindow?.setStatus("已移动 \(moves.count) 个文件到“\(session.folderURL.lastPathComponent)”")
                case .failure(let error): self.showError(error)
                }
                _ = self.synchronizeFilePresentation()
                self.folderSessions.values.forEach { $0.reload() }
                self.rebuildStatusMenu()
                self.finishPendingTermination()
            }
        }
    }

    private func canChangeWorkspace() -> Bool {
        guard fileMoveInProgress else { return true }
        settingsWindow?.setStatus("正在移动文件，完成后即可继续修改分区")
        settingsWindow?.refresh()
        return false
    }

    private func finishPendingTermination() {
        guard terminateAfterFileOperation else { return }
        terminateAfterFileOperation = false
        do {
            try desktopVisibility.restoreAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        } catch {
            showError(error)
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if fileMoveInProgress {
            terminateAfterFileOperation = true
            return .terminateLater
        }
        do { try desktopVisibility.restoreAll(); return .terminateNow }
        catch { showError(error); return .terminateCancel }
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

    private func recordUndoStep(title: String, snapshot: WorkspaceSnapshot, fileMoves: [FileMove] = []) {
        guard !isApplyingUndo else { return }
        undoHistory.record(title: title, snapshot: snapshot, fileMoves: fileMoves)
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
        let addItem = NSMenuItem(title: "新建分区", action: #selector(addRegionFromMenu), keyEquivalent: "n")
        addItem.target = self
        menu.addItem(addItem)
        let regionsItem = NSMenuItem(title: "分区", action: nil, keyEquivalent: "")
        let regionsMenu = NSMenu()
        for region in store.regions {
            let item = NSMenuItem(title: region.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let map = NSMenuItem(title: region.isMapped ? "更换映射文件夹…" : "选择映射文件夹…", action: #selector(selectFolderFromMenu(_:)), keyEquivalent: "")
            map.target = self; map.representedObject = region.id
            map.image = NSImage(systemSymbolName: region.isMapped ? "folder.fill" : "folder", accessibilityDescription: nil)
            submenu.addItem(map)
            if region.isMapped {
                for (title, action) in [("在访达中打开", #selector(revealMappedFolder(_:))), ("解除映射", #selector(clearFolderMapping(_:)))] {
                    let command = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    command.target = self; command.representedObject = region.id; submenu.addItem(command)
                }
            }
            let collapse = NSMenuItem(title: region.isCollapsed ? "展开分区" : "收起分区", action: #selector(collapseRegionFromMenu(_:)), keyEquivalent: "")
            collapse.target = self; collapse.representedObject = region.id; collapse.isEnabled = region.allowsCollapse
            submenu.addItem(collapse)
            for mode in RegionDisplayMode.allCases {
                let view = NSMenuItem(title: mode.displayName, action: #selector(displayModeFromMenu(_:)), keyEquivalent: "")
                view.target = self; view.representedObject = region.id; view.tag = mode == .icons ? 0 : 1
                view.state = region.displayMode == mode ? .on : .off; submenu.addItem(view)
            }
            if region.presentsOwnFiles {
                let sort = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
                sort.submenu = RegionSortMenu.make(options: region.fileSort) { [weak self] options in
                    self?.mutateRegion(id: region.id, actionName: "修改文件排序") { $0.fileSort = options }
                }
                submenu.addItem(sort)
            }
            item.submenu = submenu; regionsMenu.addItem(item)
        }
        regionsItem.submenu = regionsMenu
        menu.addItem(regionsItem)

        let undoTitle = undoHistory.nextStep.map { "撤销：\($0.title)" } ?? "撤销"
        let undoItem = NSMenuItem(
            title: undoTitle,
            action: #selector(undoLastAction),
            keyEquivalent: "z"
        )
        undoItem.target = self
        undoItem.isEnabled = !fileMoveInProgress && undoHistory.nextStep != nil
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
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "检查更新")
        menu.addItem(updateItem)
        let quitItem = NSMenuItem(title: "退出饭格", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
