// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

private final class EdgeTabPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum SettingsTableLayout {
    static let duplicateWidth: CGFloat = 52
    static let colorWidth: CGFloat = 76
    static let opacityWidth: CGFloat = 214
    static let mappingWidth: CGFloat = 76
    static let collapseWidth: CGFloat = 76
    static let viewWidth: CGFloat = 100
    static let moreWidth: CGFloat = 64

    static func frames(in bounds: NSRect) -> (
        duplicate: NSRect,
        color: NSRect,
        name: NSRect,
        opacity: NSRect,
        mapping: NSRect,
        collapse: NSRect,
        view: NSRect,
        more: NSRect
    ) {
        let nameWidth = max(
            190,
            bounds.width - duplicateWidth - colorWidth - opacityWidth - moreWidth - mappingWidth - collapseWidth - viewWidth
        )
        let duplicate = NSRect(x: 0, y: 0, width: duplicateWidth, height: bounds.height)
        let color = NSRect(x: duplicate.maxX, y: 0, width: colorWidth, height: bounds.height)
        let name = NSRect(x: color.maxX, y: 0, width: nameWidth, height: bounds.height)
        let opacity = NSRect(x: name.maxX, y: 0, width: opacityWidth, height: bounds.height)
        let mapping = NSRect(x: opacity.maxX, y: 0, width: mappingWidth, height: bounds.height)
        let collapse = NSRect(x: mapping.maxX, y: 0, width: collapseWidth, height: bounds.height)
        let view = NSRect(x: collapse.maxX, y: 0, width: viewWidth, height: bounds.height)
        let more = NSRect(x: view.maxX, y: 0, width: moreWidth, height: bounds.height)
        return (duplicate, color, name, opacity, mapping, collapse, view, more)
    }
}

private final class SettingsTableHeaderView: NSView {
    private let duplicateLabel = NSTextField(labelWithString: "复制")
    private let colorLabel = NSTextField(labelWithString: "颜色")
    private let nameLabel = NSTextField(labelWithString: "分区名")
    private let opacityLabel = NSTextField(labelWithString: "透明 / 着色")
    private let mappingLabel = NSTextField(labelWithString: "映射文件夹")
    private let collapseLabel = NSTextField(labelWithString: "允许收起")
    private let viewLabel = NSTextField(labelWithString: "显示方式")
    private let moreLabel = NSTextField(labelWithString: "更多")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        [duplicateLabel, colorLabel, nameLabel, opacityLabel, mappingLabel, collapseLabel, viewLabel, moreLabel].forEach {
            $0.alignment = .center
            $0.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            $0.textColor = .secondaryLabelColor
            addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let columns = SettingsTableLayout.frames(in: bounds)
        duplicateLabel.frame = columns.duplicate.insetBy(dx: 4, dy: 10)
        colorLabel.frame = columns.color.insetBy(dx: 4, dy: 10)
        nameLabel.frame = columns.name.insetBy(dx: 4, dy: 10)
        opacityLabel.frame = columns.opacity.insetBy(dx: 4, dy: 10)
        mappingLabel.frame = columns.mapping.insetBy(dx: 2, dy: 10)
        collapseLabel.frame = columns.collapse.insetBy(dx: 2, dy: 10)
        viewLabel.frame = columns.view.insetBy(dx: 2, dy: 10)
        moreLabel.frame = columns.more.insetBy(dx: 4, dy: 10)
    }
}

final class RegionRowView: NSView {
    let regionID: UUID
    private let duplicateButton = NSButton()
    private let nameField = NSTextField()
    private let colorWell = NSColorWell()
    private let opacitySlider = NSSlider(value: 0.26, minValue: 0.12, maxValue: 0.70, target: nil, action: nil)
    private let opacityStepper = NSStepper()
    private let mappingButton = NSButton()
    private let collapseCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let displayPopup = NSPopUpButton()
    private let moreButton = NSButton()
    private let separator = NSBox()

