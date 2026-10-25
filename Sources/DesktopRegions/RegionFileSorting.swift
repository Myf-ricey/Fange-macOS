// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

enum RegionFileSorting {
    static let resourceKeys: Set<URLResourceKey> = [.localizedNameKey, .isDirectoryKey, .isPackageKey,
        .contentModificationDateKey, .creationDateKey, .fileSizeKey, .localizedTypeDescriptionKey]

    static func sorted(_ urls: [URL], by options: RegionFileSort) -> [URL] {
        let entries = urls.map { original -> (url: URL, name: String, folder: Bool, date: Date, size: Int, kind: String) in
            var url = original
            url.removeAllCachedResourceValues()
            let values = try? url.resourceValues(forKeys: resourceKeys)
            return (original, values?.localizedName ?? original.lastPathComponent,
                values?.isDirectory == true && values?.isPackage != true,
                (options.key == .created ? values?.creationDate : values?.contentModificationDate) ?? .distantPast,
                values?.isDirectory == true ? 0 : (values?.fileSize ?? 0),
                values?.localizedTypeDescription ?? original.pathExtension)
        }
        return entries.sorted { a, b in
            if options.foldersFirst && a.folder != b.folder { return a.folder }
            let comparison: ComparisonResult
            switch options.key {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .kind: comparison = a.kind.localizedStandardCompare(b.kind)
            case .modified, .created: comparison = a.date.compare(b.date)
            case .size: comparison = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            }
            if comparison != .orderedSame { return comparison == (options.ascending ? .orderedAscending : .orderedDescending) }
            let names = a.name.localizedStandardCompare(b.name)
            return names == .orderedSame ? a.url.path < b.url.path : names == .orderedAscending
        }.map(\.url)
    }
}

/// Items retain their callbacks without an external target-lifetime registry.
private final class SortMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, selected: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        state = selected ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

enum RegionSortMenu {
    static func make(options: RegionFileSort, onChange: @escaping (RegionFileSort) -> Void) -> NSMenu {
        let menu = NSMenu(title: "排序方式")
        for key in RegionFileSortKey.allCases {
            menu.addItem(SortMenuItem(title: key.displayName, selected: options.key == key) {
                var updated = options; updated.key = key; onChange(updated)
            })
        }
        menu.addItem(.separator())
        for ascending in [true, false] {
            menu.addItem(SortMenuItem(title: ascending ? "升序" : "降序", selected: options.ascending == ascending) {
                var updated = options; updated.ascending = ascending; onChange(updated)
            })
        }
        menu.addItem(.separator())
        menu.addItem(SortMenuItem(title: "文件夹优先", selected: options.foldersFirst) {
            var updated = options; updated.foldersFirst.toggle(); onChange(updated)
        })
        return menu
    }
}

/// Visible controls used by the per-region settings, alongside the context menu.
final class RegionSortControls: NSObject {
    let keyPopup = NSPopUpButton()
    let orderPopup = NSPopUpButton()
    let foldersFirst = NSButton(checkboxWithTitle: "文件夹优先", target: nil, action: nil)
    var onChange: ((RegionFileSort) -> Void)?

    override init() {
        super.init()
        keyPopup.addItems(withTitles: RegionFileSortKey.allCases.map(\.displayName))
        orderPopup.addItems(withTitles: ["升序", "降序"])
        keyPopup.setAccessibilityLabel("排序依据")
        orderPopup.setAccessibilityLabel("排序顺序")
        keyPopup.target = self; keyPopup.action = #selector(changed)
        orderPopup.target = self; orderPopup.action = #selector(changed)
        foldersFirst.target = self; foldersFirst.action = #selector(changed)
        update(RegionFileSort())
    }

    func update(_ options: RegionFileSort) {
        keyPopup.selectItem(at: RegionFileSortKey.allCases.firstIndex(of: options.key) ?? 0)
        orderPopup.selectItem(at: options.ascending ? 0 : 1)
        foldersFirst.state = options.foldersFirst ? .on : .off
    }

    @objc private func changed() {
        onChange?(RegionFileSort(key: RegionFileSortKey.allCases[max(0, keyPopup.indexOfSelectedItem)],
            ascending: orderPopup.indexOfSelectedItem == 0, foldersFirst: foldersFirst.state == .on))
    }
}
