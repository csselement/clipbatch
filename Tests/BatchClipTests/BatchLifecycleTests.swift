import Foundation
import Testing
@testable import BatchClip

@MainActor
struct BatchLifecycleTests {
    private func fixture(body: String) throws -> (DownloaderStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatchClip-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture")
        try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let tools = ToolPaths(ytDLP: executable.path, ffmpeg: "/usr/bin/true", ffprobe: "/usr/bin/true")
        return (DownloaderStore(preferences: nil, tools: tools, notificationsEnabled: false), directory)
    }

    private func waitForCompletion(_ store: DownloaderStore) async throws {
        for _ in 0..<200 {
            if !store.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.cancelBatch()
        Issue.record("Batch did not finish within the fixture timeout")
    }

    @Test func rateLimitFailureStopsBeforeNextItem() async throws {
        let (store, directory) = try fixture(body: "echo 'ERROR: HTTP Error 429: Too Many Requests' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.items = [
            DownloadItem(url: "https://example.com/one", kind: .video, outputMode: .original),
            DownloadItem(url: "https://example.com/two", kind: .video, outputMode: .original)
        ]
        store.startBatch()
        try await waitForCompletion(store)
        #expect(store.items[0].status == .failed("Rate limited"))
        #expect(store.items[1].status == .queued)
        #expect(store.downloadAlert?.title == "Rate Limit Detected")
        #expect(!store.isStopping)
    }

    @Test func retryStartsOnlyFailedJobs() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BatchClip-output-\(UUID().uuidString).mp4")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let jsonPath = String(decoding: try JSONEncoder().encode(file.path), as: UTF8.self)
        let (store, directory) = try fixture(body: "printf '%s\\n' 'BC_FILE:\(jsonPath)'\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.items = [
            DownloadItem(url: "https://example.com/pending", kind: .video, outputMode: .original),
            DownloadItem(url: "https://example.com/failed", kind: .video, outputMode: .original, status: .failed("Failed"))
        ]
        store.retryFailedItems()
        try await waitForCompletion(store)
        #expect(store.items[0].status == .queued)
        #expect(store.items[1].status == .finished)
        #expect(store.items[1].downloadedFileURLs == [file])
    }
}
