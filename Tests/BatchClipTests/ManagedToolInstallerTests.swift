import Foundation
import Testing
@testable import BatchClip

private struct FixtureFetcher: ToolFetching {
    let source: URL
    var fails = false
    var waitsForCancellation = false
    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if waitsForCancellation { try await Task.sleep(for: .seconds(30)) }
        if fails { throw URLError(.notConnectedToInternet) }
        try FileManager.default.copyItem(at: source, to: destination)
        progress(1)
    }
}

struct ManagedToolInstallerTests {
    private func fixture() throws -> (ToolEnvironment, URL, ToolDownload) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchClip-setup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nprintf '2026.10.26\\n'\n".utf8).write(to: source)
        let download = ToolDownload(kind: .ytDLP, version: "2026.10.26", url: URL(string: "https://example.invalid/fixture")!, sha256: try ManagedToolInstaller.sha256(source), isZip: false)
        return (ToolEnvironment(root: root.appendingPathComponent("tools"), searchDirectories: [], environmentPath: ""), source, download)
    }

    @Test func installsAndResolvesWithoutRestart() async throws {
        let (environment, source, download) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try await ManagedToolInstaller(fetcher: FixtureFetcher(source: source)).install([download], environment: environment) { _ in }
        let path = try #require(environment.managedPath(for: .ytDLP))
        #expect(environment.resolve().ytDLP == path)
        #expect(try await ToolValidator.validate(.ytDLP, at: URL(fileURLWithPath: path)) == "2026.10.26")
        #expect(try FileManager.default.contentsOfDirectory(atPath: environment.root.path).allSatisfy { !$0.hasPrefix(".staging") })
    }

    @Test func folderPackageKeepsItsRuntimeBesideExecutable() async throws {
        let (environment, source, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let payload = source.deletingLastPathComponent().appendingPathComponent("payload")
        let support = payload.appendingPathComponent("_internal")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "2026.10.26\n".write(to: support.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        let binary = payload.appendingPathComponent("yt-dlp_macos")
        try #"""
        #!/bin/sh
        exec /bin/cat "$(/usr/bin/dirname "$0")/_internal/version"
        """#.write(to: binary, atomically: true, encoding: .utf8)
        let zip = source.deletingLastPathComponent().appendingPathComponent("payload.zip")
        _ = try await DownloadRunner().run(executablePath: "/usr/bin/ditto", arguments: ["-c", "-k", payload.path, zip.path])
        var download = original
        download.isZip = true
        download.sha256 = try ManagedToolInstaller.sha256(zip)
        download.executableName = "yt-dlp_macos"
        download.supportDirectory = "_internal"
        try await ManagedToolInstaller(fetcher: FixtureFetcher(source: zip)).install([download], environment: environment) { _ in }
        let executable = URL(fileURLWithPath: try #require(environment.managedPath(for: .ytDLP)))
        #expect(try await ToolValidator.validate(.ytDLP, at: executable) == "2026.10.26")
    }

    @Test func malformedVersionIsReportedInsteadOfCrashing() async throws {
        let (_, source, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try "#!/bin/sh\nprintf 'ffprobe version \n'\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        await #expect(throws: (any Error).self) { _ = try await ToolValidator.validate(.ffprobe, at: source) }
    }

    @Test func versionCheckTimeoutTerminatesHungExecutable() async throws {
        let (_, source, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await ToolValidator.validate(.ytDLP, at: source, timeout: .milliseconds(50))
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func checksumFailurePreservesExistingInstallation() async throws {
        let (environment, source, download) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let installer = ManagedToolInstaller(fetcher: FixtureFetcher(source: source))
        try await installer.install([download], environment: environment) { _ in }
        let before = try Data(contentsOf: environment.receiptURL)
        var bad = download
        bad.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: (any Error).self) {
            try await installer.install([bad], environment: environment) { _ in }
        }
        #expect(try Data(contentsOf: environment.receiptURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: environment.root.appendingPathComponent("versions").path).count == 1)
    }

    @Test func validationFailureNeverActivatesPartiallyInstalledTools() async throws {
        let (environment, source, download) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var second = download
        second.kind = .deno
        let installer = ManagedToolInstaller(fetcher: FixtureFetcher(source: source), validate: { kind, _ in
            if kind == .deno { throw ToolSetupError.message("Invalid executable") }
            return "valid"
        })
        await #expect(throws: (any Error).self) {
            try await installer.install([download, second], environment: environment) { _ in }
        }
        #expect(environment.receipt().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: environment.root.appendingPathComponent("versions").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: environment.root.path).allSatisfy { !$0.hasPrefix(".staging") })
    }

    @Test func offlineFailureAndCancellationLeaveNoPartialInstallation() async throws {
        for cancel in [false, true] {
            let (environment, source, download) = try fixture()
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let installer = ManagedToolInstaller(fetcher: FixtureFetcher(source: source, fails: !cancel, waitsForCancellation: cancel))
            let task = Task { try await installer.install([download], environment: environment) { _ in } }
            if cancel {
                try await Task.sleep(for: .milliseconds(50))
                task.cancel()
            }
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(environment.receipt().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: environment.root.path).allSatisfy { !$0.hasPrefix(".staging") })
        }
    }

    @Test func rejectsTraversalAndMalformedReceipts() throws {
        let (environment, source, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: environment.root, withIntermediateDirectories: true)
        for path in ["/usr/bin/true", "versions/../../yt-dlp", "versions/not-a-uuid/yt-dlp", "versions/\(UUID())/deno"] {
            try JSONEncoder().encode(["yt-dlp": path]).write(to: environment.receiptURL)
            #expect(environment.managedPath(for: .ytDLP) == nil)
        }
        #expect(throws: (any Error).self) { try ManagedToolInstaller.validateArchiveListing("../escape\nyt-dlp\n") }
        #expect(throws: (any Error).self) { try ManagedToolInstaller.validateArchiveListing("/tmp/escape\n") }
        try ManagedToolInstaller.validateArchiveListing("ffmpeg\nLICENSE\n")
    }

    @Test func catalogUsesPinnedHTTPSAndInstallsFFmpegPairForBothArchitectures() {
        for arch in [ToolArchitecture.arm64, .intel] {
            let pair = ToolDownloadCatalog.downloads(for: [.ffprobe], architecture: arch)
            #expect(Set(pair.map(\.kind)) == [.ffmpeg, .ffprobe])
            let all = ToolDownloadCatalog.downloads(for: Set(ToolKind.allCases), architecture: arch)
            #expect(all.count == 4)
            #expect(all.allSatisfy { $0.url.scheme == "https" && !$0.url.path.contains("latest") && $0.sha256.count == 64 })
        }
    }

    @Test @MainActor func checkAgainRecognizesNewExternalTools() async throws {
        let (environment, source, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let external = source.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        var configured = environment
        configured.searchDirectories = [external.path]
        let manager = ToolManager(environment: configured)
        #expect(manager.missing.contains(.ytDLP))
        let executable = external.appendingPathComponent("yt-dlp")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        await manager.refresh()
        #expect(!manager.missing.contains(.ytDLP))
        #expect(manager.paths.ytDLP == executable.path)
    }

    @Test @MainActor func brokenExecutablesAreRepairable() async throws {
        let (environment, source, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let external = source.deletingLastPathComponent()
        let executable = external.appendingPathComponent("deno")
        try "#!/bin/sh\necho 'deno 1.0.0'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var configured = environment
        configured.searchDirectories = [external.path]
        let manager = ToolManager(environment: configured)
        await manager.refresh()
        #expect(manager.missing.contains(.deno))
        #expect(manager.availability.first { $0.kind == .deno }?.detail.contains("2.3") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BATCHCLIP_TEST_MANAGED_INSTALL"] != nil))
    @MainActor func realManagedInstallation() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BATCHCLIP_TEST_MANAGED_INSTALL"]))
        let environment = ToolEnvironment(root: root, searchDirectories: [], environmentPath: "")
        let manager = ToolManager(environment: environment)
        try #require(manager.missing.count == 4, "Use an empty directory for the real first-run test.")
        try await ManagedToolInstaller().install(ToolDownloadCatalog.downloads(for: manager.missing), environment: environment) { update in
            if !update.message.contains("%") { print(update.message) }
        }
        await manager.refresh()
        #expect(!manager.needsSetup, "\(manager.availability.map { $0.detail })")
        #expect(manager.availability.allSatisfy { $0.path?.hasPrefix(root.path) == true })
        print("Managed tools installed and validated at \(root.path)")
    }
}
