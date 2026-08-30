// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

@main
struct InteractionPolicyTests {
    static func main() {
        let normalMode = RegionInteractionPolicy(editMode: false)
        let editMode = RegionInteractionPolicy(editMode: true)

        precondition(normalMode.monitorsFinderDesktopPositions, "普通模式必须监听 Finder 图标坐标")
        precondition(normalMode.windowIgnoresMouseEvents, "普通模式窗口必须透传 Finder 点击")
        precondition(!normalMode.capturesLayoutGestures, "普通模式不能移动区块")
        precondition(editMode.monitorsFinderDesktopPositions, "编辑模式仍必须监听 Finder 图标，才能优先拖动分区内的图标")
        precondition(!editMode.windowIgnoresMouseEvents, "编辑模式窗口必须接收布局手势")
        precondition(editMode.capturesLayoutGestures, "编辑模式必须捕获布局手势")
        let editLayerPolicy = RegionWindowLayerPolicy(editMode: true)
        precondition(editLayerPolicy.keepsVisualWindowBelowFinderIcons, "编辑模式的可见分区必须仍在 Finder 图标下层")
        precondition(editLayerPolicy.usesTransparentInteractionOverlay, "编辑模式必须用独立透明交互层接收拖动")
        precondition(
            editLayerPolicy.interactionWindowLevel.rawValue > Int(CGWindowLevelForKey(.mainMenuWindow)),
            "顶部特殊位的透明交互层必须高于 macOS 菜单栏"
        )
        let settingsVisibleFrame = NSRect(x: 0, y: 25, width: 1710, height: 1048)
        precondition(
            SettingsEdgePanelLayout.handleFrame(in: settingsVisibleFrame) ==
                NSRect(x: 1672, y: 494, width: 38, height: 110),
            "设置栏收回后必须在当前屏幕右侧保留可点击的展开标签"
        )
        precondition(
            SettingsPanelVisibilityPolicy.nextState(
                from: .expanded,
                action: .enteredEditMode
            ) == .collapsed,
            "进入编辑模式必须自动把设置栏收回到右侧"
        )
        precondition(
            SettingsPanelVisibilityPolicy.nextState(
                from: .collapsed,
                action: .leftEditMode
            ) == .collapsed,
            "完成编辑不能突然展开设置栏，必须由用户主动召回"
        )
        precondition(
            SettingsPanelVisibilityPolicy.nextState(
                from: .collapsed,
                action: .requestedSettings
            ) == .expanded,
            "点击右侧标签或菜单栏设置必须重新展开标准设置窗口"
        )
        let editSurfacePolicy = RegionInteractionSurfacePolicy(editMode: true)
        precondition(!editSurfacePolicy.ignoresMouseEvents, "透明编辑层必须显式接收鼠标事件")
        precondition(
            editSurfacePolicy.hitCaptureAlpha > 0 && editSurfacePolicy.hitCaptureAlpha < 0.01,
            "透明编辑层必须有不可见但可命中的合成表面"
        )
        let normalSurfacePolicy = RegionInteractionSurfacePolicy(editMode: false)
        precondition(normalSurfacePolicy.ignoresMouseEvents, "退出编辑模式后透明交互层必须停止接收鼠标")
        let riceBowlIcon = StatusBarIconFactory.makeRiceBowlIcon()
        precondition(riceBowlIcon.size == NSSize(width: 18, height: 18), "菜单栏饭碗图标必须使用清晰的 18×18 pt 画布")
        precondition(riceBowlIcon.isTemplate, "菜单栏饭碗图标必须是 Template，才能适配明暗和选中状态")
        precondition(!riceBowlIcon.representations.isEmpty, "菜单栏饭碗图标必须包含可绘制的矢量表示")
        precondition(
            FinderDragPreviewPolicy.shouldActivate(
                editMode: false,
                finderIsFrontmost: true,
                hasDesktopItemCandidate: false
            ),
            "Finder 中一开始拖动鼠标就必须立即启用空槽预览"
        )
        precondition(
            FinderDragPreviewPolicy.shouldActivate(
                editMode: true,
                finderIsFrontmost: true,
                hasDesktopItemCandidate: true
            ),
            "编辑模式下从 Finder 图标开始的拖动也必须显示空槽预览"
        )
        precondition(
            !FinderDragPreviewPolicy.shouldActivate(
                editMode: true,
                finderIsFrontmost: true,
                hasDesktopItemCandidate: false
            ),
            "编辑模式下没有桌面图标候选时，不能把移动分区误判为拖动图标"
        )
        let iconCenter = NSPoint(x: 300, y: 500)
        precondition(
            FinderIconHitTarget.contains(
                NSPoint(x: 300, y: 500),
                iconCenter: iconCenter,
                iconSize: 88
            ) && FinderIconHitTarget.contains(
                NSPoint(x: 300, y: 422),
                iconCenter: iconCenter,
                iconSize: 88
            ),
            "Finder 图标本体和下方文件名都必须优先穿透给 Finder"
        )
        precondition(
            !FinderIconHitTarget.contains(
                NSPoint(x: 370, y: 500),
                iconCenter: iconCenter,
                iconSize: 88
            ),
            "图标旁边的空白区必须仍能用来拖动分区"
        )
        let draggedPath = "/Users/test/Desktop/dragged-from-label.txt"
        let labelDragPoint = NSPoint(x: iconCenter.x, y: iconCenter.y - 78)
        precondition(
            FinderDragCandidatePolicy.candidatePaths(
                at: labelDragPoint,
                candidates: [FinderDragCandidate(path: draggedPath, iconCenter: iconCenter)],
                iconSize: 88
            ) == [draggedPath],
            "从 Finder 文件名下缘开始拖动时也必须识别候选图标并立即释放原槽位"
        )

        var dragAvailability = FinderDragAvailabilityState()
        dragAvailability.beginPress(candidatePaths: [draggedPath])
        precondition(
            dragAvailability.excludedPaths(selectedPaths: []) == [draggedPath] &&
                dragAvailability.pendingConfirmationPaths.isEmpty,
            "鼠标刚按下时必须立即保护源绑定，但普通单击不能启动松手后的确认轮询"
        )
        dragAvailability.beginDrag(candidatePaths: [draggedPath])
        dragAvailability.endDrag()
        precondition(
            dragAvailability.excludedPaths(selectedPaths: []).contains(draggedPath),
            "松手后必须暂时保留刚拖走的路径，直到 Finder 提交位置，避免旧槽位短暂消失"
        )
        let nextDraggedPath = "/Users/test/Desktop/second-drag.txt"
        dragAvailability.beginDrag(candidatePaths: [nextDraggedPath])
        precondition(
            dragAvailability.excludedPaths(selectedPaths: []) == [draggedPath, nextDraggedPath],
            "连续换位时，上一枚待确认图标和当前图标的原槽位都必须可预选"
        )
        dragAvailability.confirm(paths: [draggedPath])
        precondition(
            dragAvailability.excludedPaths(selectedPaths: []) == [nextDraggedPath],
            "Finder 提交新位置后必须清除对应的临时释放状态"
        )
        let inactiveMenu = EditModeMenuPresentation(editMode: false)
        let activeMenu = EditModeMenuPresentation(editMode: true)
        precondition(inactiveMenu.title == "编辑模式" && activeMenu.title == "编辑模式", "菜单项必须表示稳定状态，不能写成下一步动作")
        precondition(inactiveMenu.state == .off && activeMenu.state == .on, "编辑模式的菜单勾选必须与实际状态同向")

        let originalFrame = NSRect(x: 24, y: 584.5, width: 823, height: 464.5)
        let movedFrame = RegionGestureGeometry.movedFrame(from: originalFrame, dx: 60, dy: -40)
        precondition(movedFrame == NSRect(x: 84, y: 544.5, width: 823, height: 464.5), "移动必须使用固定屏幕坐标差值")

        let eventGlobalPoint = RegionGestureGeometry.globalPoint(
            windowFrame: NSRect(x: 451, y: 565, width: 243, height: 508),
            eventLocationInWindow: NSPoint(x: 119, y: 364)
        )
        precondition(
            eventGlobalPoint == NSPoint(x: 570, y: 929),
            "拖动坐标必须来自当前 NSEvent，不能读取可能停滞的全局 mouseLocation"
        )

        precondition(
            MacGridTopOverflowIntent.shouldPreferTopOverflow(
                dragStartY: 960,
                currentY: 1040,
                proposedFrameMaxY: 1153,
                visibleFrameMaxY: 1073
            ),
            "明显向上拖动且分区已顶到桌面上缘时，必须选择顶部特殊位"
        )
        precondition(
            !MacGridTopOverflowIntent.shouldPreferTopOverflow(
                dragStartY: 960,
                currentY: 962,
                proposedFrameMaxY: 1073,
                visibleFrameMaxY: 1073
            ),
            "仅在顶部横向微调时不能误触发特殊越界"
        )

        let unconstrainedWindow = UnconstrainedRegionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let intentionalOverflow = NSRect(x: 451, y: 692, width: 243, height: 508)
        precondition(
            unconstrainedWindow.constrainFrameRect(intentionalOverflow, to: NSScreen.main) == intentionalOverflow,
            "AppKit 不能把已确认的顶部特殊 frame 自动压回普通第一行"
        )

        precondition(
            !BoundItemRepositionReason.regionGeometryChanged.canSkipItemsMatchingFinderSnapshot,
            "分区连续拖动时 Finder 快照会暂停，不能用旧快照跳过绑定图标移动"
        )
        precondition(
            BoundItemRepositionReason.restoreBindings.canSkipItemsMatchingFinderSnapshot,
            "仅启动恢复绑定时可以跳过已经位于目标位置的图标"
        )
        precondition(
            FinderBindingDriftPolicy.hasDrift(
                current: NSPoint(x: 120, y: 260),
                target: (x: 500, y: 90),
                isSelected: false
            ),
            "Finder 整理造成的未选中绑定图标漂移必须被检测"
        )
        precondition(
            !FinderBindingDriftPolicy.hasDrift(
                current: NSPoint(x: 120, y: 260),
                target: (x: 500, y: 90),
                isSelected: true
            ),
            "用户正在拖出的选中图标不能被漂移恢复抢回"
        )

        let resizedFrame = RegionGestureGeometry.resizedFrameFromBottomRight(from: originalFrame, dx: 60, dy: -40)
        precondition(resizedFrame.width == 883 && resizedFrame.height == 504.5, "右下角拖动必须按鼠标位移改变宽高")
        precondition(resizedFrame.maxY == originalFrame.maxY, "从右下角缩放时上边缘必须保持不动")

        let spacingSizedFrame = NSRect(x: 375, y: 501, width: 354, height: 500)
        let spacingMinimum = RegionLayout.minimumRegionSize(
            columns: 2,
            rows: 3,
            headerHeight: 28,
            iconSpacing: 118
        )
        let userShrunkFrame = RegionGestureGeometry.resizedFrameFromBottomRight(
            from: spacingSizedFrame,
            dx: -24,
            dy: 24,
            minimumSize: spacingMinimum
        )
        precondition(
            userShrunkFrame.width < spacingSizedFrame.width && userShrunkFrame.height < spacingSizedFrame.height,
            "图标间距不能把当前分区尺寸锁成不可缩小"
        )

        let localBounds = NSRect(origin: .zero, size: originalFrame.size)
        let header = RegionLayout.headerRect(in: localBounds)
        precondition(header.minX == 1 && header.maxX == localBounds.maxX - 1, "默认标题栏必须覆盖整个顶部")
        precondition(header.maxY == localBounds.maxY - 1 && header.height == 34, "标题栏必须与分区顶边相接")
        let tallHeader = RegionLayout.headerRect(in: localBounds, height: 56)
        precondition(tallHeader.width == header.width, "调整标签栏高度时横向仍必须填满")
        precondition(tallHeader.height == 56, "更多设置必须能纵向调整标签栏高度")
        let titleTextRect = RegionLayout.titleTextRect(
            in: header,
            titleHeight: 20,
            editMode: true
        )
        precondition(
            abs(titleTextRect.midY - (header.midY - 2)) < 0.01,
            "分区标题文字必须从几何中心向下微调 2 pt"
        )

        let screenFrame = NSRect(x: 0, y: 0, width: 1710, height: 1112)
        let layoutRegion = Region(
            name: "网格测试",
            role: .custom,
            frame: originalFrame,
            colorHex: "#112233"
        )
        let editHitTestController = RegionWindowController(region: layoutRegion, editMode: true)
        let finderIconPoint = NSPoint(x: 180, y: 760)
        editHitTestController.updateEditInteractionPassthrough(
            at: finderIconPoint,
            desktopIconCenters: [finderIconPoint],
            iconSize: 88,
            isOverControlWindow: false
        )
        precondition(
            editHitTestController.editSurfaceIgnoresMouseEvents,
            "编辑模式下 Finder 图标的鼠标命中必须穿透给桌面"
        )
        editHitTestController.updateEditInteractionPassthrough(
            at: NSPoint(x: 360, y: 760),
            desktopIconCenters: [finderIconPoint],
            iconSize: 88,
            isOverControlWindow: false
        )
        precondition(
            !editHitTestController.editSurfaceIgnoresMouseEvents,
            "编辑模式下图标旁边的空白区必须恢复分区拖动"
        )
        editHitTestController.updateEditInteractionPassthrough(
            at: NSPoint(x: 360, y: 760),
            desktopIconCenters: [],
            iconSize: 88,
            isOverControlWindow: true
        )
        precondition(
            editHitTestController.editSurfaceIgnoresMouseEvents,
            "设置窗口或系统选色板覆盖分区时必须优先接收鼠标"
        )
        editHitTestController.updateEditInteractionPassthrough(
            at: NSPoint(x: 360, y: 760),
            desktopIconCenters: [],
            iconSize: 88,
            isOverControlWindow: false
        )
        precondition(
            !editHitTestController.editSurfaceIgnoresMouseEvents,
            "离开设置窗口后空白分区应恢复拖动"
        )
        editHitTestController.close()
        let iconPositions = RegionLayout.finderIconPositions(
            in: layoutRegion,
            screenFrame: screenFrame,
            count: Int.max
        )
        precondition(iconPositions.count == 6, "默认区块应固定生成横 2 列、纵 3 行的图标网格")
        let globalIconPoints = iconPositions.map {
            NSPoint(x: CGFloat($0.x) + screenFrame.minX, y: screenFrame.maxY - CGFloat($0.y))
        }
        precondition(
            globalIconPoints.allSatisfy {
                $0.y < originalFrame.maxY - CGFloat(layoutRegion.headerHeight)
            },
            "图标第一行必须避开标题栏"
        )
        precondition(
            globalIconPoints.allSatisfy {
                $0.x >= originalFrame.minX + RegionLayout.minimumIconInset &&
                $0.x <= originalFrame.maxX - RegionLayout.minimumIconInset &&
                $0.y >= originalFrame.minY + RegionLayout.minimumIconInset
            },
            "图标区必须保留左右和底部留白"
        )
        precondition(
            abs((globalIconPoints[1].x - globalIconPoints[0].x) - CGFloat(layoutRegion.iconSpacing)) < 1,
            "宽分区中的图标间距必须使用设置值，不能被拉到两侧"
        )
        precondition(
            abs((globalIconPoints[0].x + globalIconPoints[1].x) / 2 - originalFrame.midX) < 1,
            "未占满宽度的网格必须整体居中"
        )
        let topIconGap = originalFrame.maxY - CGFloat(layoutRegion.headerHeight) - globalIconPoints[0].y
        let bottomIconGap = globalIconPoints[4].y - originalFrame.minY
        precondition(
            bottomIconGap > topIconGap,
            "图标网格必须整体偏上，为最底行的 Finder 文件名保留更多空间"
        )
        let nearestSlot = RegionLayout.nearestAvailableSlot(
            to: NSPoint(x: globalIconPoints[3].x + 4, y: globalIconPoints[3].y - 3),
            in: layoutRegion,
            excluding: [0, 1, 2]
        )
        precondition(nearestSlot == 3, "拖入图标必须选择距离落点最近的空槽位")

        let finderMetrics = FinderDesktopGridMetrics(
            iconSize: 88,
            gridSpacing: 39,
            gridOffsetX: 0,
            gridOffsetY: 0
        )
        precondition(
            RegionLayout.macGridDownwardOffset == 44,
            "截图中 AI 顶边与日历顶边相差 88 Retina 像素，即 44 pt"
        )
        var macGridRegion = layoutRegion
        macGridRegion.usesMacDefaultGrid = true
        macGridRegion.gridColumns = 2
        macGridRegion.gridRows = 3
        let macGridSize = RegionLayout.macGridFrameSize(for: macGridRegion, metrics: finderMetrics)
        precondition(
            macGridRegion.macGridBottomExtension == 24 &&
                macGridSize == NSSize(width: 243, height: 532),
            "Mac 网格默认必须向下延伸 24 pt，接住两行 Finder 文件名"
        )

        let visibleFrame = NSRect(x: 0, y: 80, width: 1710, height: 993)
        let proposedMacFrame = NSRect(x: 1340, y: 410, width: 320, height: 430)
        var zeroBottomExtensionRegion = macGridRegion
        zeroBottomExtensionRegion.macGridBottomExtension = 0
        let zeroExtensionFrame = RegionLayout.snappedMacGridFrame(
            near: proposedMacFrame,
            region: zeroBottomExtensionRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics
        )
        let extendedFrame = RegionLayout.snappedMacGridFrame(
            near: proposedMacFrame,
            region: macGridRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics
        )
        precondition(
            extendedFrame.maxY == zeroExtensionFrame.maxY &&
                extendedFrame.minY == zeroExtensionFrame.minY - 24,
            "底部延伸只能向下扩大边界，不能移动分区顶部"
        )
        var zeroExtensionPlacedRegion = zeroBottomExtensionRegion
        zeroExtensionPlacedRegion.setFrame(zeroExtensionFrame)
        var extendedPlacedRegion = macGridRegion
        extendedPlacedRegion.setFrame(extendedFrame)
        precondition(
            RegionLayout.macGridSlotCenters(in: zeroExtensionPlacedRegion, metrics: finderMetrics)
                == RegionLayout.macGridSlotCenters(in: extendedPlacedRegion, metrics: finderMetrics),
            "调整底部延伸时所有图标位置必须保持不动"
        )

        let snappedMacFrame = RegionLayout.snappedMacGridFrame(
            near: proposedMacFrame,
            region: macGridRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics
        )
        macGridRegion.setFrame(snappedMacFrame)
        let macCenters = RegionLayout.macGridSlotCenters(in: macGridRegion, metrics: finderMetrics)
        precondition(macCenters.count == 6, "Mac 网格仍必须只产生所设 2×3 个图标位置")
        precondition(
            abs((snappedMacFrame.maxY - finderMetrics.topInset) - macCenters[0].y - finderMetrics.pitch) < 0.01,
            "标签栏必须独占 Finder 网格的第一行"
        )
        precondition(
            abs(macCenters[1].x - macCenters[0].x - finderMetrics.pitch) < 0.01 &&
                abs(macCenters[2].y - macCenters[0].y + finderMetrics.pitch) < 0.01,
            "Mac 网格的横纵步进必须与 Finder 完全一致"
        )

        let topOverflowProposal = NSRect(
            x: snappedMacFrame.minX,
            y: visibleFrame.maxY + finderMetrics.pitch - macGridSize.height,
            width: macGridSize.width,
            height: macGridSize.height
        )
        let topOverflowFrame = RegionLayout.snappedMacGridFrame(
            near: topOverflowProposal,
            region: macGridRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics
        )
        precondition(
            abs(
                topOverflowFrame.maxY
                    - (visibleFrame.maxY + finderMetrics.pitch - RegionLayout.macGridDownwardOffset)
            ) < 0.01,
            "顶部特殊吸附位必须连同整套默认网格下移 44 pt"
        )
        let pointerForcedTopFrame = RegionLayout.snappedMacGridFrame(
            near: snappedMacFrame,
            region: macGridRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics,
            prefersTopOverflow: true
        )
        precondition(
            abs(
                pointerForcedTopFrame.maxY
                    - (visibleFrame.maxY + finderMetrics.pitch - RegionLayout.macGridDownwardOffset)
            ) < 0.01,
            "即使窗口被 macOS 约束在旧位置，鼠标到达屏幕顶端也必须强制选择特殊越界位"
        )
        var topOverflowRegion = macGridRegion
        topOverflowRegion.setFrame(topOverflowFrame)
        let topOverflowCenters = RegionLayout.macGridSlotCenters(
            in: topOverflowRegion,
            metrics: finderMetrics
        )
        let shiftedFinderFirstRowY = visibleFrame.maxY
            - finderMetrics.topInset
            - finderMetrics.gridOffsetY
            - RegionLayout.macGridDownwardOffset
        precondition(
            abs(topOverflowCenters[0].y - shiftedFinderFirstRowY) < 0.01,
            "默认网格的第一行图标也必须与分区一起下移 44 pt"
        )
        var topOverflowLocalRegion = topOverflowRegion
        topOverflowLocalRegion.setFrame(NSRect(origin: .zero, size: topOverflowFrame.size))
        let topOverflowHeader = RegionLayout.headerRect(
            in: topOverflowLocalRegion.frame,
            region: topOverflowLocalRegion,
            metrics: finderMetrics
        ).offsetBy(dx: topOverflowFrame.minX, dy: topOverflowFrame.minY)
        precondition(
            topOverflowHeader.minY > topOverflowCenters[0].y &&
                topOverflowHeader.maxY < visibleFrame.maxY,
            "整体下移后，最顶部标签应落在菜单栏下方并仍位于第一行图标上方"
        )
        let topEditingHeader = RegionLayout.editingHeaderRect(
            in: topOverflowLocalRegion.frame,
            region: topOverflowRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics
        ).offsetBy(dx: topOverflowFrame.minX, dy: topOverflowFrame.minY)
        precondition(
            topEditingHeader == topOverflowHeader,
            "编辑模式不能为了命中鼠标而把顶部标签画到分区内部"
        )

        // Exercise the real RegionView event path, not only the layout helper:
        // clicking the real top title's ellipsis must reach the edit action.
        let topInteractionView = RegionView(region: topOverflowRegion, rendersVisuals: false)
        topInteractionView.frame = topOverflowLocalRegion.frame
        topInteractionView.editMode = true
        let topInteractionWindow = UnconstrainedRegionWindow(
            contentRect: topOverflowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        topInteractionWindow.contentView = topInteractionView
        var requestedTopRegionSettings = false
        topInteractionView.onMoreRequested = {
            requestedTopRegionSettings = true
        }
        let topEditingHeaderLocal = topEditingHeader.offsetBy(
            dx: -topOverflowFrame.minX,
            dy: -topOverflowFrame.minY
        )
        let moreButtonPoint = NSPoint(
            x: topEditingHeaderLocal.maxX - 22,
            y: topEditingHeaderLocal.midY
        )
        guard let moreMouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: moreButtonPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: topInteractionWindow.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            preconditionFailure("无法构造顶部标签的鼠标回归事件")
        }
        topInteractionView.mouseDown(with: moreMouseDown)
        precondition(
            requestedTopRegionSettings,
            "顶部特殊位的屏内三点必须真正触发分区设置"
        )

        // The rest of the real title remains the move handle. This guards
        // against fixing the ellipsis while leaving the title non-draggable.
        let proxyDragStart = NSPoint(
            x: topEditingHeaderLocal.midX,
            y: topEditingHeaderLocal.midY
        )
        guard let proxyMouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: proxyDragStart,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: topInteractionWindow.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ), let proxyMouseDragged = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: proxyDragStart.x - 17, y: proxyDragStart.y - 19),
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: topInteractionWindow.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        ) else {
            preconditionFailure("无法构造顶部标签的拖动回归事件")
        }
        var topRegionLiveFrame: NSRect?
        topInteractionView.onLiveFrameChanged = { topRegionLiveFrame = $0 }
        topInteractionView.mouseDown(with: proxyMouseDown)
        topInteractionView.mouseDragged(with: proxyMouseDragged)
        precondition(
            topRegionLiveFrame != nil && topRegionLiveFrame != topOverflowFrame,
            "顶部特殊位的真实标签必须可以拖动分区"
        )

        let excessiveOverflowProposal = topOverflowProposal.offsetBy(dx: 0, dy: finderMetrics.pitch)
        let limitedOverflowFrame = RegionLayout.snappedMacGridFrame(
            near: excessiveOverflowProposal,
            region: macGridRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics
        )
        precondition(
            limitedOverflowFrame.maxY <= visibleFrame.maxY
                + finderMetrics.pitch
                - RegionLayout.macGridDownwardOffset
                + 0.5,
            "顶部特殊越界只能占用一行，不能继续把图标推到屏幕之外"
        )
        let bottomRowProposal = NSRect(
            x: snappedMacFrame.minX,
            y: visibleFrame.minY
                - 23
                - RegionLayout.macGridDownwardOffset
                - CGFloat(macGridRegion.macGridBottomExtension),
            width: macGridSize.width,
            height: macGridSize.height
        )
        let bottomRowFrame = RegionLayout.snappedMacGridFrame(
            near: bottomRowProposal,
            region: macGridRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics
        )
        precondition(
            abs(
                bottomRowFrame.minY
                    - (visibleFrame.minY
                        - 23
                        - RegionLayout.macGridDownwardOffset
                        - CGFloat(macGridRegion.macGridBottomExtension))
            ) < 0.01,
            "底部档位必须保留同一图标中心线，并只把边界继续向下延伸"
        )
        var bottomRowRegion = macGridRegion
        bottomRowRegion.setFrame(bottomRowFrame)
        let bottomCenters = RegionLayout.macGridSlotCenters(in: bottomRowRegion, metrics: finderMetrics)
        precondition(
            abs(bottomCenters.last!.y - (131 - RegionLayout.macGridDownwardOffset)) < 0.01,
            "底部最后一行图标必须同样下移 44 pt"
        )
        let displacedFrame = RegionLayout.snappedMacGridFrame(
            near: snappedMacFrame,
            region: macGridRegion,
            visibleFrame: visibleFrame,
            metrics: finderMetrics,
            avoiding: [RegionLayout.visualCollisionFrame(for: macGridRegion, metrics: finderMetrics)]
        )
        var displacedRegion = macGridRegion
        displacedRegion.setFrame(displacedFrame)
        precondition(
            !RegionLayout.visualCollisionFrame(for: displacedRegion, metrics: finderMetrics)
                .intersects(RegionLayout.visualCollisionFrame(for: macGridRegion, metrics: finderMetrics)),
            "吸附候选必须避开其他分区从标签栏顶端开始的真实可见占位"
        )

        let macLocalBounds = NSRect(origin: .zero, size: snappedMacFrame.size)
        var macLocalRegion = macGridRegion
        macLocalRegion.setFrame(macLocalBounds)
        macLocalRegion.headerHeight = 36
        let standardMacHeader = RegionLayout.headerRect(
            in: macLocalBounds,
            region: macLocalRegion,
            metrics: finderMetrics
        )
        var collisionRegion = macGridRegion
        collisionRegion.headerHeight = macLocalRegion.headerHeight
        let visibleCollisionFrame = RegionLayout.visualCollisionFrame(
            for: collisionRegion,
            metrics: finderMetrics
        )
        precondition(
            abs(visibleCollisionFrame.maxY - (snappedMacFrame.minY + standardMacHeader.maxY)) < 0.01 &&
                visibleCollisionFrame.maxY < snappedMacFrame.maxY,
            "默认网格骨架和碰撞占位必须从标签栏顶端开始，不能包含上方的透明虚拟行"
        )

        let tallVisibleFrame = NSRect(x: 0, y: 0, width: 1200, height: 1800)
        let upperFrame = RegionLayout.snappedMacGridFrame(
            near: NSRect(x: 700, y: 1100, width: macGridSize.width, height: macGridSize.height),
            region: macGridRegion,
            visibleFrame: tallVisibleFrame,
            metrics: finderMetrics
        )
        var upperRegion = macGridRegion
        upperRegion.setFrame(upperFrame)
        let upperVisibleFootprint = RegionLayout.visualCollisionFrame(
            for: upperRegion,
            metrics: finderMetrics
        )
        let fourRowsBelow = upperFrame.offsetBy(dx: 0, dy: -4 * finderMetrics.pitch)
        let tightlyStackedFrame = RegionLayout.snappedMacGridFrame(
            near: fourRowsBelow,
            region: macGridRegion,
            visibleFrame: tallVisibleFrame,
            metrics: finderMetrics,
            avoiding: [upperVisibleFootprint]
        )
        var tightlyStackedRegion = macGridRegion
        tightlyStackedRegion.setFrame(tightlyStackedFrame)
        let lowerVisibleFootprint = RegionLayout.visualCollisionFrame(
            for: tightlyStackedRegion,
            metrics: finderMetrics
        )
        precondition(
            abs(tightlyStackedFrame.maxY - fourRowsBelow.maxY) < 0.01 &&
                !lowerVisibleFootprint.intersects(upperVisibleFootprint),
            "两个 2×3 默认网格分区应能相隔四个 Finder 步进紧密排列，不再被标签上方的虚拟行多推开一行"
        )
        let firstMacIconY = RegionLayout.macGridSlotCenters(
            in: macLocalRegion,
            metrics: finderMetrics
        )[0].y
        precondition(
            abs(
                standardMacHeader.minY - firstMacIconY - finderMetrics.iconSize / 2
                    - RegionLayout.macHeaderToFirstIconTopGap
            ) < 0.01,
            "Mac 网格标签栏底部必须像默认分区一样贴近第一行图标"
        )
        let approvedManualRegion = Region.defaultNewRegion(
            frame: NSRect(x: 0, y: 0, width: 262, height: 425)
        )
        let approvedManualFirstIconY = RegionLayout.globalSlotCenters(in: approvedManualRegion)[0].y
        let approvedManualVisibleGap = approvedManualRegion.frame.maxY
            - CGFloat(approvedManualRegion.headerHeight)
            - approvedManualFirstIconY
            - finderMetrics.iconSize / 2
        precondition(
            abs(approvedManualVisibleGap - RegionLayout.macHeaderToFirstIconTopGap) <= 0.5,
            "Mac 网格标签栏与图标上沿的距离必须复刻用户批准的默认分区"
        )
        macLocalRegion.headerHeight = 64
        let thickMacHeader = RegionLayout.headerRect(
            in: macLocalBounds,
            region: macLocalRegion,
            metrics: finderMetrics
        )
        precondition(
            thickMacHeader.minY == standardMacHeader.minY &&
                thickMacHeader.maxY > standardMacHeader.maxY,
            "调整 Mac 网格标签栏粗细时必须固定底边，只让顶边向上增长"
        )
        let visualRegion = RegionLayout.visualRegionRect(
            in: macLocalBounds,
            region: macLocalRegion,
            metrics: finderMetrics
        )
        precondition(visualRegion.maxY == thickMacHeader.maxY, "Mac 网格分区的可见顶边必须跟随标签栏顶边")
        let transparentAnchorPoint = NSPoint(
            x: macGridRegion.frame.midX,
            y: macGridRegion.frame.maxY - 1
        )
        precondition(
            macGridRegion.frame.contains(transparentAnchorPoint) &&
                !RegionLayout.visualCollisionFrame(for: macGridRegion).contains(transparentAnchorPoint) &&
                RegionLayout.dropTargetRegion(
                    at: transparentAnchorPoint,
                    in: [macGridRegion]
                ) == nil,
            "视觉上已拖出分区的图标不能因仍处于透明定位行而被误判为需要吸回"
        )
        let visibleDropPoint = NSPoint(
            x: RegionLayout.visualCollisionFrame(for: macGridRegion).midX,
            y: RegionLayout.visualCollisionFrame(for: macGridRegion).midY
        )
        precondition(
            RegionLayout.dropTargetRegion(at: visibleDropPoint, in: [macGridRegion])?.id
                == macGridRegion.id,
            "实际可见区域内部仍必须正常成为拖入目标"
        )

        let newRegionDefaults = Region.defaultNewRegion(frame: NSRect(x: 10, y: 20, width: 262, height: 425))
        precondition(
            newRegionDefaults.frame.size == NSSize(width: 262, height: 425) &&
                newRegionDefaults.gridColumns == 2 && newRegionDefaults.gridRows == 3 &&
                newRegionDefaults.iconSpacing == 125,
            "新增分区必须采用当前 AI 分区的尺寸和 2×3 网格"
        )
        precondition(
            newRegionDefaults.colorHex == "#000000" && newRegionDefaults.opacity == 0.12 &&
                newRegionDefaults.usesFrostedGlass && newRegionDefaults.borderStyle == .none &&
                newRegionDefaults.headerHeight == 36 && newRegionDefaults.titleFontSize == 19 &&
                newRegionDefaults.macGridBottomExtension == 24 &&
                newRegionDefaults.headerStyle == .macNative &&
                newRegionDefaults.surfaceStyle == .macNative,
            "新增分区必须复刻当前 AI 分区的外观默认值"
        )
        precondition(!newRegionDefaults.usesMacDefaultGrid, "新增分区默认仍应保留截图中的 125 pt 手动配置")
        var customizedRegion = newRegionDefaults
        let originalIdentity = customizedRegion.id
        let customizedOriginalFrame = customizedRegion.frame
        customizedRegion.name = "保留这个名称"
        customizedRegion.opacity = 0.73
        customizedRegion.usesMacDefaultGrid = true
        customizedRegion.itemBindings = [
            RegionItemBinding(path: "/tmp/keep-bound-item", slotIndex: 1)
        ]
        customizedRegion.colorHex = "#123456"
        customizedRegion.secondaryColorHex = "#654321"
        customizedRegion.gradientDirection = .topLeftToBottomRight
        customizedRegion.usesFrostedGlass = false
        customizedRegion.borderStyle = .dashDot
        customizedRegion.borderColorHex = "#FF00AA"
        customizedRegion.headerWidthFraction = 0.5
        customizedRegion.headerHeight = 61
        customizedRegion.titleFontSize = 11
        customizedRegion.titleColorHex = "#00FF00"
        customizedRegion.titleFontWeight = .bold
        customizedRegion.headerStyle = .porcelain
        customizedRegion.surfaceStyle = .liquidLight
        customizedRegion.gridColumns = 5
        customizedRegion.gridRows = 4
        customizedRegion.iconSpacing = 79
        customizedRegion.macGridBottomExtension = 67
        customizedRegion.restoreDefaultAdvancedParameters()
        precondition(
            customizedRegion.id == originalIdentity &&
                customizedRegion.name == "保留这个名称" &&
                customizedRegion.frame == customizedOriginalFrame &&
                customizedRegion.opacity == 0.73 &&
                customizedRegion.usesMacDefaultGrid &&
                customizedRegion.itemBindings == [
                    RegionItemBinding(path: "/tmp/keep-bound-item", slotIndex: 1)
                ],
            "恢复默认参数不能改名、移动分区、改透明度、切换全局网格或解绑应用"
        )
        precondition(
            customizedRegion.colorHex == newRegionDefaults.colorHex &&
                customizedRegion.secondaryColorHex == newRegionDefaults.secondaryColorHex &&
                customizedRegion.gradientDirection == newRegionDefaults.gradientDirection &&
                customizedRegion.usesFrostedGlass == newRegionDefaults.usesFrostedGlass &&
                customizedRegion.borderStyle == newRegionDefaults.borderStyle &&
                customizedRegion.borderColorHex == newRegionDefaults.borderColorHex &&
                customizedRegion.headerWidthFraction == newRegionDefaults.headerWidthFraction &&
                customizedRegion.headerHeight == newRegionDefaults.headerHeight &&
                customizedRegion.titleFontSize == newRegionDefaults.titleFontSize &&
                customizedRegion.titleColorHex == newRegionDefaults.titleColorHex &&
                customizedRegion.titleFontWeight == newRegionDefaults.titleFontWeight &&
                customizedRegion.headerStyle == newRegionDefaults.headerStyle &&
                customizedRegion.surfaceStyle == newRegionDefaults.surfaceStyle &&
                customizedRegion.gridColumns == newRegionDefaults.gridColumns &&
                customizedRegion.gridRows == newRegionDefaults.gridRows &&
                customizedRegion.iconSpacing == newRegionDefaults.iconSpacing &&
                customizedRegion.macGridBottomExtension == newRegionDefaults.macGridBottomExtension,
            "恢复默认参数必须与新增分区使用同一套默认外观和网格数值"
        )

        var styledRegion = newRegionDefaults
        styledRegion.colorHex = "#183B32"
        styledRegion.secondaryColorHex = "#B79462"
        styledRegion.opacity = 0.37
        styledRegion.gradientDirection = .bottomLeftToTopRight
        styledRegion.usesFrostedGlass = false
        styledRegion.borderStyle = .dashDot
        styledRegion.borderColorHex = "#D7D0C1"
        styledRegion.applySurfaceStyle(.wovenFiber)
        precondition(
            styledRegion.surfaceStyle == .wovenFiber &&
                styledRegion.colorHex == "#183B32" &&
                styledRegion.secondaryColorHex == "#B79462" &&
                styledRegion.opacity == 0.37 &&
                styledRegion.gradientDirection == .bottomLeftToTopRight &&
                !styledRegion.usesFrostedGlass &&
                styledRegion.borderStyle == .dashDot &&
                styledRegion.borderColorHex == "#D7D0C1",
            "切换分区材质只能改变渲染风格，不能覆盖用户自己设置的外观参数"
        )
        let legacySurfaceMappings: [String: RegionSurfaceStyle] = [
            "monochrome": .monochromeFilm,
            "silverGlass": .layeredGlass,
            "deepOcean": .liquidLight,
            "pine": .wovenFiber,
            "terracotta": .matteCeramic,
            "handmadePaper": .ricePaper,
            "pastelFiberPaper": .ricePaper,
            "cardPaper": .ricePaper,
            "ruledPaper": .ricePaper,
            "clearOutline": .ricePaper,
            "compartment": .ricePaper,
            "custom": .macNative
        ]
        for (legacyValue, expectedStyle) in legacySurfaceMappings {
            let encodedValue = Data("\"\(legacyValue)\"".utf8)
            precondition(
                (try? JSONDecoder().decode(RegionSurfaceStyle.self, from: encodedValue)) == expectedStyle,
                "旧分区风格 \(legacyValue) 必须迁移到新的材质模型"
            )
        }
        precondition(
            (try? JSONDecoder().decode(
                RegionHeaderStyle.self,
                from: Data("\"floatingOutline\"".utf8)
            )) == .macNative,
            "已删除的悬浮线框必须安全回退到 mac 原生标签栏"
        )
        styledRegion.applyHeaderStyle(.porcelain)
        styledRegion.itemBindings = [
            RegionItemBinding(path: "/Users/test/Desktop/owned-by-original.txt", slotIndex: 0)
        ]
        let duplicateFrame = styledRegion.frame.offsetBy(dx: 24, dy: -24)
        let duplicatedRegion = styledRegion.duplicated(
            name: "\(styledRegion.name) 副本",
            frame: duplicateFrame
        )
        precondition(
            duplicatedRegion.id != styledRegion.id &&
                duplicatedRegion.name == "\(styledRegion.name) 副本" &&
                duplicatedRegion.frame == duplicateFrame &&
                duplicatedRegion.role == styledRegion.role &&
                duplicatedRegion.colorHex == styledRegion.colorHex &&
                duplicatedRegion.secondaryColorHex == styledRegion.secondaryColorHex &&
                duplicatedRegion.opacity == styledRegion.opacity &&
                duplicatedRegion.gradientDirection == styledRegion.gradientDirection &&
                duplicatedRegion.usesFrostedGlass == styledRegion.usesFrostedGlass &&
                duplicatedRegion.borderStyle == styledRegion.borderStyle &&
                duplicatedRegion.borderColorHex == styledRegion.borderColorHex &&
                duplicatedRegion.headerHeight == styledRegion.headerHeight &&
                duplicatedRegion.titleFontSize == styledRegion.titleFontSize &&
                duplicatedRegion.titleColorHex == styledRegion.titleColorHex &&
                duplicatedRegion.titleFontWeight == styledRegion.titleFontWeight &&
                duplicatedRegion.headerStyle == styledRegion.headerStyle &&
                duplicatedRegion.surfaceStyle == styledRegion.surfaceStyle &&
                duplicatedRegion.gridColumns == styledRegion.gridColumns &&
                duplicatedRegion.gridRows == styledRegion.gridRows &&
                duplicatedRegion.iconSpacing == styledRegion.iconSpacing &&
                duplicatedRegion.itemBindings.isEmpty,
            "复制分区必须保留全部可调参数、创建新身份，并避免重复绑定同一桌面文件"
        )
        var legacyGlobalRegion = newRegionDefaults
        legacyGlobalRegion.usesMacDefaultGrid = true
        precondition(
            MacDefaultGridPreferencePolicy.resolvedValue(
                persistedValue: nil,
                regions: [newRegionDefaults, legacyGlobalRegion]
            ),
            "旧版任一分区开启过 Mac 网格时，迁移后必须保留为全局开启"
        )
        precondition(
            !MacDefaultGridPreferencePolicy.resolvedValue(
                persistedValue: false,
                regions: [legacyGlobalRegion]
            ),
            "已保存的全局开关必须优先于旧分区字段"
        )
        let globallyEnabledRegions = MacDefaultGridPreferencePolicy.synchronizing(
            [newRegionDefaults, legacyGlobalRegion],
            enabled: true
        )
        precondition(
            globallyEnabledRegions.allSatisfy(\.usesMacDefaultGrid),
            "全局 Mac 网格开关必须同步到所有分区"
        )
        let macGeometryBeforeDisabling = RegionLayout.globalSlotCenters(in: legacyGlobalRegion)
        let disabledWithoutVisualChange = MacDefaultGridPreferencePolicy.synchronizing(
            [legacyGlobalRegion],
            enabled: false
        )[0]
        precondition(
            disabledWithoutVisualChange.frame == legacyGlobalRegion.frame &&
                disabledWithoutVisualChange.gridColumns == legacyGlobalRegion.gridColumns &&
                disabledWithoutVisualChange.gridRows == legacyGlobalRegion.gridRows &&
                disabledWithoutVisualChange.iconSpacing == legacyGlobalRegion.iconSpacing &&
                disabledWithoutVisualChange.preservesMacGridGeometry &&
                RegionLayout.visualCollisionFrame(for: disabledWithoutVisualChange)
                    == RegionLayout.visualCollisionFrame(for: legacyGlobalRegion) &&
                RegionLayout.globalSlotCenters(in: disabledWithoutVisualChange) == macGeometryBeforeDisabling,
            "关闭 Mac 默认网格只能停止后续吸附，不能改变当前 frame、参数或任何图标槽位"
        )
        var movedFrozenRegion = disabledWithoutVisualChange
        movedFrozenRegion.setFrame(disabledWithoutVisualChange.frame.offsetBy(dx: 30, dy: -20))
        precondition(
            !MacDefaultGridPreferencePolicy.shouldExitPreservedGeometry(
                previous: disabledWithoutVisualChange,
                updated: movedFrozenRegion
            ),
            "关闭默认网格后只移动分区位置时必须继续保持当前 Mac 几何"
        )
        var resizedFrozenRegion = disabledWithoutVisualChange
        resizedFrozenRegion.setFrame(NSRect(
            origin: resizedFrozenRegion.frame.origin,
            size: NSSize(
                width: resizedFrozenRegion.frame.width + 20,
                height: resizedFrozenRegion.frame.height
            )
        ))
        precondition(
            MacDefaultGridPreferencePolicy.shouldExitPreservedGeometry(
                previous: disabledWithoutVisualChange,
                updated: resizedFrozenRegion
            ),
            "用户主动修改尺寸或网格参数后才应进入真正的手动几何"
        )

        let temporaryStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopRegions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryStoreURL) }
        let store = RegionStore(fileURL: temporaryStoreURL)
        var persistedRegion = Region(
            name: "状态回归测试",
            role: .custom,
            frame: originalFrame,
            colorHex: "#112233"
        )
        store.add(persistedRegion)
        persistedRegion.setFrame(NSRect(x: 148, y: 206, width: 612, height: 388))
        store.update(persistedRegion)
        let adjustedFrame = persistedRegion.frame
        store.mutate(id: persistedRegion.id) { region in
            region.colorHex = "#AABBCC"
            region.opacity = 0.42
            region.headerHeight = 48
            region.iconSpacing = 112
            region.macGridBottomExtension = 46
            region.usesFrostedGlass = true
            region.borderStyle = .dashDot
            region.borderColorHex = "#55AAFF"
            region.headerStyle = .graphite
            region.surfaceStyle = .blueprintGrid
            region.usesMacDefaultGrid = true
            region.itemBindings = [RegionItemBinding(path: "/Users/test/Desktop/new-file.txt", slotIndex: 2)]
        }
        guard let appearanceUpdated = store.region(id: persistedRegion.id) else {
            preconditionFailure("修改外观后分区不能消失")
        }
        precondition(appearanceUpdated.frame == adjustedFrame, "修改颜色或透明度不能覆盖刚调整的位置和大小")
        precondition(appearanceUpdated.colorHex == "#AABBCC", "外观修改必须写入当前分区")
        let reloadedStore = RegionStore(fileURL: temporaryStoreURL)
        guard let reloaded = reloadedStore.region(id: persistedRegion.id) else {
            preconditionFailure("重启后分区绑定不能丢失")
        }
        precondition(
            reloaded.headerHeight == 48 && reloaded.iconSpacing == 112 &&
                reloaded.macGridBottomExtension == 46,
            "标签高度、图标间距和默认网格底部延伸必须持久化"
        )
        precondition(reloaded.usesFrostedGlass, "磨砂玻璃选项必须持久化")
        precondition(reloaded.usesMacDefaultGrid, "Mac 默认网格选项必须持久化")
        precondition(
            reloaded.borderStyle == .dashDot && reloaded.borderColorHex == "#55AAFF",
            "边框样式和颜色必须持久化"
        )
        precondition(
            reloaded.headerStyle == .graphite && reloaded.surfaceStyle == .blueprintGrid,
            "标签栏与分区风格必须持久化"
        )
        precondition(reloaded.itemBindings.first?.slotIndex == 2, "图标与槽位的绑定必须持久化")

        let firstWorkspaceSnapshot = WorkspaceSnapshot(
            regions: [persistedRegion],
            desktopIconPositions: [
                DesktopIconPosition(path: "/Users/test/Desktop/B.txt", position: NSPoint(x: 42, y: 84)),
                DesktopIconPosition(path: "/Users/test/Desktop/A.txt", position: NSPoint(x: 21, y: 63))
            ],
            usesMacDefaultGrid: false
        )
        let secondWorkspaceSnapshot = WorkspaceSnapshot(
            regions: [reloaded],
            desktopIconPositions: [
                DesktopIconPosition(path: "/Users/test/Desktop/A.txt", position: NSPoint(x: 120, y: 180))
            ],
            usesMacDefaultGrid: true
        )
        var undoHistory = WorkspaceUndoHistory(limit: 2)
        undoHistory.record(title: "第一步", snapshot: firstWorkspaceSnapshot)
        undoHistory.record(title: "第二步", snapshot: secondWorkspaceSnapshot)
        undoHistory.record(title: "重复快照不应新增", snapshot: secondWorkspaceSnapshot)
        precondition(
            undoHistory.steps.count == 2 &&
                undoHistory.nextStep?.title == "第二步" &&
                undoHistory.nextStep?.snapshot.desktopIconPositions.map(\.path)
                    == ["/Users/test/Desktop/A.txt"],
            "撤销历史必须保存完整工作区、稳定排序图标路径，并去除连续重复快照"
        )
        precondition(
            undoHistory.popLast()?.snapshot == secondWorkspaceSnapshot &&
                undoHistory.popLast()?.snapshot == firstWorkspaceSnapshot &&
                undoHistory.popLast() == nil,
            "撤销必须严格按后进先出的操作顺序恢复"
        )

        var occupancyRegion = layoutRegion
        let explicitlyBoundPath = "/Users/test/Desktop/ChatGPT"
        occupancyRegion.itemBindings = [
            RegionItemBinding(path: explicitlyBoundPath, slotIndex: 1, isExplicit: true)
        ]
        precondition(
            RegionBindingPolicy.occupiedSlotIndices(in: occupancyRegion, excludingPaths: []) == [1],
            "只有明确拖入并绑定的应用才能占用灰框"
        )
        precondition(
            RegionBindingPolicy.occupiedSlotIndices(
                in: occupancyRegion,
                excludingPaths: [explicitlyBoundPath]
            ).isEmpty,
            "正在拖动的绑定应用必须立即释放原槽位预览"
        )
        let legacyImplicitBinding = RegionItemBinding(
            path: "/Users/test/Desktop/FlClash",
            slotIndex: 4,
            isExplicit: false
        )
        precondition(
            RegionBindingPolicy.validBindings(
                [legacyImplicitBinding, occupancyRegion.itemBindings[0]],
                existingPaths: [legacyImplicitBinding.path, explicitlyBoundPath],
                capacity: 6
            ) == occupancyRegion.itemBindings,
            "旧版自动认领产生的隐式绑定必须被清理，不能在改网格时移动无关应用"
        )

        var customGridRegion = appearanceUpdated
        customGridRegion.gridColumns = 4
        customGridRegion.gridRows = 2
        let customGridPositions = RegionLayout.finderIconPositions(
            in: customGridRegion,
            screenFrame: screenFrame,
            count: Int.max
        )
        precondition(customGridPositions.count == 8, "自定义横 4 纵 2 后只能生成八个固定网格位置")
        precondition(RegionGradientDirection.allCases.count == 9, "背景必须提供纯色和八个渐变方向")
        precondition(RegionBorderStyle.allCases.count == 6, "边框必须提供无线、实线和四种虚线")
        precondition(RegionHeaderStyle.allCases.count == 6, "标签栏必须提供六种可辨识风格")
        precondition(RegionSurfaceStyle.allCases.count == 13, "分区必须提供原生风和十二种独立材质")
        precondition(
            !RegionHeaderStyle.allCases.map(\.displayName).contains("悬浮线框") &&
                !RegionSurfaceStyle.allCases.map(\.displayName).contains("分格收纳"),
            "已否决的悬浮线框和分格收纳不能继续出现在风格列表"
        )
        precondition(
            Set(RegionSurfaceStyle.allCases.map(\.displayName)).isSuperset(
                of: ["云龙纤维纸", "牛皮档案纸"]
            ) && !RegionSurfaceStyle.allCases.map(\.displayName).contains("暖白手工纸") &&
                !RegionSurfaceStyle.allCases.map(\.displayName).contains("低饱和棉纸") &&
                RegionHeaderStyle.allCases.map(\.displayName).contains("纸签标签"),
            "分区只能保留云龙纤维纸和牛皮档案纸两种纸材"
        )
        precondition(
            RegionSurfaceStyle.ricePaper.isPaper &&
                RegionSurfaceStyle.kraftArchivePaper.isPaper &&
                !RegionSurfaceStyle.macNative.isPaper &&
                !RegionSurfaceStyle.layeredGlass.isPaper,
            "只有实体纸张材质才能关闭背景透视并将透明度改为着色强度"
        )
        precondition(
            Set(RegionSurfaceStyle.allCases.map(\.displayName)).isSuperset(
                of: ["全息偏振膜", "液态铬", "光刻电路"]
            ),
            "未来科技分区必须包含全息、金属与光刻三种不同材质机制"
        )
        precondition(
            !RegionSurfaceStyle.allCases.map(\.displayName).contains("毛毡纹卡纸") &&
                !RegionSurfaceStyle.allCases.map(\.displayName).contains("冷压水彩纸"),
            "用户否决的两种纸材不能继续出现在风格列表"
        )
        precondition(RegionBorderStyle.dashDot.dashPattern == [12, 5, 2, 5], "点划线必须使用稳定的虚线节奏")

        let desktopPath = "/Users/test/Desktop/new-file.txt"
        let newItem = FinderDesktopItem(url: URL(fileURLWithPath: desktopPath), position: NSPoint(x: 900, y: 400))
        let newlyAppeared = FinderDesktopChangeDetector.changedItems(
            previous: [:],
            current: [desktopPath: newItem],
            selectedPaths: []
        )
        precondition(newlyAppeared == [newItem], "从 Finder 窗口拖来的新桌面项即使未选中也必须被识别")

        let oldItem = FinderDesktopItem(url: newItem.url, position: NSPoint(x: 100, y: 100))
        let movedSelected = FinderDesktopChangeDetector.changedItems(
            previous: [desktopPath: oldItem],
            current: [desktopPath: newItem],
            selectedPaths: [desktopPath]
        )
        precondition(movedSelected == [newItem], "拖动已有桌面项时必须识别选中项坐标变化")

        let movedUnselected = FinderDesktopChangeDetector.changedItems(
            previous: [desktopPath: oldItem],
            current: [desktopPath: newItem],
            selectedPaths: []
        )
        precondition(movedUnselected.isEmpty, "不能把 Finder 自动重排的未选中旧项目误判为用户拖动")

        let movedTrackedButUnselected = FinderDesktopChangeDetector.changedItems(
            previous: [desktopPath: oldItem],
            current: [desktopPath: newItem],
            selectedPaths: [],
            trackedMovementPaths: [desktopPath]
        )
        precondition(
            movedTrackedButUnselected == [newItem],
            "松手后 Finder 即使瞬间取消选中，也必须凭本次拖动路径立即识别坐标变化"
        )

        let movedEvents = FinderDesktopPollEventPipeline.events(
            previous: [desktopPath: oldItem],
            current: [desktopPath: newItem],
            selectedPaths: [],
            trackedMovementPaths: [desktopPath]
        )
        precondition(
            movedEvents.count == 2 && movedEvents[0].isMovement && movedEvents[1].isSnapshot,
            "同一次轮询必须先处理用户移动和解绑，再检查绑定漂移，避免旧绑定抢先弹回"
        )
        let programmaticPath = "/Users/test/Desktop/programmatic.txt"
        let userPath = "/Users/test/Desktop/user-drag.txt"
        let programmaticOld = FinderDesktopItem(
            url: URL(fileURLWithPath: programmaticPath),
            position: NSPoint(x: 10, y: 10)
        )
        let programmaticNew = FinderDesktopItem(
            url: programmaticOld.url,
            position: NSPoint(x: 500, y: 500)
        )
        let userOld = FinderDesktopItem(
            url: URL(fileURLWithPath: userPath),
            position: NSPoint(x: 20, y: 20)
        )
        let userNew = FinderDesktopItem(
            url: userOld.url,
            position: NSPoint(x: 700, y: 700)
        )
        var programmaticTracker = FinderProgrammaticMoveTracker()
        programmaticTracker.register([
            DesktopIconPosition(path: programmaticPath, position: programmaticNew.position)
        ])
        let fulfilledProgrammaticPaths = programmaticTracker.fulfilledPaths(
            in: [programmaticPath: programmaticNew, userPath: userNew]
        )
        precondition(
            fulfilledProgrammaticPaths == [programmaticPath],
            "程序移动只能按路径和目标坐标精确兑现，不能清空整个 Finder 基线"
        )
        let mixedEvents = FinderDesktopPollEventPipeline.events(
            previous: [programmaticPath: programmaticOld, userPath: userOld],
            current: [programmaticPath: programmaticNew, userPath: userNew],
            selectedPaths: [],
            trackedMovementPaths: [userPath],
            ignoredMovementPaths: fulfilledProgrammaticPaths
        )
        precondition(
            mixedEvents.count == 2 &&
                mixedEvents[0] == .movement(
                    items: [userNew],
                    previousItems: [programmaticOld, userOld]
                ),
            "程序吸附和用户拖动同时发生时必须只忽略程序路径，用户移动仍要立即解绑"
        )
        programmaticTracker.consume(fulfilledProgrammaticPaths)
        precondition(
            programmaticTracker.pendingPaths.isEmpty,
            "观察到程序目标后必须只消费对应路径的预期"
        )
        for index in 1...1_000 {
            let stressPath = "/Users/test/Desktop/stress-\(index).txt"
            let stressURL = URL(fileURLWithPath: stressPath)
            let stressOld = FinderDesktopItem(
                url: stressURL,
                position: NSPoint(x: index, y: index * 2)
            )
            let stressNew = FinderDesktopItem(
                url: stressURL,
                position: NSPoint(x: index + 300, y: index * 2 + 200)
            )
            let events = FinderDesktopPollEventPipeline.events(
                previous: [stressPath: stressOld],
                current: [stressPath: stressNew],
                selectedPaths: [],
                trackedMovementPaths: [stressPath]
            )
            precondition(
                events.count == 2 && events[0].isMovement && events[1].isSnapshot,
                "1000 次松手竞态压力测试中每一次都必须先提交移动，再发布 Finder 快照"
            )
        }
        print("drag interaction and region layout: PASS")
    }
}