    private var currentName: String
    private var onDuplicate: ((UUID) -> Void)?
    private var onNameChanged: ((UUID, String) -> Void)?
    private var onColorChanged: ((UUID, String) -> Void)?
    private var onOpacityChanged: ((UUID, Double) -> Void)?
    private var onMore: ((UUID) -> Void)?
    private var onMapping: ((UUID, NSView) -> Void)?
    private var onCollapseAllowed: ((UUID, Bool) -> Void)?
    private var onDisplayMode: ((UUID, RegionDisplayMode) -> Void)?
    private var onDelete: ((UUID) -> Void)?
    private var isDeleteMode = false

    init(
        region: Region,
        onDuplicate: @escaping (UUID) -> Void,
        onNameChanged: @escaping (UUID, String) -> Void,
        onColorChanged: @escaping (UUID, String) -> Void,
        onOpacityChanged: @escaping (UUID, Double) -> Void,
        onMore: @escaping (UUID) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onMapping: @escaping (UUID, NSView) -> Void,
        onCollapseAllowed: @escaping (UUID, Bool) -> Void,
        onDisplayMode: @escaping (UUID, RegionDisplayMode) -> Void
    ) {
        regionID = region.id
        currentName = region.name
        self.onDuplicate = onDuplicate
        self.onNameChanged = onNameChanged
        self.onColorChanged = onColorChanged
        self.onOpacityChanged = onOpacityChanged
        self.onMore = onMore
        self.onDelete = onDelete
        self.onMapping = onMapping
        self.onCollapseAllowed = onCollapseAllowed
        self.onDisplayMode = onDisplayMode
        super.init(frame: .zero)

        duplicateButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "复制分区"
        )
        duplicateButton.imagePosition = .imageOnly
        duplicateButton.bezelStyle = .inline
        duplicateButton.isBordered = false
        duplicateButton.contentTintColor = .secondaryLabelColor
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicatePressed)
        duplicateButton.toolTip = "创建参数相同的分区副本"

        nameField.stringValue = region.name
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .exterior
        nameField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        nameField.alignment = .center
        nameField.placeholderString = "分区名称"
        nameField.target = self
        nameField.action = #selector(nameChanged)
        nameField.delegate = self

        colorWell.color = NSColor(hex: region.colorHex)
        colorWell.colorWellStyle = .minimal
        colorWell.target = self
        colorWell.action = #selector(colorChanged)

        opacitySlider.doubleValue = region.opacity
        opacitySlider.controlSize = .small
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)

        opacityStepper.minValue = opacitySlider.minValue
        opacityStepper.maxValue = opacitySlider.maxValue
        opacityStepper.increment = 0.01
        opacityStepper.doubleValue = region.opacity
        opacityStepper.valueWraps = false
        opacityStepper.autorepeat = true
        opacityStepper.target = self
        opacityStepper.action = #selector(opacityStepped)
        updateOpacitySemantics(for: region)

        mappingButton.bezelStyle = .inline
        mappingButton.isBordered = false
        mappingButton.imagePosition = .imageOnly
        mappingButton.target = self
        mappingButton.action = #selector(mappingPressed)
        collapseCheckbox.target = self
        collapseCheckbox.action = #selector(collapseAllowedChanged)
        collapseCheckbox.toolTip = "在分区左上角显示展开 / 收起按钮"
        displayPopup.addItems(withTitles: RegionDisplayMode.allCases.map(\.displayName))
        displayPopup.controlSize = .small
        displayPopup.target = self
        displayPopup.action = #selector(displayModeChanged)
        updateFileControls(region)

        moreButton.bezelStyle = .inline
        moreButton.isBordered = false
        moreButton.imagePosition = .imageOnly
        moreButton.target = self
        moreButton.action = #selector(morePressed)
        setDeleteMode(false)

        separator.boxType = .separator
        [duplicateButton, colorWell, nameField, opacitySlider, opacityStepper, mappingButton, collapseCheckbox, displayPopup, moreButton, separator]
            .forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let columns = SettingsTableLayout.frames(in: bounds)
        duplicateButton.frame = NSRect(
            x: columns.duplicate.midX - 16,
            y: bounds.midY - 15,
            width: 32,
            height: 30
        )
        colorWell.frame = NSRect(x: columns.color.midX - 16, y: bounds.midY - 14, width: 32, height: 28)
        nameField.frame = columns.name.insetBy(dx: 14, dy: 14)
        let opacityContent = columns.opacity.insetBy(dx: 16, dy: 15)
        opacityStepper.frame = NSRect(
            x: opacityContent.maxX - 20,
            y: bounds.midY - 13,
            width: 20,
            height: 26
        )
        opacitySlider.frame = NSRect(
            x: opacityContent.minX,
            y: opacityContent.minY,
            width: max(80, opacityContent.width - 34),
            height: opacityContent.height
        )
        mappingButton.frame = NSRect(x: columns.mapping.midX - 17, y: bounds.midY - 15, width: 34, height: 30)
        collapseCheckbox.frame = NSRect(x: columns.collapse.midX - 9, y: bounds.midY - 10, width: 20, height: 20)
        displayPopup.frame = NSRect(x: columns.view.minX + 5, y: bounds.midY - 13, width: columns.view.width - 10, height: 26)
        moreButton.frame = NSRect(x: columns.more.midX - 18, y: bounds.midY - 16, width: 36, height: 32)
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    func update(with region: Region) {
        guard region.id == regionID else { return }
        currentName = region.name
        if window?.firstResponder !== nameField.currentEditor() {
            nameField.stringValue = region.name
        }
        colorWell.color = NSColor(hex: region.colorHex)
        opacitySlider.doubleValue = region.opacity
        opacityStepper.doubleValue = region.opacity
        updateOpacitySemantics(for: region)
        updateFileControls(region)
    }

    private func updateFileControls(_ region: Region) {
        mappingButton.image = NSImage(systemSymbolName: region.isMapped ? "folder.fill.badge.gearshape" : "folder",
                                      accessibilityDescription: region.isMapped ? "已映射文件夹" : "选择映射文件夹")
        mappingButton.contentTintColor = region.isMapped ? .systemBlue : .systemGray
        mappingButton.toolTip = region.mappedFolderPath.map { "已映射：\($0)\n点击更换、打开或解除映射；排序在“更多”设置中调整" } ?? "未映射：点击选择真实文件夹"
        collapseCheckbox.state = region.allowsCollapse ? .on : .off
        displayPopup.selectItem(at: RegionDisplayMode.allCases.firstIndex(of: region.displayMode) ?? 0)
    }

    @objc private func mappingPressed() { onMapping?(regionID, mappingButton) }
    @objc private func collapseAllowedChanged() { onCollapseAllowed?(regionID, collapseCheckbox.state == .on) }
    @objc private func displayModeChanged() { onDisplayMode?(regionID, RegionDisplayMode.allCases[displayPopup.indexOfSelectedItem]) }

    private func updateOpacitySemantics(for region: Region) {
        let description = region.surfaceStyle.isPaper
            ? "调整纸面着色强度；纸张始终不透明"
            : "调整分区透明度"
        opacitySlider.toolTip = description
        opacityStepper.toolTip = description
    }

    func setDeleteMode(_ enabled: Bool) {
        isDeleteMode = enabled
        if enabled {
            moreButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除分区")
            moreButton.contentTintColor = .systemRed
            moreButton.toolTip = "删除这个分区"
        } else {
            moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
            moreButton.contentTintColor = .secondaryLabelColor
            moreButton.toolTip = "外观、网格与文件排序"
        }
    }

    @objc private func nameChanged() {
        commitName()
    }

    @objc private func duplicatePressed() {
        onDuplicate?(regionID)
    }

    @objc private func colorChanged() {
        onColorChanged?(regionID, colorWell.color.hexString)
    }

    @objc private func opacityChanged() {
        opacityStepper.doubleValue = opacitySlider.doubleValue
        onOpacityChanged?(regionID, opacitySlider.doubleValue)
    }

    @objc private func opacityStepped() {
        opacitySlider.doubleValue = opacityStepper.doubleValue
        onOpacityChanged?(regionID, opacityStepper.doubleValue)
    }

    @objc private func morePressed() {
        if isDeleteMode {
            onDelete?(regionID)
        } else {
            onMore?(regionID)
        }
    }

    fileprivate func commitName() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameField.stringValue = currentName
            return
        }
        currentName = trimmed
        onNameChanged?(regionID, trimmed)
    }
}

