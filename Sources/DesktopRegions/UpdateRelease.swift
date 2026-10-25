// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

struct UpdateVersion: Comparable, Equatable, CustomStringConvertible {
    private let numbers: [Int]
    private let prerelease: [String]
    let description: String

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let build = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components.allSatisfy({ Int($0) != nil }) else { return nil }
        var numbers = components.map { Int($0)! }
        while numbers.count > 1 && numbers.last == 0 { numbers.removeLast() }
        let identifiers = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard identifiers.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        self.numbers = numbers
        self.prerelease = identifiers
        self.description = text
    }
    var baseDescription: String { (numbers + Array(repeating: 0, count: max(0, 3 - numbers.count))).map(String.init).joined(separator: ".") }

    static func == (a: Self, b: Self) -> Bool { a.numbers == b.numbers && a.prerelease == b.prerelease }
    static func < (a: Self, b: Self) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for i in 0..<min(a.prerelease.count, b.prerelease.count) {
            let x = a.prerelease[i], y = b.prerelease[i]
            if x == y { continue }
            if let xn = Int(x), let yn = Int(y) { return xn < yn }
            if Int(x) != nil { return true }
            if Int(y) != nil { return false }
            return x < y
        }
        return a.prerelease.count < b.prerelease.count
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64
        let digest: String?
    }
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: UpdateVersion? { UpdateVersion(tag_name) }
}

struct AvailableUpdate {
    let release: GitHubRelease
    let asset: GitHubRelease.Asset?
    let checksumAsset: GitHubRelease.Asset?
    var version: UpdateVersion { release.version! }
    var canInstall: Bool { asset != nil && (UpdatePolicy.digest(from: asset?.digest) != nil || checksumAsset != nil) }
}

enum UpdatePolicy {
    static let repository = "Myf-ricey/Fange-macOS"
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    static let maximumPackageBytes: Int64 = 200 * 1024 * 1024

    static func error(_ description: String) -> NSError {
        NSError(domain: "DesktopRegions.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
    static func trustedReleaseURL(_ string: String, asset: Bool) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/\(repository)/releases/\(asset ? "download/" : "tag/")") else { return nil }
        return url
    }
    static func digest(from raw: String?) -> String? {
        guard let raw, raw.lowercased().hasPrefix("sha256:") else { return nil }
        let value = String(raw.dropFirst(7)).lowercased()
        guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
    static func latest(in releases: [GitHubRelease], architecture: String = nativeArchitecture) -> AvailableUpdate? {
        guard let release = releases.filter({ !$0.draft && $0.version != nil && trustedReleaseURL($0.html_url, asset: false) != nil })
            .max(by: { $0.version! < $1.version! }) else { return nil }
        let compatible = release.assets.filter { asset in
            let name = asset.name.lowercased()
            guard name.hasSuffix(".zip"), name.contains("fange") || name.contains("饭格"),
                  asset.size > 0, asset.size <= maximumPackageBytes,
                  let url = trustedReleaseURL(asset.browser_download_url, asset: true), url.lastPathComponent == asset.name else { return false }
            if architecture == "arm64" { return !name.contains("x86_64") && !name.contains("intel") || name.contains("universal") }
            return !name.contains("arm64") && !name.contains("apple-silicon") || name.contains("universal")
        }
        let asset = compatible.max { score($0, architecture: architecture) < score($1, architecture: architecture) }
        let checksum = release.assets.first {
            ["sha256sums.txt", "sha256sums", "checksums.txt"].contains($0.name.lowercased()) &&
                $0.size > 0 && $0.size < 1024 * 1024 && trustedReleaseURL($0.browser_download_url, asset: true) != nil
        }
        return AvailableUpdate(release: release, asset: asset, checksumAsset: checksum)
    }
    static var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private static func score(_ asset: GitHubRelease.Asset, architecture: String) -> Int {
        let name = asset.name.lowercased()
        return name.contains(architecture) ? 3 : (name.contains("universal") ? 2 : 1)
    }
    static func checksum(in text: String, filename: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let name = fields[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == filename, let hash = digest(from: "sha256:" + fields[0]) { return hash }
        }
        return nil
    }
    static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class GitHubUpdateService {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Fange-macOS-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdatePolicy.error("更新服务器没有返回有效响应。") }
        guard http.statusCode == 200 else {
            if [403, 429].contains(http.statusCode) { throw UpdatePolicy.error("GitHub 暂时限制了检查频率，请稍后再试。") }
            throw UpdatePolicy.error("检查更新失败（GitHub HTTP \(http.statusCode)），请稍后重试。")
        }
        guard let url = http.url, url.scheme == "https", let host = url.host?.lowercased(),
              host == "api.github.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com") else {
            throw UpdatePolicy.error("更新下载地址不是受信任的 GitHub 地址。")
        }
    }
    func latest() async throws -> AvailableUpdate {
        let (data, response) = try await session.data(for: request(UpdatePolicy.apiURL))
        try validate(response)
        guard data.count < 5 * 1024 * 1024 else { throw UpdatePolicy.error("更新信息过大，请前往 GitHub 查看。") }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let latest = UpdatePolicy.latest(in: releases) else { throw UpdatePolicy.error("GitHub 暂无可用的饭格发行版本。") }
        return latest
    }
    func download(_ update: AvailableUpdate, to workspace: URL) async throws -> URL {
        guard let asset = update.asset, let url = UpdatePolicy.trustedReleaseURL(asset.browser_download_url, asset: true) else {
            throw UpdatePolicy.error("该版本没有适合这台 Mac 的 ZIP 安装包，请在 GitHub 查看。")
        }
        var expected = UpdatePolicy.digest(from: asset.digest)
        if expected == nil, let checksum = update.checksumAsset,
           let checksumURL = UpdatePolicy.trustedReleaseURL(checksum.browser_download_url, asset: true) {
            let (data, response) = try await session.data(for: request(checksumURL))
            try validate(response)
            guard data.count < 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw UpdatePolicy.error("校验文件无效。") }
            expected = UpdatePolicy.checksum(in: text, filename: asset.name)
        }
        guard let expected else { throw UpdatePolicy.error("发布者尚未提供 SHA-256 校验信息，请前往 GitHub 手动安装。") }
        try Task.checkCancellation()
        let (temporary, response) = try await session.download(for: request(url))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validate(response)
        let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= UpdatePolicy.maximumPackageBytes, Int64(bytes) == asset.size else {
            throw UpdatePolicy.error("安装包大小不符或下载不完整，请重新检查更新。")
        }
        guard try UpdatePolicy.sha256(of: temporary) == expected else {
            throw UpdatePolicy.error("安装包校验失败，已停止安装。当前版本保持不变。")
        }
        try Task.checkCancellation()
        let archive = workspace.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        return archive
    }
}
