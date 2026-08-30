// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

final class RegionAdvancedWindowController: NSWindowController {
    private weak var appDelegate: AppDelegate?
    private let regionID: UUID

    private let surfaceStylePopup = NSPopUpButton()
    private let headerStylePopup = NSPopUpButton()
    private let headerHeightSlider = NSSlider(value: 34, minValue: 28, maxValue: 64, target: nil, action: nil)
    private let headerHeightValue = NSTextField(labelWithString: "34 pt")
    private let headerHeightStepper = NSStepper()
    private let fontSizeSlider = NSSlider(value: 13, minValue: 10, maxValue: 22, target: nil, action: nil)
    private let fontSizeValue = NSTextField(labelWithString: "13 pt")
    private let fontSizeStepper = NSStepper()
    private let titleColorWell = NSColorWell()
    private let weightPopup = NSPopUpButton()
    private let gradientPopup = NSPopUpButton()
    private let primaryColorWell = NSColorWell()
    private let secondaryColorWell = NSColorWell()
    private let frostedCheckbox = NSButton(checkboxWithTitle: "macOS 磨砂玻璃", target: nil, action: nil)
    private let borderPopup = NSPopUpButton()
    private let borderColorWell = NSColorWell()
    private let columnsStepper = NSStepper()
    private let rowsStepper = NSStepper()
    private let columnsValue = NSTextField(labelWithString: "2")
    private let rowsValue = NSTextField(labelWithString: "3")
    private let iconSpacingSlider = NSSlider(value: 96, minValue: 72, maxValue: 160, target: nil, action: nil)
    private let iconSpacingValue = NSTextField(labelWithString: "96 pt")
    private let iconSpacingStepper = NSStepper()
    private let bottomExtensionSlider = NSSlider(value: 24, minValue: 0, maxValue: 80, target: nil, action: nil)
    private let bottomExtensionValue = NSTextField(labelWithString: "24 pt")
    private let bottomExtensionStepper = NSStepper()
    private let spacingHint = NSTextField(wrappingLabelWithString: "网格始终保持居中；拉宽分区只增加两侧余量，不会把图标推到两边。")
    private let restoreDefaultsButton = NSButton(
        title: "恢复默认参数",
        target: nil,
        action: nil
    )

    init(region: Region, appDelegate: AppDelegate) {
        self.regionID = region.id
        self.appDelegate = appDelegate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 848),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(region.name) · 更多设置"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.center()
        super.init(window: window)

