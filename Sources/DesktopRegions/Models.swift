// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

enum RegionRole: String, Codable, CaseIterable {
    case work
    case inbox
    case media
    case reference
    case custom

    var displayName: String {
        switch self {
        case .work: return "工作文件"
        case .inbox: return "待整理"
        case .media: return "图片与素材"
        case .reference: return "参考资料"
        case .custom: return "自定义"
        }
    }
}

enum RegionGradientDirection: String, Codable, CaseIterable {
    case solid
    case topToBottom
    case bottomToTop
    case leftToRight
    case rightToLeft
    case topLeftToBottomRight
    case bottomRightToTopLeft
    case topRightToBottomLeft
    case bottomLeftToTopRight

    var displayName: String {
        switch self {
        case .solid: return "纯色"
        case .topToBottom: return "从上到下"
        case .bottomToTop: return "从下到上"
        case .leftToRight: return "从左到右"
        case .rightToLeft: return "从右到左"
        case .topLeftToBottomRight: return "左上到右下"
        case .bottomRightToTopLeft: return "右下到左上"
        case .topRightToBottomLeft: return "右上到左下"
        case .bottomLeftToTopRight: return "左下到右上"
        }
    }

    var gradientAngle: CGFloat {
        switch self {
        case .solid: return 0
        case .leftToRight: return 0
        case .bottomLeftToTopRight: return 45
        case .bottomToTop: return 90
        case .bottomRightToTopLeft: return 135
        case .rightToLeft: return 180
        case .topRightToBottomLeft: return 225
        case .topToBottom: return 270
        case .topLeftToBottomRight: return 315
        }
    }
}

enum RegionBorderStyle: String, Codable, CaseIterable {
    case none
    case solid
    case shortDash
    case longDash
    case dotted
    case dashDot

    var displayName: String {
        switch self {
        case .none: return "无线条"
        case .solid: return "实线"
        case .shortDash: return "短虚线"
        case .longDash: return "长虚线"
        case .dotted: return "点线"
        case .dashDot: return "点划线"
        }
    }

    var dashPattern: [CGFloat] {
        switch self {
        case .none, .solid: return []
        case .shortDash: return [7, 5]
        case .longDash: return [16, 8]
        case .dotted: return [1.5, 5]
        case .dashDot: return [12, 5, 2, 5]
        }
    }
}

enum RegionTitleWeight: String, Codable, CaseIterable {
    case regular
    case medium
    case semibold
    case bold

    var displayName: String {
        switch self {
        case .regular: return "常规"
        case .medium: return "中等"
        case .semibold: return "半粗"
        case .bold: return "粗体"
        }
    }

    var fontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

enum RegionHeaderStyle: String, Codable, CaseIterable {
    case macNative
    case ink
    case porcelain
    case graphite
    case colorTint
    case paperLabel

