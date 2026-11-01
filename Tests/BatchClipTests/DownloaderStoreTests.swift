import Foundation

import Testing
@testable import BatchClip

@MainActor
struct DownloaderStoreTests {
    @Test func missingDenoRequiresSetupOnlyForYouTube() {
        let tools = ToolPaths(ytDLP: "/usr/bin/true", ffmpeg: "/usr/bin/true", ffprobe: "/usr/bin/true")
        let store = DownloaderStore(preferences: nil, tools: tools, notificationsEnabled: false)
        store.items = [DownloadItem(url: "https://example.com/video", kind: .video)]
        #expect(store.canStart)
        store.items = [DownloadItem(url: "https://www.youtube.com/watch?v=video", kind: .video)]
        #expect(!store.canStart && store.needsYouTubeSetup)
        store.startBatch()
        #expect(store.showingToolSetup && !store.isRunning)
        store.items = [DownloadItem(url: "https://youtube.com.example.com/video", kind: .video)]
        #expect(store.canStart)
    }

    @Test func addLinksIsIgnoredWhileBatchIsRunning() {
        let store = DownloaderStore(preferences: nil, notificationsEnabled: false)
        store.isRunning = true
        store.pendingText = "https://example.com/video\n"

        store.addLinks(kind: .video)

        #expect(store.items.isEmpty)
        #expect(store.pendingText == "https://example.com/video\n")
    }

    @Test func retryFailedItemsClearsStaleProgressState() {
        let store = DownloaderStore(preferences: nil, notificationsEnabled: false)
        store.items = [
            DownloadItem(
                url: "https://example.com/video",
                kind: .video,
                status: .failed("Failed"),
                log: "old log",
                progressPercent: 42,
                progressText: "42%",
                activityText: "Old failure"
            )
        ]

        store.retryFailedItems(startImmediately: false)

        #expect(store.items[0].status == .queued)
        #expect(store.items[0].log.isEmpty)
        #expect(store.items[0].progressPercent == nil)
        #expect(store.items[0].progressText.isEmpty)
        #expect(store.items[0].activityText.isEmpty)
    }
}

@MainActor
struct QueueBehaviorTests {
    @Test func deduplicatesWithinPasteButAllowsDifferentOutputs() {
        let store = DownloaderStore(preferences: nil, notificationsEnabled: false)
        store.pendingText = "https://example.com/one\nhttps://example.com/one\ninvalid\nfile:///etc/passwd"
        store.addLinks(kind: .video)
        #expect(store.items.count == 1)
        #expect(store.pendingText == "invalid\nfile:///etc/passwd")
        store.pendingText = "https://example.com/one"
        store.addLinks(kind: .audio)
        store.pendingText = "https://example.com/one"
        store.addLinks(kind: .video, outputMode: .original)
        #expect(store.items.count == 3)
    }

    @Test func largeBatchesKeepExplicitPacingChoice() {
        let store = DownloaderStore(preferences: nil, notificationsEnabled: false)
        #expect(store.pacing == .cautious)
        store.pacing = .standard
        store.pendingText = (1...12).map { "https://example.com/\($0)" }.joined(separator: "\n")
        store.addLinks(kind: .video)
        #expect(store.pacing == .standard)
        #expect(store.rateLimitWarning != nil)
    }

    @Test func stoppingLocksQueueUntilProcessCleanup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("fake-ytdlp")
        try "#!/bin/sh\necho ready\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let tools = ToolPaths(ytDLP: script.path, ffmpeg: "/usr/bin/true", ffprobe: "/usr/bin/true")
        let store = DownloaderStore(preferences: nil, tools: tools, notificationsEnabled: false)
        store.items = [DownloadItem(url: "https://example.com/one", kind: .video), DownloadItem(url: "https://example.com/two", kind: .video)]
        store.startBatch()
        for _ in 0..<200 {
            if store.items[0].log.contains("ready") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(store.items[0].log.contains("ready"))
        store.cancelBatch()
        #expect(store.isRunning && store.isStopping && !store.canStart)
        store.removeItem(id: store.items[0].id)
        store.clearFinished()
        store.startBatch()
        #expect(store.items.count == 2)
        for _ in 0..<300 {
            if !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isRunning && !store.isStopping)
        #expect(store.items[0].status == .failed("Cancelled"))
        #expect(store.items[1].status == .queued)
        #expect(store.globalMessage == "Batch cancelled")
    }

    @Test func persistsDestinationAndPacing() throws {
        let name = "BatchClip.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DownloaderStore(preferences: defaults, notificationsEnabled: false)
        store.selectedFolder = URL(fileURLWithPath: "/tmp/batchclip-test")
        store.pacing = .standard
        let restored = DownloaderStore(preferences: defaults, notificationsEnabled: false)
        #expect(restored.selectedFolder == store.selectedFolder)
        #expect(restored.pacing == .standard)
    }
}
