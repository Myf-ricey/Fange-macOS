// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

@MainActor
final class AppUpdateManager: NSObject {
    private let service: GitHubUpdateService
    private let beforeInstall: () throws -> Void
    private var task: Task<Void, Never>?
    private var dialog: UpdateDialogController?
    private var manualRequested = false
    private var available: AvailableUpdate?
    private var installing = false
    private var operationID: UUID?

    init(service: GitHubUpdateService = GitHubUpdateService(), beforeInstall: @escaping () throws -> Void) {
        self.service = service
        self.beforeInstall = beforeInstall
        super.init()
    }

    func didLaunch() {
        let arguments = CommandLine.arguments
        for flag in ["--complete-update", "--update-result"] {
            if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
                let manifest = arguments[index + 1]
                if flag == "--complete-update" { UpdateInstaller.acknowledgeLaunch(manifestPath: manifest) }
                task = Task { @MainActor [weak self] in
                    let resultURL = URL(fileURLWithPath: manifest).deletingLastPathComponent().appendingPathComponent("result.json")
                    for _ in 0..<300 {
                        guard !Task.isCancelled else { return }
                        if let data = try? Data(contentsOf: resultURL), let result = try? JSONDecoder().decode(UpdateInstallationResult.self, from: data) {
                            self?.showDialog()
                            self?.dialog?.present(title: result.success ? "更新完成" : "更新未完成", detail: result.message, primary: "关闭", action: { [weak self] in self?.dialog?.close() })
                            self?.task = nil
                            return
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    self?.task = nil
                }
                return
            }
        }
        // One check for each process launch; reopening Settings does not check.
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self else { return }
            self.task = nil
            self.check(manual: false)
        }
    }

    func check(manual: Bool) {
        if manual { manualRequested = true; showDialog() }
        guard task == nil else { return }
        if manual { dialog?.progress(title: "正在检查更新", detail: "正在连接 GitHub Releases…", cancellable: true) }
        let id = UUID()
        operationID = id
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.operationID == id { self.task = nil; self.operationID = nil } }
            do {
                let update = try await self.service.latest()
                try Task.checkCancellation()
                self.available = update
                let currentText = UpdateInstaller.currentVersion
                guard let current = UpdateVersion(currentText) else { throw UpdatePolicy.error("无法识别当前应用版本。") }
                if update.version > current {
                    self.showDialog()
                    let beta = update.release.prerelease ? "（Beta）" : ""
                    let notes = update.release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.dialog?.present(title: "发现新版本 \(update.release.tag_name)\(beta)",
                        detail: "当前版本：\(currentText)\n\n更新内容\n\(notes.isEmpty ? "作者尚未填写更新说明。" : notes)",
                        primary: update.canInstall ? "一键更新并重启" : "前往 GitHub 下载",
                        secondary: "稍后", action: { [weak self] in
                            guard let self else { return }
                            if update.canInstall { self.install(update) } else { self.openGitHub(update) }
                        })
                } else if self.manualRequested {
                    self.dialog?.present(title: "暂无可用更新", detail: "当前版本：\(currentText)\nGitHub 最新发布：\(update.release.tag_name)\n\n当前版本不低于 GitHub 发布版本。",
                        primary: "关闭", action: { [weak self] in self?.dialog?.close() })
                }
            } catch is CancellationError {
                self.manualRequested = false
            } catch {
                guard !Task.isCancelled else { return }
                if self.manualRequested {
                    self.dialog?.present(title: "检查更新失败", detail: "\(error.localizedDescription)\n\n当前版本：\(UpdateInstaller.currentVersion)\n更新来源：GitHub · \(UpdatePolicy.repository)",
                        primary: "重试", secondary: "关闭", action: { [weak self] in
                            // Dispatch after the current task's defer clears it.
                            DispatchQueue.main.async { self?.check(manual: true) }
                        })
                }
            }
        }
    }

    func cancel() {
        guard !installing else { return }
        task?.cancel(); task = nil; operationID = nil; manualRequested = false
    }

    private func showDialog() {
        if dialog == nil {
            dialog = UpdateDialogController()
            dialog?.onCancel = { [weak self] in self?.cancel() }
            dialog?.onDetails = { [weak self] in self?.openGitHub(self?.available) }
        }
        dialog?.show()
    }
    private func openGitHub(_ update: AvailableUpdate?) {
        let url = update.flatMap { UpdatePolicy.trustedReleaseURL($0.release.html_url, asset: false) } ?? UpdatePolicy.releasesURL
        NSWorkspace.shared.open(url)
    }

    private func install(_ update: AvailableUpdate) {
        guard task == nil, !installing else { return }
        dialog?.progress(title: "正在下载并验证更新", detail: "\(update.release.tag_name)\n正在从作者的 GitHub Release 下载。下载与验证完成前，当前应用可继续使用。", cancellable: true)
        let id = UUID()
        operationID = id
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var workspace: URL?
            var prepared: UpdateInstallRequest?
            var handedOff = false
            defer {
                if !handedOff {
                    if let prepared { try? FileManager.default.removeItem(atPath: prepared.stagedPath) }
                    if let workspace { try? FileManager.default.removeItem(at: workspace) }
                }
                if self.operationID == id { self.task = nil; self.operationID = nil }
            }
            do {
                let directory = try UpdateInstaller.makeWorkspace()
                workspace = directory
                let archive = try await self.service.download(update, to: directory)
                try Task.checkCancellation()
                self.dialog?.progress(title: "正在准备安装", detail: "正在检查应用版本、签名与当前安装位置…", cancellable: true)
                let target = Bundle.main.bundleURL
                let request = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.prepare(archive: archive, workspace: directory, target: target, releaseTag: update.release.tag_name)
                }.value
                prepared = request
                try Task.checkCancellation()
                try self.beforeInstall()
                self.installing = true
                self.dialog?.progress(title: "正在更新饭格", detail: "即将退出并覆盖安装，完成后自动重新打开。", cancellable: false)
                try UpdateInstaller.startHelper(request)
                handedOff = true
                NSApp.terminate(nil)
            } catch is CancellationError {
                self.installing = false
            } catch {
                self.installing = false
                guard !Task.isCancelled else { return }
                self.dialog?.present(title: "更新未完成", detail: "\(error.localizedDescription)\n\n旧版本与分区设置保持不变。",
                    primary: "重试", secondary: "关闭", action: { [weak self] in
                        DispatchQueue.main.async { self?.install(update) }
                    })
            }
        }
    }
}

