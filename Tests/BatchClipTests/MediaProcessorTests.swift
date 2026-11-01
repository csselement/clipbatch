import Foundation
import Testing
@testable import BatchClip

@Suite(.serialized)
struct MediaProcessorTests {
    static var available: Bool { FileManager.default.isExecutableFile(atPath: ToolPaths.installed.ffmpeg) }
    let tools = ToolPaths.installed

    func fixture(codec: String, ext: String) async throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BatchClip-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sample.\(ext)")
        _ = try await DownloadRunner().run(executablePath: tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12", "-t", "0.5", "-c:v", codec, "-an", file.path
        ])
        return (folder, file)
    }

    @Test(.enabled(if: available)) func compatibleFileIsNotReencoded() async throws {
        let (folder, file) = try await fixture(codec: "libx264", ext: "mp4")
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: file)
        let result = try await MediaProcessor.compatibleVideo(file, tools: tools, runner: DownloadRunner()) { _ in }
        #expect(result == file)
        #expect(try Data(contentsOf: result) == before)
    }

    @Test(.enabled(if: available)) func remuxesH264AndCorrectsExtension() async throws {
        let (folder, file) = try await fixture(codec: "libx264", ext: "mkv")
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await MediaProcessor.compatibleVideo(file, tools: tools, runner: DownloadRunner()) { _ in }
        #expect(result.pathExtension == "mp4")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let info = try await MediaProcessor.inspect(result, tools: tools, runner: DownloadRunner())
        #expect(info.hasH264Video)
        #expect(info.format?.format_name?.contains("mp4") == true)
    }

    @Test(.enabled(if: available)) func transcodesVP9AndReportsProgress() async throws {
        let (folder, file) = try await fixture(codec: "libvpx-vp9", ext: "webm")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = LineRecorder()
        let result = try await MediaProcessor.compatibleVideo(file, tools: tools, runner: DownloadRunner()) { percent in
            await recorder.append(percent.map(String.init(describing:)) ?? "converting")
        }
        let info = try await MediaProcessor.inspect(result, tools: tools, runner: DownloadRunner())
        #expect(info.hasH264Video && result.pathExtension == "mp4")
        #expect(await recorder.lines.count > 1)
    }

    @Test(.enabled(if: available)) func failedConversionPreservesSourceAndCleansTemporaryOutput() async throws {
        let (folder, file) = try await fixture(codec: "libvpx-vp9", ext: "webm")
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: file)
        var failingTools = tools
        failingTools.ffmpeg = "/usr/bin/false"
        do {
            _ = try await MediaProcessor.compatibleVideo(file, tools: failingTools, runner: DownloadRunner()) { _ in }
            Issue.record("Expected encoder failure")
        } catch {}
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [file.lastPathComponent])
    }

    @Test(.enabled(if: available)) func destinationCollisionPreservesBothFiles() async throws {
        let (folder, file) = try await fixture(codec: "libx264", ext: "mkv")
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("sample.mp4")
        try Data("existing file".utf8).write(to: existing)
        do {
            _ = try await MediaProcessor.compatibleVideo(file, tools: tools, runner: DownloadRunner()) { _ in }
            Issue.record("Expected collision")
        } catch {}
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing file")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test(.enabled(if: available)) func cancellationDuringConversionPreservesSource() async throws {
        let (folder, file) = try await fixture(codec: "libvpx-vp9", ext: "webm")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("slow-encoder")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var slow = tools
        slow.ffmpeg = script.path
        let slowTools = slow
        let recorder = LineRecorder()
        let task = Task {
            try await MediaProcessor.compatibleVideo(file, tools: slowTools, runner: DownloadRunner()) { _ in await recorder.append("started") }
        }
        for _ in 0..<200 {
            if await recorder.contains("started") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await recorder.contains("started"))
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".batchclip-") })
    }
}
