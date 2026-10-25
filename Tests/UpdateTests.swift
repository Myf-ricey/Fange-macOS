// Copyright 2026 Myf-ricey
// SPDX-License-Identifier: Apache-2.0

import Cocoa

private final class GitHubFixtureProtocol: URLProtocol {
    static var payload = Data()
    static var status = 200
    static var failure: Error?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let error = Self.failure { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct UpdateTests {
    static func main() async throws {
        func check(_ condition: Bool, _ message: String = "check failed") { precondition(condition, message) }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("expected rejection") } catch {}
        }
        let ordered = ["0.1.0-beta", "0.1.0-beta.2", "0.1.0-beta.10", "0.1.0", "0.2.0", "0.2.1", "1.0.0-rc.1", "1.0.0"]
        for pair in zip(ordered, ordered.dropFirst()) { check(UpdateVersion(pair.0)! < UpdateVersion(pair.1)!) }
        check(UpdateVersion("v1.2.0+build.9") == UpdateVersion("1.2"))
        check(UpdateVersion("not-a-version") == nil && UpdateVersion("1..2") == nil && UpdateVersion("1.2.0-") == nil)
        check(UpdateVersion("0.3.0-beta.2")!.baseDescription == "0.3.0")
        check(UpdatePolicy.trustedReleaseURL("https://github.com/Myf-ricey/Fange-macOS/releases/tag/v1.0.0", asset: false) != nil)
        check(UpdatePolicy.trustedReleaseURL("http://github.com/Myf-ricey/Fange-macOS/releases/tag/v1.0.0", asset: false) == nil)
        check(UpdatePolicy.trustedReleaseURL("https://github.com.evil.test/Myf-ricey/Fange-macOS/releases/tag/v1.0.0", asset: false) == nil)
        check(UpdatePolicy.trustedReleaseURL("https://github.com/other/repo/releases/tag/v1.0.0", asset: false) == nil)
        let digest = String(repeating: "a", count: 64)
        check(UpdatePolicy.digest(from: "sha256:" + digest) == digest)
        check(UpdatePolicy.digest(from: "sha256:bad") == nil)
        check(UpdatePolicy.checksum(in: "\(digest)  Fange.zip\n", filename: "Fange.zip") == digest)
        check(UpdatePolicy.checksum(in: "\(digest) *Fange.zip\n", filename: "Other.zip") == nil)
        print("semantic versions, beta order, downgrade prevention, source URLs, checksum parsing: PASS")

        func release(_ version: String, draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
            ["tag_name": version, "name": version, "body": "更新内容", "html_url": "https://github.com/Myf-ricey/Fange-macOS/releases/tag/\(version)",
             "draft": draft, "prerelease": prerelease, "assets": [
                ["name": "Fange-\(version)-macOS-universal.zip", "browser_download_url": "https://github.com/Myf-ricey/Fange-macOS/releases/download/\(version)/Fange-\(version)-macOS-universal.zip", "size": 1024, "digest": "sha256:" + digest],
                ["name": "Fange-\(version)-macOS-arm64.zip", "browser_download_url": "https://github.com/Myf-ricey/Fange-macOS/releases/download/\(version)/Fange-\(version)-macOS-arm64.zip", "size": 1024, "digest": "sha256:" + digest]
             ]]
        }
        let fixture = try JSONSerialization.data(withJSONObject: [release("v0.2.0"), release("v0.3.0-beta.2", prerelease: true), release("v9.0.0", draft: true)])
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: fixture)
        let arm = UpdatePolicy.latest(in: releases, architecture: "arm64")!
        let intel = UpdatePolicy.latest(in: releases, architecture: "x86_64")!
        check(arm.release.tag_name == "v0.3.0-beta.2" && arm.asset!.name.contains("arm64"))
        check(intel.asset!.name.contains("universal"))
        check(arm.canInstall)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubFixtureProtocol.self]
        let service = GitHubUpdateService(session: URLSession(configuration: config))
        GitHubFixtureProtocol.payload = fixture
        let fetched = try await service.latest()
        check(fetched.release.tag_name == arm.release.tag_name)
        GitHubFixtureProtocol.status = 403
        do { _ = try await service.latest(); preconditionFailure("rate limit must fail") }
        catch { check(error.localizedDescription.contains("频率")) }
        GitHubFixtureProtocol.status = 200
        GitHubFixtureProtocol.failure = URLError(.notConnectedToInternet)
        do { _ = try await service.latest(); preconditionFailure("offline must fail") } catch {}
        GitHubFixtureProtocol.failure = nil
        print("GitHub release selection, architecture matching, HTTP/rate-limit/offline handling: PASS")

        let fm = FileManager.default
        let kekaScratch = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.aone.keka/Data/tmp", isDirectory: true)
        let root = kekaScratch.appendingPathComponent("fange-update-tests-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("stub.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let stub = root.appendingPathComponent("stub")
        try UpdateInstaller.run("/usr/bin/clang", ["-arch", UpdatePolicy.nativeArchitecture, source.path, "-o", stub.path])
        func makeApp(_ parent: URL, version: String, id: String = UpdateInstaller.bundleIdentifier) throws -> URL {
            let app = parent.appendingPathComponent("饭格.app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Fange", "CFBundleName": "饭格", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1", "LSMinimumSystemVersion": "13.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            try fm.copyItem(at: stub, to: contents.appendingPathComponent("MacOS/Fange"))
            try Data(version.utf8).write(to: contents.appendingPathComponent("Resources/version-marker.txt"))
            try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
            return app
        }
        let installed = try makeApp(root.appendingPathComponent("installed"), version: "0.2.0")
        let candidate = try makeApp(root.appendingPathComponent("candidate"), version: "0.3.0")
        let archive = root.appendingPathComponent("candidate.zip")
        let keka = "/Applications/Keka.app/Contents/MacOS/Keka"
        guard fm.isExecutableFile(atPath: keka) else { throw UpdatePolicy.error("测试安装包需要已安装的 Keka。") }
        try UpdateInstaller.run(keka, ["--ignore-file-access", "--cli", "7z", "a", "-tzip", "-mx=1", archive.path, candidate.path])
        try UpdateInstaller.run(keka, ["--ignore-file-access", "--cli", "7z", "t", archive.path])
        try UpdateInstaller.validateArchive(archive)
        check(try UpdatePolicy.sha256(of: archive).count == 64)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let request = try UpdateInstaller.prepare(archive: archive, workspace: workspace, target: installed, releaseTag: "v0.3.0")
        let marker = installed.appendingPathComponent("Contents/Resources/version-marker.txt")
        rejects { try UpdateInstaller.replace(request) { throw UpdatePolicy.error("simulated launch failure") } }
        check(try String(contentsOf: marker, encoding: .utf8) == "0.2.0", "启动失败必须恢复完整旧版本")
        check(fm.fileExists(atPath: request.stagedPath))
        var launched = false
        try UpdateInstaller.replace(request) { launched = true }
        check(try launched && String(contentsOf: marker, encoding: .utf8) == "0.3.0")
        check(try String(contentsOf: URL(fileURLWithPath: request.backupPath).appendingPathComponent("Contents/Resources/version-marker.txt"), encoding: .utf8) == "0.2.0")
        print("Keka ZIP integrity, SHA-256, signature/architecture verification, staged installation, atomic replacement and rollback: PASS")

        rejects { try UpdateInstaller.verifyApplication(installed, releaseTag: "v99.0.0", requiredTeam: nil) }
        rejects { try UpdateInstaller.verifyApplication(installed, releaseTag: "v0.3.0", requiredTeam: "OTHERTEAM") }
        let impostor = try makeApp(root.appendingPathComponent("impostor"), version: "0.3.0", id: "invalid.impostor")
        rejects { try UpdateInstaller.verifyApplication(impostor, releaseTag: "v0.3.0", requiredTeam: nil) }
        // Mutate a Keka-generated fixture's filenames to test traversal; no
        // alternate archive creator is used for these negative test payloads.
        var unsafe = try Data(contentsOf: archive)
        let originalName = Data("Contents/Info.plist".utf8)
        let traversalName = Data("../xxxxx/Info.plist".utf8)
        check(originalName.count == traversalName.count)
        while let range = unsafe.range(of: originalName) { unsafe.replaceSubrange(range, with: traversalName) }
        let malicious = root.appendingPathComponent("unsafe.zip")
        try unsafe.write(to: malicious)
        rejects { try UpdateInstaller.validateArchive(malicious) }
        let truncated = root.appendingPathComponent("truncated.zip")
        try Data(unsafe.prefix(20)).write(to: truncated)
        rejects { try UpdateInstaller.validateArchive(truncated) }
        let executable = installed.appendingPathComponent("Contents/MacOS/Fange")
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("tampered".utf8)); try handle.close()
        rejects { try UpdateInstaller.verifyApplication(installed, releaseTag: "v0.3.0", requiredTeam: nil) }
        print("wrong version/team/bundle, tampered signature, ZIP traversal and truncated download rejection: PASS")

        if ProcessInfo.processInfo.environment["FANGE_LIVE_UPDATE_CHECK"] == "1" {
            let live = try await GitHubUpdateService().latest()
            check(UpdatePolicy.trustedReleaseURL(live.release.html_url, asset: false) != nil)
            print("live GitHub check: PASS (\(live.release.tag_name), installable: \(live.canInstall))")
            if ProcessInfo.processInfo.environment["FANGE_LIVE_UPDATE_DOWNLOAD"] == "1" {
                let liveWorkspace = root.appendingPathComponent("live-download", isDirectory: true)
                try fm.createDirectory(at: liveWorkspace, withIntermediateDirectories: true)
                let downloaded = try await GitHubUpdateService().download(live, to: liveWorkspace)
                try UpdateInstaller.validateArchive(downloaded)
                let expanded = liveWorkspace.appendingPathComponent("expanded", isDirectory: true)
                try fm.createDirectory(at: expanded, withIntermediateDirectories: true)
                try UpdateInstaller.run("/usr/bin/ditto", ["-x", "-k", downloaded.path, expanded.path])
                let files = fm.enumerator(at: expanded, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])!
                let app = (files.allObjects as! [URL]).first { $0.pathExtension == "app" }!
                try UpdateInstaller.verifyApplication(app, releaseTag: live.release.tag_name, requiredTeam: nil)
                print("real GitHub asset download, digest, archive and application verification (no installation): PASS")
            }
        }
    }
}
