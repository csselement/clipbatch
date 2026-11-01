import Foundation
import Testing
@testable import BatchClip

/// Opt-in local HTTP fixture tests. No requests to public media sites.
@Suite(.serialized)
@MainActor
struct DownloadPipelineTests {
    nonisolated static var baseURL: String? { ProcessInfo.processInfo.environment["BATCHCLIP_TEST_BASE_URL"] }

    @Test(.enabled(if: baseURL != nil)) func downloadsAllOutputModesAndRevealsFinalFiles() async throws {
        let base = try #require(Self.baseURL)
        for (kind, mode, name) in [
            (DownloadKind.video, OutputMode.compatible, "sample.mp4"),
            (.video, .compatible, "vp9.webm"),
            (.video, .original, "vp9.webm"),
            (.audio, .compatible, "sample.mp4"),
            (.audio, .original, "sample.mp4")
        ] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BatchClip-pipeline-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = DownloaderStore(preferences: nil, notificationsEnabled: false)
            store.selectedFolder = folder
            store.pacing = .standard
            store.pendingText = "\(base)/\(name)"
            store.addLinks(kind: kind, outputMode: mode)
            store.startBatch()
            for _ in 0..<600 {
                if !store.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if store.isRunning { store.cancelBatch() }
            let item = try #require(store.items.first)
            try #require(item.status == .finished, "\(kind) / \(mode) failed: \(item.log)")
            let file = try #require(item.downloadedFileURLs.first)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(item.title != nil)
            #expect(item.phase == .complete && !item.phaseDurations.isEmpty)
            let info = try await MediaProcessor.inspect(file, tools: .installed, runner: DownloadRunner())
            if kind == .video {
                #expect(info.streams.contains { $0.codec_type == "video" && $0.codec_name == (mode == .compatible ? "h264" : "vp9") })
                if mode == .compatible { #expect(file.pathExtension == "mp4") }
            } else {
                #expect(!info.streams.contains { $0.codec_type == "video" })
                #expect(info.streams.contains { $0.codec_type == "audio" && $0.codec_name == (mode == .compatible ? "mp3" : "aac") })
            }
        }
    }

    @Test(.enabled(if: baseURL != nil)) func cautiousWaitIsVisibleAndCancellable() async throws {
        let store = DownloaderStore(preferences: nil, notificationsEnabled: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BatchClip-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        store.selectedFolder = folder
        store.pendingText = "\(try #require(Self.baseURL))/sample.mp4"
        store.addLinks(kind: .video)
        store.startBatch()
        for _ in 0..<100 {
            if store.items.first?.phase == .waiting || !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.items.first?.phase == .waiting)
        #expect(store.items.first?.progressPercent == nil)
        store.cancelBatch()
        for _ in 0..<30 {
            if !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!store.isRunning)
        #expect(store.items.first?.status == .failed("Cancelled"))
    }
}