        window.contentView = makeContentView()
        update(with: region)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with region: Region) {
        guard region.id == regionID else { return }
        window?.title = "\(region.name) · 更多设置"

        surfaceStylePopup.selectItem(
            at: RegionSurfaceStyle.allCases.firstIndex(of: region.surfaceStyle) ?? 0
        )
        headerStylePopup.selectItem(
            at: RegionHeaderStyle.allCases.firstIndex(of: region.headerStyle) ?? 0
        )
        headerHeightSlider.doubleValue = region.headerHeight
        headerHeightValue.stringValue = "\(Int(region.headerHeight.rounded())) pt"
        headerHeightStepper.doubleValue = region.headerHeight
        fontSizeSlider.doubleValue = region.titleFontSize
        fontSizeValue.stringValue = "\(Int(region.titleFontSize.rounded())) pt"
        fontSizeStepper.doubleValue = region.titleFontSize
        titleColorWell.color = NSColor(hex: region.titleColorHex)
        weightPopup.selectItem(at: RegionTitleWeight.allCases.firstIndex(of: region.titleFontWeight) ?? 2)
        gradientPopup.selectItem(at: RegionGradientDirection.allCases.firstIndex(of: region.gradientDirection) ?? 0)
        primaryColorWell.color = NSColor(hex: region.colorHex)
        secondaryColorWell.color = NSColor(hex: region.secondaryColorHex)
        secondaryColorWell.isEnabled = true
        let usesSolidPaperSubstrate = region.surfaceStyle.isPaper
        frostedCheckbox.state = !usesSolidPaperSubstrate && region.usesFrostedGlass ? .on : .off
        frostedCheckbox.isEnabled = !usesSolidPaperSubstrate
        frostedCheckbox.toolTip = usesSolidPaperSubstrate
            ? "纸质风格使用实体底材，不启用透明磨砂"
            : "让桌面颜色透过分区背景"
        borderPopup.selectItem(at: RegionBorderStyle.allCases.firstIndex(of: region.borderStyle) ?? 1)
        borderColorWell.color = NSColor(hex: region.borderColorHex)
        borderColorWell.isEnabled = region.borderStyle != .none
        columnsStepper.integerValue = region.gridColumns
        rowsStepper.integerValue = region.gridRows
        columnsValue.stringValue = "\(region.gridColumns)"
        rowsValue.stringValue = "\(region.gridRows)"
        iconSpacingSlider.doubleValue = region.iconSpacing
        iconSpacingValue.stringValue = "\(Int(region.iconSpacing.rounded())) pt"
        iconSpacingStepper.doubleValue = region.iconSpacing
        bottomExtensionSlider.doubleValue = region.macGridBottomExtension
        bottomExtensionValue.stringValue = "\(Int(region.macGridBottomExtension.rounded())) pt"
        bottomExtensionStepper.doubleValue = region.macGridBottomExtension
        let isManualGrid = !region.usesMacDefaultGrid
        headerHeightSlider.isEnabled = true
        headerHeightStepper.isEnabled = true
        headerHeightValue.textColor = .labelColor
        iconSpacingSlider.isEnabled = isManualGrid
        iconSpacingStepper.isEnabled = isManualGrid
        iconSpacingValue.textColor = isManualGrid ? .labelColor : .tertiaryLabelColor
        bottomExtensionSlider.isEnabled = !isManualGrid
        bottomExtensionStepper.isEnabled = !isManualGrid
        bottomExtensionValue.textColor = !isManualGrid ? .labelColor : .tertiaryLabelColor
        if region.usesMacDefaultGrid {
            let metrics = FinderDesktopGridMetrics.current()
            spacingHint.stringValue = "跟随 Finder：图标 \(Int(metrics.iconSize.rounded())) pt + 间隔 \(Int(metrics.gridSpacing.rounded())) pt；最上方档位与桌面组件顶部对齐。"
        } else {
            spacingHint.stringValue = "网格始终保持居中；拉宽分区只增加两侧余量，不会把图标推到两边。"
        }
    }

    private func makeContentView() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 820))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let heading = NSTextField(labelWithString: "分区外观与网格")
        heading.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        heading.frame = NSRect(x: 28, y: 778, width: 464, height: 30)
        root.addSubview(heading)

        addSectionTitle("风格方案", y: 746, to: root)
        surfaceStylePopup.addItems(withTitles: RegionSurfaceStyle.allCases.map(\.displayName))
        surfaceStylePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        surfaceStylePopup.target = self
        surfaceStylePopup.action = #selector(surfaceStyleChanged)
        surfaceStylePopup.toolTip = "切换独立材质层；纸质风格使用不透明底材，透明度滑杆改为控制着色强度"
        addRow(label: "分区风格", controls: [surfaceStylePopup], y: 706, to: root)

        headerStylePopup.addItems(withTitles: RegionHeaderStyle.allCases.map(\.displayName))
        headerStylePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        headerStylePopup.target = self
        headerStylePopup.action = #selector(headerStyleChanged)
        headerStylePopup.toolTip = "只切换顶部标签栏的材质与黑白关系"
        addRow(label: "标签栏风格", controls: [headerStylePopup], y: 666, to: root)

        addSectionTitle("顶部标签栏", y: 642, to: root)
        configureSlider(headerHeightSlider, action: #selector(headerHeightChanged))
        configureNumericStepper(
            headerHeightStepper,
            matching: headerHeightSlider,
            increment: 1,
            action: #selector(headerHeightStepped)
        )
        headerHeightValue.widthAnchor.constraint(equalToConstant: 52).isActive = true
        addRow(
            label: "标签栏高度",
            controls: [headerHeightSlider, headerHeightValue, headerHeightStepper],
            y: 602,
            to: root
        )

        configureSlider(fontSizeSlider, action: #selector(fontSizeChanged))
        configureNumericStepper(
            fontSizeStepper,
            matching: fontSizeSlider,
            increment: 1,
            action: #selector(fontSizeStepped)
        )
        fontSizeValue.widthAnchor.constraint(equalToConstant: 52).isActive = true
        addRow(
            label: "名称字号",
            controls: [fontSizeSlider, fontSizeValue, fontSizeStepper],
            y: 562,
            to: root
        )

        configureColorWell(titleColorWell, action: #selector(titleColorChanged))
        weightPopup.addItems(withTitles: RegionTitleWeight.allCases.map(\.displayName))
        weightPopup.widthAnchor.constraint(equalToConstant: 104).isActive = true
        weightPopup.target = self
        weightPopup.action = #selector(weightChanged)
        addRow(label: "文字颜色与粗细", controls: [titleColorWell, weightPopup], y: 522, to: root)

        addSectionTitle("分区背景", y: 484, to: root)
        gradientPopup.addItems(withTitles: RegionGradientDirection.allCases.map(\.displayName))
        gradientPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        gradientPopup.target = self
        gradientPopup.action = #selector(gradientChanged)
        addRow(label: "填色方向", controls: [gradientPopup], y: 444, to: root)

        configureColorWell(primaryColorWell, action: #selector(primaryColorChanged))
        configureColorWell(secondaryColorWell, action: #selector(secondaryColorChanged))
        secondaryColorWell.toolTip = "终点颜色可随时选择；选择渐变方向后立即显示"
        let colorArrow = NSTextField(labelWithString: "→")
        colorArrow.alignment = .center
        colorArrow.textColor = .secondaryLabelColor
        addRow(label: "起点与终点颜色", controls: [primaryColorWell, colorArrow, secondaryColorWell], y: 404, to: root)

        frostedCheckbox.target = self
        frostedCheckbox.action = #selector(frostedChanged)
        addRow(label: "透明质感", controls: [frostedCheckbox], y: 364, to: root)

        addSectionTitle("分区边框", y: 326, to: root)
        borderPopup.addItems(withTitles: RegionBorderStyle.allCases.map(\.displayName))
        borderPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        borderPopup.target = self
        borderPopup.action = #selector(borderStyleChanged)
        addRow(label: "线条样式", controls: [borderPopup], y: 286, to: root)

        configureColorWell(borderColorWell, action: #selector(borderColorChanged))
        addRow(label: "线条颜色", controls: [borderColorWell], y: 246, to: root)

        addSectionTitle("图标网格", y: 208, to: root)
        configureStepper(columnsStepper, action: #selector(columnsChanged))
        configureStepper(rowsStepper, action: #selector(rowsChanged))
        let columnsLabel = NSTextField(labelWithString: "横向")
        let rowsLabel = NSTextField(labelWithString: "纵向")
        columnsLabel.textColor = .secondaryLabelColor
        rowsLabel.textColor = .secondaryLabelColor
        addRow(
            label: "固定行列数",
            controls: [columnsLabel, columnsValue, columnsStepper, rowsLabel, rowsValue, rowsStepper],
            y: 168,
            to: root
        )

        configureSlider(iconSpacingSlider, action: #selector(iconSpacingChanged))
        configureNumericStepper(
            iconSpacingStepper,
            matching: iconSpacingSlider,
            increment: 1,
            action: #selector(iconSpacingStepped)
        )
        iconSpacingValue.widthAnchor.constraint(equalToConstant: 52).isActive = true
        addRow(
            label: "图标间距",
            controls: [iconSpacingSlider, iconSpacingValue, iconSpacingStepper],
            y: 126,
            to: root
        )

        configureSlider(bottomExtensionSlider, action: #selector(bottomExtensionChanged))
        configureNumericStepper(
            bottomExtensionStepper,
            matching: bottomExtensionSlider,
            increment: 1,
            action: #selector(bottomExtensionStepped)
        )
        bottomExtensionValue.widthAnchor.constraint(equalToConstant: 52).isActive = true
        addRow(
            label: "下边界延伸",
            controls: [bottomExtensionSlider, bottomExtensionValue, bottomExtensionStepper],
            y: 86,
            to: root
        )

        spacingHint.font = NSFont.systemFont(ofSize: 11)
        spacingHint.textColor = .secondaryLabelColor
        spacingHint.frame = NSRect(x: 184, y: 42, width: 290, height: 34)
        root.addSubview(spacingHint)

        restoreDefaultsButton.target = self
        restoreDefaultsButton.action = #selector(restoreDefaultParameters)
        restoreDefaultsButton.bezelStyle = .rounded
        restoreDefaultsButton.controlSize = .regular
        restoreDefaultsButton.toolTip = "恢复新增分区的默认外观与网格；名称、位置和透明度不变"
        restoreDefaultsButton.frame = NSRect(x: 354, y: 8, width: 120, height: 30)
        root.addSubview(restoreDefaultsButton)

        return root
    }

    private func addSectionTitle(_ text: String, y: CGFloat, to root: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 28, y: y, width: 464, height: 20)
        root.addSubview(label)
    }

    private func addRow(label text: String, controls: [NSView], y: CGFloat, to root: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.frame = NSRect(x: 40, y: y + 5, width: 132, height: 22)
        root.addSubview(label)

        let stack = NSStackView(views: controls)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.distribution = .fill
        stack.frame = NSRect(x: 184, y: y, width: 290, height: 30)
        controls.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addSubview(stack)
    }

    private func configureSlider(_ slider: NSSlider, action: Selector) {
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 168).isActive = true
    }

    private func configureNumericStepper(
        _ stepper: NSStepper,
        matching slider: NSSlider,
        increment: Double,
        action: Selector
    ) {
        stepper.minValue = slider.minValue
        stepper.maxValue = slider.maxValue
        stepper.increment = increment
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.target = self
        stepper.action = action
        stepper.toolTip = "点击上下键微调"
    }

    private func configureColorWell(_ colorWell: NSColorWell, action: Selector) {
        colorWell.target = self
        colorWell.action = action
        colorWell.colorWellStyle = .minimal
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func configureStepper(_ stepper: NSStepper, action: Selector) {
        stepper.minValue = 1
        stepper.maxValue = 12
        stepper.increment = 1
        stepper.target = self
        stepper.action = action
    }

    @objc private func surfaceStyleChanged() {
        let style = RegionSurfaceStyle.allCases[max(0, surfaceStylePopup.indexOfSelectedItem)]
        appDelegate?.mutateRegion(id: regionID) { $0.applySurfaceStyle(style) }
    }

    @objc private func headerStyleChanged() {
        let style = RegionHeaderStyle.allCases[max(0, headerStylePopup.indexOfSelectedItem)]
        appDelegate?.mutateRegion(id: regionID) { $0.applyHeaderStyle(style) }
    }

    @objc private func headerHeightChanged() {
        let value = headerHeightSlider.doubleValue.rounded()
        headerHeightSlider.doubleValue = value
        headerHeightStepper.doubleValue = value
        headerHeightValue.stringValue = "\(Int(value)) pt"
        appDelegate?.mutateRegion(id: regionID) { region in
            region.headerHeight = value
            ensureMinimumFrame(for: &region)
        }
    }

    @objc private func headerHeightStepped() {
        headerHeightSlider.doubleValue = headerHeightStepper.doubleValue
        headerHeightChanged()
    }

    @objc private func fontSizeChanged() {
        let value = fontSizeSlider.doubleValue.rounded()
        fontSizeSlider.doubleValue = value
        fontSizeStepper.doubleValue = value
        fontSizeValue.stringValue = "\(Int(value)) pt"
        appDelegate?.mutateRegion(id: regionID) { $0.titleFontSize = value }
    }

    @objc private func fontSizeStepped() {
        fontSizeSlider.doubleValue = fontSizeStepper.doubleValue
        fontSizeChanged()
    }

    @objc private func titleColorChanged() {
        let value = titleColorWell.color.hexString
        appDelegate?.mutateRegion(id: regionID) { $0.titleColorHex = value }
    }

    @objc private func weightChanged() {
        let value = RegionTitleWeight.allCases[max(0, weightPopup.indexOfSelectedItem)]
        appDelegate?.mutateRegion(id: regionID) { $0.titleFontWeight = value }
    }

    @objc private func gradientChanged() {
        let value = RegionGradientDirection.allCases[max(0, gradientPopup.indexOfSelectedItem)]
        secondaryColorWell.isEnabled = true
        appDelegate?.mutateRegion(id: regionID) { $0.gradientDirection = value }
    }

    @objc private func primaryColorChanged() {
        let value = primaryColorWell.color.hexString
        appDelegate?.mutateRegion(id: regionID) { $0.colorHex = value }
    }

    @objc private func secondaryColorChanged() {
        let value = secondaryColorWell.color.hexString
        appDelegate?.mutateRegion(id: regionID) { $0.secondaryColorHex = value }
    }

    @objc private func frostedChanged() {
        let enabled = frostedCheckbox.state == .on
        appDelegate?.mutateRegion(id: regionID) { $0.usesFrostedGlass = enabled }
    }

    @objc private func borderStyleChanged() {
        let value = RegionBorderStyle.allCases[max(0, borderPopup.indexOfSelectedItem)]
        borderColorWell.isEnabled = value != .none
        appDelegate?.mutateRegion(id: regionID) { $0.borderStyle = value }
    }

    @objc private func borderColorChanged() {
        let value = borderColorWell.color.hexString
        appDelegate?.mutateRegion(id: regionID) { $0.borderColorHex = value }
    }

    @objc private func columnsChanged() {
        applyGrid(columns: columnsStepper.integerValue, rows: nil)
    }

    @objc private func rowsChanged() {
        applyGrid(columns: nil, rows: rowsStepper.integerValue)
    }

    @objc private func iconSpacingChanged() {
        guard appDelegate?.usesMacDefaultGrid != true else { return }
        let value = iconSpacingSlider.doubleValue.rounded()
        iconSpacingSlider.doubleValue = value
        iconSpacingStepper.doubleValue = value
        iconSpacingValue.stringValue = "\(Int(value)) pt"
        appDelegate?.mutateRegion(id: regionID) { region in
            region.iconSpacing = value
            ensureMinimumFrame(for: &region)
        }
    }

    @objc private func iconSpacingStepped() {
        iconSpacingSlider.doubleValue = iconSpacingStepper.doubleValue
        iconSpacingChanged()
    }

    @objc private func bottomExtensionChanged() {
        guard appDelegate?.usesMacDefaultGrid == true else { return }
        let value = bottomExtensionSlider.doubleValue.rounded()
        bottomExtensionSlider.doubleValue = value
        bottomExtensionStepper.doubleValue = value
        bottomExtensionValue.stringValue = "\(Int(value)) pt"
        appDelegate?.mutateRegion(id: regionID) { region in
            region.macGridBottomExtension = value
        }
    }

    @objc private func bottomExtensionStepped() {
        bottomExtensionSlider.doubleValue = bottomExtensionStepper.doubleValue
        bottomExtensionChanged()
    }

    @objc private func restoreDefaultParameters() {
        appDelegate?.mutateRegion(id: regionID) { region in
            region.restoreDefaultAdvancedParameters()
            if !region.usesMacDefaultGrid {
                ensureMinimumFrame(for: &region)
            }
        }
    }

    private func applyGrid(columns: Int?, rows: Int?) {
        appDelegate?.mutateRegion(id: regionID) { region in
            if let columns { region.gridColumns = columns }
            if let rows { region.gridRows = rows }
            if !region.usesMacDefaultGrid {
                ensureMinimumFrame(for: &region)
            }
        }
    }

    private func ensureMinimumFrame(for region: inout Region) {
        let minimum = RegionLayout.minimumRegionSize(
            columns: region.gridColumns,
            rows: region.gridRows,
            headerHeight: CGFloat(region.headerHeight),
            iconSpacing: CGFloat(region.iconSpacing)
        )
        guard region.frame.width < minimum.width || region.frame.height < minimum.height else { return }
        let oldFrame = region.frame
        let newHeight = max(oldFrame.height, minimum.height)
        region.setFrame(NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - newHeight,
            width: max(oldFrame.width, minimum.width),
            height: newHeight
        ))
    }

}