    var displayName: String {
        switch self {
        case .macNative: return "mac 原生风"
        case .ink: return "墨黑标签"
        case .porcelain: return "雪白标签"
        case .graphite: return "石墨渐层"
        case .colorTint: return "同色融合"
        case .paperLabel: return "纸签标签"
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if let currentStyle = RegionHeaderStyle(rawValue: value) {
            self = currentStyle
        } else {
            // The removed floating outline used a light title that would not
            // remain readable on paper, so legacy selections return to native.
            self = .macNative
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum RegionSurfaceStyle: String, Codable, CaseIterable {
    case macNative
    case layeredGlass
    case monochromeFilm
    case brushedMetal
    case blueprintGrid
    case matteCeramic
    case wovenFiber
    case liquidLight
    case ricePaper
    case kraftArchivePaper
    case holographicFoil
    case liquidChrome
    case etchedCircuit

    var displayName: String {
        switch self {
        case .macNative: return "mac 原生风"
        case .layeredGlass: return "叠层玻璃"
        case .monochromeFilm: return "黑白胶片"
        case .brushedMetal: return "拉丝金属"
        case .blueprintGrid: return "蓝图网格"
        case .matteCeramic: return "雾面陶瓷"
        case .wovenFiber: return "织物纤维"
        case .liquidLight: return "流体晕染"
        case .ricePaper: return "云龙纤维纸"
        case .kraftArchivePaper: return "牛皮档案纸"
        case .holographicFoil: return "全息偏振膜"
        case .liquidChrome: return "液态铬"
        case .etchedCircuit: return "光刻电路"
        }
    }

    /// Paper surfaces use a solid substrate. The appearance slider tints that
    /// substrate instead of exposing the desktop through it.
    var isPaper: Bool {
        switch self {
        case .ricePaper, .kraftArchivePaper:
            return true
        default:
            return false
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if let currentStyle = RegionSurfaceStyle(rawValue: value) {
            self = currentStyle
            return
        }

        // Migrate the former color-preset names to the closest real material.
        // The user's saved appearance parameters are preserved by Region.
        switch value {
        case "monochrome": self = .monochromeFilm
        case "silverGlass": self = .layeredGlass
        case "deepOcean": self = .liquidLight
        case "pine": self = .wovenFiber
        case "terracotta": self = .matteCeramic
        case "handmadePaper", "pastelFiberPaper",
             "cardPaper", "ruledPaper", "clearOutline", "compartment": self = .ricePaper
        case "custom": self = .macNative
        default: self = .macNative
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct RegionItemBinding: Codable, Equatable {
    var path: String
    var slotIndex: Int
    var isExplicit: Bool

    init(path: String, slotIndex: Int, isExplicit: Bool = true) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.slotIndex = slotIndex
        self.isExplicit = isExplicit
    }

    private enum CodingKeys: String, CodingKey {
        case path, slotIndex, isExplicit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = URL(
            fileURLWithPath: try container.decode(String.self, forKey: .path)
        ).standardizedFileURL.path
        slotIndex = try container.decode(Int.self, forKey: .slotIndex)
        // Bindings saved by the buggy auto-adoption build have no provenance.
        // Treat them as implicit so they can be removed once instead of moving
        // unrelated desktop items when a grid changes.
        isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
    }
}

enum RegionBindingPolicy {
    static func occupiedSlotIndices(
        in region: Region,
        excludingPaths: Set<String>
    ) -> Set<Int> {
        let capacity = min(12, max(1, region.gridColumns)) * min(12, max(1, region.gridRows))
        return Set(region.itemBindings.compactMap { binding -> Int? in
            guard binding.isExplicit,
                  !excludingPaths.contains(binding.path),
                  (0..<capacity).contains(binding.slotIndex) else { return nil }
            return binding.slotIndex
        })
    }

    static func validBindings(
        _ bindings: [RegionItemBinding],
        existingPaths: Set<String>,
        capacity: Int
    ) -> [RegionItemBinding] {
        var seenPaths = Set<String>()
        var seenSlots = Set<Int>()
        return bindings.filter { binding in
            guard binding.isExplicit,
                  existingPaths.contains(binding.path),
                  (0..<capacity).contains(binding.slotIndex),
                  seenPaths.insert(binding.path).inserted,
                  seenSlots.insert(binding.slotIndex).inserted else { return false }
            return true
        }
    }
}

enum MacDefaultGridPreferencePolicy {
    static func resolvedValue(persistedValue: Bool?, regions: [Region]) -> Bool {
        persistedValue ?? regions.contains { $0.usesMacDefaultGrid }
    }

    static func synchronizing(_ regions: [Region], enabled: Bool) -> [Region] {
        regions.map { storedRegion in
            var region = storedRegion
            let currentlyUsesMacGeometry = region.usesMacGridGeometry
            region.usesMacDefaultGrid = enabled
            region.preservesMacGridGeometry = enabled ? false : currentlyUsesMacGeometry
            return region
        }
    }

    static func shouldExitPreservedGeometry(previous: Region, updated: Region) -> Bool {
        guard !updated.usesMacDefaultGrid,
              updated.preservesMacGridGeometry
        else { return false }
        return previous.frame.size != updated.frame.size ||
            previous.gridColumns != updated.gridColumns ||
            previous.gridRows != updated.gridRows ||
            previous.iconSpacing != updated.iconSpacing ||
            previous.headerHeight != updated.headerHeight ||
            previous.macGridBottomExtension != updated.macGridBottomExtension
    }
}

struct Region: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var role: RegionRole
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var colorHex: String
    var secondaryColorHex: String
    var opacity: Double
    var gradientDirection: RegionGradientDirection
    var usesFrostedGlass: Bool
    var borderStyle: RegionBorderStyle
    var borderColorHex: String
    var usesMacDefaultGrid: Bool
    /// Turning the global Mac-grid switch off must be visually lossless. Keep
    /// the current Finder geometry until the user explicitly changes a manual
    /// size or grid parameter.
    var preservesMacGridGeometry: Bool
    /// Extra painted space below the last Finder row. This extends only the
    /// region boundary so multi-line desktop labels remain visually contained.
    var macGridBottomExtension: Double
    // Retained only so existing saved data can still be decoded. The title bar
    // now always spans the full region width.
    var headerWidthFraction: Double
    var headerHeight: Double
    var titleFontSize: Double
    var titleColorHex: String
    var titleFontWeight: RegionTitleWeight
    var headerStyle: RegionHeaderStyle
    var surfaceStyle: RegionSurfaceStyle
    var gridColumns: Int
    var gridRows: Int
    var iconSpacing: Double
    var itemBindings: [RegionItemBinding]

    init(
        id: UUID = UUID(),
        name: String,
        role: RegionRole,
        frame: NSRect,
        colorHex: String,
        secondaryColorHex: String? = nil,
        opacity: Double = 0.26,
        gradientDirection: RegionGradientDirection = .solid,
        usesFrostedGlass: Bool = false,
        borderStyle: RegionBorderStyle = .solid,
        borderColorHex: String = "#FFFFFF",
        usesMacDefaultGrid: Bool = false,
        preservesMacGridGeometry: Bool = false,
        macGridBottomExtension: Double = 24,
        headerWidthFraction: Double = 1,
        headerHeight: Double = 34,
        titleFontSize: Double = 13,
        titleColorHex: String = "#FFFFFF",
        titleFontWeight: RegionTitleWeight = .semibold,
        headerStyle: RegionHeaderStyle = .macNative,
        surfaceStyle: RegionSurfaceStyle = .macNative,
        gridColumns: Int = 2,
        gridRows: Int = 3,
        iconSpacing: Double = 96,
        itemBindings: [RegionItemBinding] = []
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.x = Double(frame.origin.x)
        self.y = Double(frame.origin.y)
        self.width = Double(frame.size.width)
        self.height = Double(frame.size.height)
        self.colorHex = colorHex
        self.secondaryColorHex = secondaryColorHex ?? colorHex
        self.opacity = opacity
        self.gradientDirection = gradientDirection
        self.usesFrostedGlass = usesFrostedGlass
        self.borderStyle = borderStyle
        self.borderColorHex = borderColorHex
        self.usesMacDefaultGrid = usesMacDefaultGrid
        self.preservesMacGridGeometry = preservesMacGridGeometry
        self.macGridBottomExtension = macGridBottomExtension
        self.headerWidthFraction = headerWidthFraction
        self.headerHeight = headerHeight
        self.titleFontSize = titleFontSize
        self.titleColorHex = titleColorHex
        self.titleFontWeight = titleFontWeight
        self.headerStyle = headerStyle
        self.surfaceStyle = surfaceStyle
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.iconSpacing = iconSpacing
        self.itemBindings = itemBindings
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, role, x, y, width, height, colorHex, secondaryColorHex, opacity
        case gradientDirection, usesFrostedGlass, borderStyle, borderColorHex, usesMacDefaultGrid
        case preservesMacGridGeometry
        case macGridBottomExtension
        case headerWidthFraction, headerHeight, titleFontSize, titleColorHex, titleFontWeight
        case headerStyle, surfaceStyle
        case gridColumns, gridRows, iconSpacing, itemBindings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(RegionRole.self, forKey: .role)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        secondaryColorHex = try container.decodeIfPresent(String.self, forKey: .secondaryColorHex) ?? colorHex
        opacity = try container.decode(Double.self, forKey: .opacity)
        gradientDirection = try container.decodeIfPresent(RegionGradientDirection.self, forKey: .gradientDirection) ?? .solid
        usesFrostedGlass = try container.decodeIfPresent(Bool.self, forKey: .usesFrostedGlass) ?? false
        borderStyle = try container.decodeIfPresent(RegionBorderStyle.self, forKey: .borderStyle) ?? .solid
        borderColorHex = try container.decodeIfPresent(String.self, forKey: .borderColorHex) ?? "#FFFFFF"
        usesMacDefaultGrid = try container.decodeIfPresent(Bool.self, forKey: .usesMacDefaultGrid) ?? false
        preservesMacGridGeometry = try container.decodeIfPresent(
            Bool.self,
            forKey: .preservesMacGridGeometry
        ) ?? false
        macGridBottomExtension = try container.decodeIfPresent(
            Double.self,
            forKey: .macGridBottomExtension
        ) ?? 24
        headerWidthFraction = try container.decodeIfPresent(Double.self, forKey: .headerWidthFraction) ?? 1
        headerHeight = try container.decodeIfPresent(Double.self, forKey: .headerHeight) ?? 34
        titleFontSize = try container.decodeIfPresent(Double.self, forKey: .titleFontSize) ?? 13
        titleColorHex = try container.decodeIfPresent(String.self, forKey: .titleColorHex) ?? "#FFFFFF"
        titleFontWeight = try container.decodeIfPresent(RegionTitleWeight.self, forKey: .titleFontWeight) ?? .semibold
        headerStyle = try container.decodeIfPresent(RegionHeaderStyle.self, forKey: .headerStyle) ?? .macNative
        surfaceStyle = try container.decodeIfPresent(RegionSurfaceStyle.self, forKey: .surfaceStyle) ?? .macNative
        gridColumns = try container.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 2
        gridRows = try container.decodeIfPresent(Int.self, forKey: .gridRows) ?? 3
        iconSpacing = try container.decodeIfPresent(Double.self, forKey: .iconSpacing) ?? 96
        itemBindings = try container.decodeIfPresent([RegionItemBinding].self, forKey: .itemBindings) ?? []
    }

    var frame: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }

    var usesMacGridGeometry: Bool {
        usesMacDefaultGrid || preservesMacGridGeometry
    }

    mutating func setFrame(_ newFrame: NSRect) {
        x = Double(newFrame.origin.x)
        y = Double(newFrame.origin.y)
        width = Double(newFrame.size.width)
        height = Double(newFrame.size.height)
    }

    /// The starting point for every region created with the add button.  These
    /// values intentionally match the user's approved “AI” region instead of
    /// the older bright-blue template.
    static func defaultNewRegion(frame: NSRect) -> Region {
        Region(
            name: "新区域",
            role: .custom,
            frame: frame,
            colorHex: "#000000",
            secondaryColorHex: "#000000",
            opacity: 0.12,
            gradientDirection: .solid,
            usesFrostedGlass: true,
            borderStyle: .none,
            borderColorHex: "#FFFFFF",
            usesMacDefaultGrid: false,
            headerHeight: 36,
            titleFontSize: 19,
            titleColorHex: "#FFFFFF",
            titleFontWeight: .semibold,
            headerStyle: .macNative,
            surfaceStyle: .macNative,
            gridColumns: 2,
            gridRows: 3,
            iconSpacing: 125
        )
    }

    /// Restores every control exposed by the per-region advanced editor while
    /// preserving the region's identity, name, placement, opacity, global-grid
    /// state, and bound Finder items.
    mutating func restoreDefaultAdvancedParameters() {
        let defaults = Region.defaultNewRegion(frame: frame)
        colorHex = defaults.colorHex
        secondaryColorHex = defaults.secondaryColorHex
        gradientDirection = defaults.gradientDirection
        usesFrostedGlass = defaults.usesFrostedGlass
        borderStyle = defaults.borderStyle
        borderColorHex = defaults.borderColorHex
        headerWidthFraction = defaults.headerWidthFraction
        headerHeight = defaults.headerHeight
        titleFontSize = defaults.titleFontSize
        titleColorHex = defaults.titleColorHex
        titleFontWeight = defaults.titleFontWeight
        headerStyle = defaults.headerStyle
        surfaceStyle = defaults.surfaceStyle
        gridColumns = defaults.gridColumns
        gridRows = defaults.gridRows
        iconSpacing = defaults.iconSpacing
        macGridBottomExtension = defaults.macGridBottomExtension
    }

    /// Creates a visually identical region with a fresh identity. Finder item
    /// bindings are content ownership, not appearance parameters, so a copy
    /// starts empty instead of letting two regions fight over the same files.
    func duplicated(name duplicateName: String, frame duplicateFrame: NSRect) -> Region {
        Region(
            name: duplicateName,
            role: role,
            frame: duplicateFrame,
            colorHex: colorHex,
            secondaryColorHex: secondaryColorHex,
            opacity: opacity,
            gradientDirection: gradientDirection,
            usesFrostedGlass: usesFrostedGlass,
            borderStyle: borderStyle,
            borderColorHex: borderColorHex,
            usesMacDefaultGrid: usesMacDefaultGrid,
            preservesMacGridGeometry: preservesMacGridGeometry,
            macGridBottomExtension: macGridBottomExtension,
            headerWidthFraction: headerWidthFraction,
            headerHeight: headerHeight,
            titleFontSize: titleFontSize,
            titleColorHex: titleColorHex,
            titleFontWeight: titleFontWeight,
            headerStyle: headerStyle,
            surfaceStyle: surfaceStyle,
            gridColumns: gridColumns,
            gridRows: gridRows,
            iconSpacing: iconSpacing,
            itemBindings: []
        )
    }

    mutating func applyHeaderStyle(_ style: RegionHeaderStyle) {
        headerStyle = style
        switch style {
        case .macNative, .ink, .graphite, .colorTint:
            titleColorHex = "#F7F7F8"
            titleFontWeight = style == .graphite ? .medium : .semibold
        case .porcelain, .paperLabel:
            titleColorHex = style == .paperLabel ? "#282A2D" : "#1B1C1F"
            titleFontWeight = .semibold
        }
    }

    mutating func applySurfaceStyle(_ style: RegionSurfaceStyle) {
        surfaceStyle = style
    }
}

final class RegionStore {
    private(set) var regions: [Region] = []
    private let fileURL: URL

    init(fileURL customFileURL: URL? = nil) {
        if let customFileURL {
            fileURL = customFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = appSupport.appendingPathComponent("DesktopRegions", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("regions.json")
        }
        load()
    }

    var isEmpty: Bool { regions.isEmpty }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([Region].self, from: data) else { return }
        regions = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(regions) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    func replace(with newRegions: [Region]) {
        regions = newRegions
        save()
    }

    func add(_ region: Region) {
        regions.append(region)
        save()
    }

    func update(_ updated: Region) {
        guard let index = regions.firstIndex(where: { $0.id == updated.id }) else { return }
        regions[index] = updated
        save()
    }

    func region(id: UUID) -> Region? {
        regions.first(where: { $0.id == id })
    }

    func mutate(id: UUID, _ mutation: (inout Region) -> Void) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        mutation(&regions[index])
        save()
    }

    func remove(id: UUID) {
        regions.removeAll { $0.id == id }
        save()
    }

    static func defaultRegions(in visibleFrame: NSRect) -> [Region] {
        let margin: CGFloat = 24
        let gap: CGFloat = 16
        let width = max(300, (visibleFrame.width - margin * 2 - gap) / 2)
        let height = max(220, (visibleFrame.height - margin * 2 - gap) / 2)
        let left = visibleFrame.minX + margin
        let right = left + width + gap
        let bottom = visibleFrame.minY + margin
        let top = bottom + height + gap

        return [
            Region(
                name: "正在处理",
                role: .work,
                frame: NSRect(x: left, y: top, width: width, height: height),
                colorHex: "#6D8AFF"
            ),
            Region(
                name: "待整理",
                role: .inbox,
                frame: NSRect(x: right, y: top, width: width, height: height),
                colorHex: "#FFB86B"
            ),
            Region(
                name: "图片与素材",
                role: .media,
                frame: NSRect(x: left, y: bottom, width: width, height: height),
                colorHex: "#62D8A7"
            ),
            Region(
                name: "参考资料",
                role: .reference,
                frame: NSRect(x: right, y: bottom, width: width, height: height),
                colorHex: "#B89CFF"
            )
        ]
    }
}

extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if cleaned.count == 3 {
            red = CGFloat((value >> 8) & 0xF) / 15
            green = CGFloat((value >> 4) & 0xF) / 15
            blue = CGFloat(value & 0xF) / 15
        } else {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
        }
        self.init(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    var hexString: String {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        let red = max(0, min(255, Int(round(rgb.redComponent * 255))))
        let green = max(0, min(255, Int(round(rgb.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(rgb.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