@MainActor
private final class UpdateDialogController: NSWindowController, NSWindowDelegate {
    private let heading = NSTextField(labelWithString: "饭格更新")
    private let detail = NSTextView()
    private let spinner = NSProgressIndicator()
    private let primary = NSButton()
    private let secondary = NSButton(title: "关闭", target: nil, action: nil)
    private let details = NSButton(title: "GitHub 发布页", target: nil, action: nil)
    private var primaryAction: (() -> Void)?
    private var cancellable = true
    var onCancel: (() -> Void)?
    var onDetails: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 410),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "饭格 · 检查更新"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init(window: window)
        window.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 410))
        heading.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        heading.frame = NSRect(x: 26, y: 350, width: 488, height: 34)
        let scroll = NSScrollView(frame: NSRect(x: 26, y: 92, width: 488, height: 244))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = false
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .labelColor
        detail.textContainerInset = NSSize(width: 4, height: 6)
        detail.autoresizingMask = [.width]
        detail.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.textContainer?.widthTracksTextView = true
        detail.frame = scroll.contentView.bounds
        scroll.documentView = detail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 26, y: 48, width: 20, height: 20)
        primary.frame = NSRect(x: 330, y: 30, width: 184, height: 34)
        primary.bezelStyle = .rounded
        primary.target = self; primary.action = #selector(primaryPressed)
        primary.keyEquivalent = "\r"
        secondary.frame = NSRect(x: 234, y: 30, width: 86, height: 34)
        secondary.bezelStyle = .rounded
        secondary.target = self; secondary.action = #selector(closePressed)
        details.frame = NSRect(x: 48, y: 31, width: 152, height: 32)
        details.bezelStyle = .inline
        details.target = self; details.action = #selector(detailsPressed)
        [heading, scroll, spinner, primary, secondary, details].forEach(root.addSubview)
        window.contentView = root
        progress(title: "正在检查更新", detail: "正在连接 GitHub Releases…", cancellable: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    func present(title: String, detail text: String, primary titleText: String, secondary secondaryText: String? = nil, action: @escaping () -> Void) {
        cancellable = true
        window?.standardWindowButton(.closeButton)?.isEnabled = true
        heading.stringValue = title
        detail.string = text
        detail.scrollToBeginningOfDocument(nil)
        spinner.stopAnimation(nil); spinner.isHidden = true
        primary.title = titleText; primary.isHidden = false; primary.isEnabled = true
        secondary.title = secondaryText ?? "关闭"; secondary.isHidden = secondaryText == nil; secondary.isEnabled = true
        primaryAction = action
    }
    func progress(title: String, detail text: String, cancellable: Bool) {
        self.cancellable = cancellable
        heading.stringValue = title; detail.string = text
        spinner.isHidden = false; spinner.startAnimation(nil)
        primary.isHidden = true
        secondary.isHidden = false; secondary.title = "取消"; secondary.isEnabled = cancellable
        window?.standardWindowButton(.closeButton)?.isEnabled = cancellable
        primaryAction = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancellable }
    func windowWillClose(_ notification: Notification) { onCancel?() }
    @objc private func primaryPressed() { primaryAction?() }
    @objc private func closePressed() { guard cancellable else { return }; close() }
    @objc private func detailsPressed() { onDetails?() }
}