extension RegionRowView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitName()
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private let tableHeader = SettingsTableHeaderView()
    private let tableBackground = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var editButton = NSButton(title: "进入编辑模式", target: self, action: #selector(toggleEditMode))
    private lazy var collapseButton: NSButton = {
        let button = NSButton(
            title: "收起到右侧  >",
            target: self,
            action: #selector(collapsePressed)
        )
        button.toolTip = "隐藏设置窗口，并在屏幕右侧保留展开标签"
        return button
    }()
    private lazy var deleteModeButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "切换删除模式")
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggleDeleteMode)
        button.toolTip = "进入删除模式"
        return button
    }()
    private lazy var macDefaultGridCheckbox = NSButton(
        checkboxWithTitle: "采用 Mac 默认网格",
        target: self,
        action: #selector(macDefaultGridChanged)
    )
    private lazy var launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "登录时自动启动饭格",
        target: self,
        action: #selector(launchAtLoginChanged)
    )
    private var rowsByID: [UUID: RegionRowView] = [:]
    private var isDeleteMode = false
    private var edgePanel: NSPanel?
    private var expandedFrame: NSRect?
    private var visibilityState: SettingsPanelVisibilityState = .expanded
    private var advancedEditor: RegionAdvancedWindowController?
    private var helpPopover: NSPopover?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "饭格"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1040, height: 540)
        window.setFrameAutosaveName("DesktopRegionsSettingsWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
        window.center()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        edgePanel?.orderOut(nil)
        NotificationCenter.default.removeObserver(self)
    }

    func refresh() {
        rowsByID.removeAll()
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        guard let appDelegate else { return }
        macDefaultGridCheckbox.state = appDelegate.usesMacDefaultGrid ? .on : .off
        setLaunchAtLoginState(appDelegate.loginItemState)
        for region in appDelegate.store.regions {
            let row = RegionRowView(
                region: region,
                onDuplicate: { [weak appDelegate] id in
                    appDelegate?.duplicateRegion(id: id)
                },
                onNameChanged: { [weak appDelegate] id, name in
                    appDelegate?.mutateRegion(id: id) { $0.name = name }
                },
                onColorChanged: { [weak appDelegate] id, color in
                    appDelegate?.mutateRegion(id: id) { $0.colorHex = color }
                },
                onOpacityChanged: { [weak appDelegate] id, opacity in
                    appDelegate?.mutateRegion(id: id) { $0.opacity = opacity }
                },
                onMore: { [weak self] id in
                    self?.showAdvancedSettings(for: id)
                },
                onDelete: { [weak self] id in
                    self?.deleteRegion(id: id)
                },
                onMapping: { [weak appDelegate] id, view in
                    appDelegate?.requestFolderMapping(for: id, from: view)
                },
                onCollapseAllowed: { [weak appDelegate] id, allowed in
                    appDelegate?.mutateRegion(id: id, actionName: "设置分区收起") {
                        $0.allowsCollapse = allowed
                        if !allowed { $0.isCollapsed = false }
                    }
                },
                onDisplayMode: { [weak appDelegate] id, mode in
                    appDelegate?.mutateRegion(id: id, actionName: "切换图标显示方式") { $0.displayMode = mode }
                }
            )
            row.setDeleteMode(isDeleteMode)
            row.heightAnchor.constraint(equalToConstant: 54).isActive = true
            listStack.addArrangedSubview(row)
            rowsByID[region.id] = row
        }

        synchronizeTableGeometry()
    }

    func updateRegionRow(_ region: Region) {
        rowsByID[region.id]?.update(with: region)
    }

    func updateAdvancedEditor(_ region: Region) {
        advancedEditor?.update(with: region)
    }

    func showAdvancedSettings(for id: UUID) {
        guard let appDelegate, let region = appDelegate.store.region(id: id) else { return }
        advancedEditor?.close()
        let controller = RegionAdvancedWindowController(region: region, appDelegate: appDelegate)
        advancedEditor = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setEditMode(_ enabled: Bool) {
        editButton.title = enabled ? "完成编辑" : "进入编辑模式"
        let action: SettingsPanelVisibilityAction = enabled
            ? .enteredEditMode
            : .leftEditMode
        let nextState = SettingsPanelVisibilityPolicy.nextState(
            from: visibilityState,
            action: action
        )
        if nextState == .collapsed {
            collapseToEdge()
        }
    }

    func setMacDefaultGridEnabled(_ enabled: Bool) {
        macDefaultGridCheckbox.state = enabled ? .on : .off
    }

    func setLaunchAtLoginState(_ state: LoginItemState) {
        launchAtLoginCheckbox.allowsMixedState = false
        switch state {
        case .enabled:
            launchAtLoginCheckbox.state = .on
            launchAtLoginCheckbox.toolTip = "饭格会在你登录 Mac 时自动启动"
        case .disabled:
            launchAtLoginCheckbox.state = .off
            launchAtLoginCheckbox.toolTip = "开启后，饭格会在你登录 Mac 时自动启动"
        case .unavailable:
            launchAtLoginCheckbox.state = .off
            launchAtLoginCheckbox.toolTip = "暂时无法读取饭格的登录项状态"
        }
    }

    func expandFromEdge() {
        guard let window else { return }
        edgePanel?.orderOut(nil)
        if let expandedFrame {
            let screen = screen(containing: expandedFrame)
                ?? window.screen
                ?? NSScreen.main
                ?? NSScreen.screens.first
            if let screen {
                window.setFrame(
                    SettingsEdgePanelLayout.restoredWindowFrame(
                        expandedFrame,
                        in: screen.visibleFrame
                    ),
                    display: false
                )
            }
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        visibilityState = SettingsPanelVisibilityPolicy.nextState(
            from: visibilityState,
            action: .requestedSettings
        )
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            window.makeFirstResponder(nil)
        }
    }

    func collapseToEdge() {
        guard let window,
              window.isVisible || window.isMiniaturized,
              visibilityState != .collapsed
        else { return }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeFirstResponder(nil)
        helpPopover?.close()
        expandedFrame = window.frame

        guard let screen = window.screen
                ?? screen(containing: window.frame)
                ?? NSScreen.main
                ?? NSScreen.screens.first
        else { return }

        let handleFrame = SettingsEdgePanelLayout.handleFrame(
            in: screen.visibleFrame
        )
        let panel: NSPanel
        if let edgePanel {
            panel = edgePanel
            panel.setFrame(handleFrame, display: true)
        } else {
            panel = makeEdgePanel(frame: handleFrame)
            edgePanel = panel
        }
        visibilityState = SettingsPanelVisibilityPolicy.nextState(
            from: visibilityState,
            action: .manualCollapse
        )
        window.orderOut(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeEdgePanel(frame: NSRect) -> NSPanel {
        let panel = EdgeTabPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setAccessibilityLabel("饭格设置展开标签")

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        let button = NSButton(
            title: "<",
            target: self,
            action: #selector(expandPressed)
        )
        button.frame = background.bounds
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        button.contentTintColor = .white
        button.toolTip = "展开饭格设置"
        button.setAccessibilityLabel("展开饭格设置")
        background.addSubview(button)
        panel.contentView = background
        return panel
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { lhs, rhs in
                lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
                    < rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
            }
    }

    private func makeContentView() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 622))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = makeBrandTitleView()

        let helpButton = NSButton()
        helpButton.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "使用说明")
        helpButton.imagePosition = .imageOnly
        helpButton.isBordered = false
        helpButton.contentTintColor = .secondaryLabelColor
        helpButton.target = self
        helpButton.action = #selector(showHelp(_:))
        helpButton.toolTip = "展开详细使用说明"
        helpButton.frame = NSRect(x: 1018, y: 566, width: 32, height: 32)
        helpButton.autoresizingMask = [.minXMargin, .minYMargin]

        macDefaultGridCheckbox.state = appDelegate?.usesMacDefaultGrid == true ? .on : .off
        macDefaultGridCheckbox.toolTip = "所有分区统一采用 Finder 的网格步进，并与桌面组件顶部对齐"
        macDefaultGridCheckbox.frame = NSRect(x: 800, y: 570, width: 202, height: 24)
        macDefaultGridCheckbox.autoresizingMask = [.minXMargin, .minYMargin]

        setLaunchAtLoginState(appDelegate?.loginItemState ?? .unavailable)
        launchAtLoginCheckbox.frame = NSRect(x: 578, y: 570, width: 210, height: 24)
        launchAtLoginCheckbox.autoresizingMask = [.minXMargin, .minYMargin]

        tableBackground.frame = NSRect(x: 30, y: 112, width: 1020, height: 410)
        tableBackground.wantsLayer = true
        tableBackground.layer?.cornerRadius = 16
        tableBackground.layer?.borderWidth = 1
        tableBackground.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        tableBackground.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.34).cgColor
        tableBackground.layer?.masksToBounds = true
        tableBackground.autoresizingMask = [.width, .height]

        tableHeader.frame = NSRect(x: 0, y: tableBackground.bounds.height - 40, width: tableBackground.bounds.width, height: 40)
        // Its width tracks the scroll clip view, not the outer card: the
        // vertical scroller consumes a few points that the data rows cannot use.
        tableHeader.autoresizingMask = [.minYMargin]
        tableBackground.addSubview(tableHeader)

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 0

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = listStack
        scrollView.frame = NSRect(x: 0, y: 38, width: tableBackground.bounds.width, height: tableBackground.bounds.height - 78)
        scrollView.autoresizingMask = [.width, .height]
        tableBackground.addSubview(scrollView)
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollClipViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        let addSmallButton = NSButton(title: "+", target: self, action: #selector(addRegion))
        addSmallButton.bezelStyle = .inline
        addSmallButton.isBordered = false
        addSmallButton.font = NSFont.systemFont(ofSize: 20, weight: .regular)
        addSmallButton.frame = NSRect(x: 8, y: 2, width: 34, height: 34)
        addSmallButton.toolTip = "添加分区"
        tableBackground.addSubview(addSmallButton)

        deleteModeButton.frame = NSRect(x: 44, y: 2, width: 34, height: 34)
        tableBackground.addSubview(deleteModeButton)

        let footerSeparator = NSBox(frame: NSRect(x: 0, y: 37, width: tableBackground.bounds.width, height: 1))
        footerSeparator.boxType = .separator
        footerSeparator.autoresizingMask = [.width, .maxYMargin]
        tableBackground.addSubview(footerSeparator)

        editButton.bezelStyle = .rounded
        collapseButton.bezelStyle = .rounded
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let updateButton = NSButton(title: "检查更新…", target: appDelegate, action: #selector(AppDelegate.checkForUpdates))
        updateButton.bezelStyle = .rounded
        updateButton.toolTip = "检查作者在 GitHub 发布的新版本"
        let footer = NSStackView(views: [editButton, collapseButton, updateButton, NSView(), statusLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.frame = NSRect(x: 30, y: 48, width: 1020, height: 34)
        footer.autoresizingMask = [.width, .maxYMargin]

        [title, launchAtLoginCheckbox, macDefaultGridCheckbox, helpButton, tableBackground, footer].forEach(root.addSubview)
        synchronizeTableGeometry()
        return root
    }

    private func synchronizeTableGeometry() {
        let contentWidth = max(0, scrollView.contentView.bounds.width)
        guard contentWidth > 0 else { return }
        let rowCount = max(1, listStack.arrangedSubviews.count)
        let documentHeight = max(
            scrollView.contentView.bounds.height,
            CGFloat(rowCount) * 54
        )
        tableHeader.frame.size.width = contentWidth
        listStack.frame = NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: documentHeight
        )
        tableHeader.needsLayout = true
        listStack.needsLayout = true
        rowsByID.values.forEach { $0.needsLayout = true }
        tableHeader.layoutSubtreeIfNeeded()
        listStack.layoutSubtreeIfNeeded()
    }

    @objc private func scrollClipViewFrameChanged(_ notification: Notification) {
        synchronizeTableGeometry()
    }

    private func makeBrandTitleView() -> NSView {
        if let url = Bundle.main.url(forResource: "FangeTitle", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignLeft
            imageView.frame = NSRect(x: 30, y: 554, width: 148, height: 54)
            imageView.autoresizingMask = [.maxXMargin, .minYMargin]
            imageView.setAccessibilityLabel("饭格")
            return imageView
        }

        let fallback = NSTextField(labelWithString: "饭格")
        fallback.font = NSFont.systemFont(ofSize: 25, weight: .bold)
        fallback.frame = NSRect(x: 30, y: 568, width: 148, height: 34)
        fallback.autoresizingMask = [.maxXMargin, .minYMargin]
        return fallback
    }

    private func makeHelpViewController() -> NSViewController {
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 650))

        let title = NSTextField(labelWithString: "饭格使用说明")
        title.font = NSFont.systemFont(ofSize: 19, weight: .bold)
        title.frame = NSRect(x: 24, y: 614, width: 382, height: 28)
        root.addSubview(title)

        let instructions = [
            ("普通模式", "直接双击或拖动 Finder 桌面图标。把图标松到分区内后，它会吸附到该分区预设的网格位置。"),
            ("编辑与设置窗口", "点击“进入编辑模式”后拖动分区空白处可移动，拖右下角可缩放；设置窗会自动收回到右侧。也可手动点击“收起到右侧”，再点屏幕右侧的 < 标签召回。窗口仍保留标准红黄绿按钮，切换其他 App 时不会自动关闭。"),
            ("映射文件夹", "点击灰色文件夹图标选择目录。蓝色图标表示已映射，可更换、打开或解除映射。内容实时刷新，超出分区时向下滚动；拖入文件会移动到真实目录，同名文件不会被覆盖。"),
            ("文件排序", "点击映射或列表分区的三个点，在“文件排序”区域选择排序依据、升降序和文件夹优先。规则独立保存并立即生效，也可在文件区右键 → 排序方式，或从菜单栏的分区子菜单设置。"),
            ("检查更新", "菜单栏或设置底部点击“检查更新…”，查看 GitHub 新版本与更新说明，并一键下载、校验、覆盖安装和重启。每次启动自动检查一次，无更新时保持安静。"),
            ("收起与列表", "每个分区默认允许收起，点击左上角箭头即可切换。在“允许收起”列可关闭该功能；“显示方式”可切换大图标或列表。可收起的大图标保留原槽位和缓存，收展立即切换整层显示。文件仍在桌面，应用运行时持续隐藏对应的 Finder 原图标；关闭可收起、解除绑定或退出后恢复。"),
            ("复制、名称与自动启动", "每行左侧可复制分区，名称可直接编辑。右上角可设置登录时自动启动饭格。"),
            ("风格与更多设置", "点击每行或分区标题栏里的三个点，可切换标签栏及分区风格，也可细调字号、颜色、渐变、边框和网格。"),
            ("固定网格", "主设置右上角可让所有分区采用 Finder 网格。关闭开关只停止后续吸附，当前分区位置、外观和图标槽位不会变化。"),
            ("拖放与撤销", "拖动开始后会立即释放原槽位并显示灰框；拖出可见边界即解除绑定，拖回后立即吸附。菜单栏“撤销”可恢复分区参数、绑定及桌面图标位置，也可把移入映射文件夹的文件移回原位置。")
        ]

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: 382, height: 576))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let content = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 12
        for (heading, body) in instructions {
            content.append(NSAttributedString(string: heading + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            content.append(NSAttributedString(string: body + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph]))
        }
        text.textStorage?.setAttributedString(content)
        scroll.documentView = text
        root.addSubview(scroll)

        controller.view = root
        return controller
    }

    @objc private func addRegion() {
        appDelegate?.addRegion()
    }

    @objc private func toggleDeleteMode() {
        setDeleteMode(!isDeleteMode)
    }

    private func setDeleteMode(_ enabled: Bool) {
        isDeleteMode = enabled
        deleteModeButton.contentTintColor = enabled ? .systemRed : .secondaryLabelColor
        deleteModeButton.toolTip = enabled ? "退出删除模式" : "进入删除模式"
        rowsByID.values.forEach { $0.setDeleteMode(enabled) }
        if enabled {
            advancedEditor?.close()
            advancedEditor = nil
            statusLabel.stringValue = "删除模式：点击红色垃圾桶删除对应分区，再按 − 退出"
        } else if statusLabel.stringValue.hasPrefix("删除模式：") {
            statusLabel.stringValue = ""
        }
    }

    private func deleteRegion(id: UUID) {
        appDelegate?.deleteRegion(id: id)
    }

    @objc private func toggleEditMode() {
        appDelegate?.toggleEditMode()
    }

    @objc private func collapsePressed() {
        collapseToEdge()
    }

    @objc private func expandPressed() {
        expandFromEdge()
    }

    @objc private func macDefaultGridChanged() {
        appDelegate?.setMacDefaultGridEnabled(macDefaultGridCheckbox.state == .on)
    }

    @objc private func launchAtLoginChanged() {
        appDelegate?.setLaunchAtLoginEnabled(launchAtLoginCheckbox.state == .on)
    }

    @objc private func showHelp(_ sender: NSButton) {
        if helpPopover?.isShown == true {
            helpPopover?.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 430, height: 650)
        popover.contentViewController = makeHelpViewController()
        helpPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func windowDidResize(_ notification: Notification) {
        if visibilityState == .expanded {
            expandedFrame = window?.frame
        }
        synchronizeTableGeometry()
    }

    func windowDidMove(_ notification: Notification) {
        if visibilityState == .expanded {
            expandedFrame = window?.frame
        }
    }

    func windowWillClose(_ notification: Notification) {
        edgePanel?.orderOut(nil)
        visibilityState = .expanded
    }

    @objc private func screenParametersChanged() {
        guard visibilityState == .collapsed,
              let panel = edgePanel,
              let referenceFrame = expandedFrame,
              let screen = screen(containing: referenceFrame)
                ?? NSScreen.main
                ?? NSScreen.screens.first
        else { return }
        panel.setFrame(
            SettingsEdgePanelLayout.handleFrame(in: screen.visibleFrame),
            display: true
        )
    }
}
