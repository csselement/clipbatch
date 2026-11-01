import Foundation
import Testing
import Darwin
@testable import BatchClip

actor LineRecorder {
    var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func contains(_ value: String) -> Bool { lines.contains { $0.contains(value) } }
}

struct DownloadRunnerTests {
    @Test func deliversCompleteUTF8LinesAndFinalPartialLine() async throws {
        let recorder = LineRecorder()
        let output = try await DownloadRunner().run(executablePath: "/bin/sh", arguments: ["-c", "printf '\\303'; sleep 0.05; printf '\\251 first\\rsecond\\nlast'"]) {
            await recorder.append($0)
        }
        #expect(output == "é first\nsecond\nlast")
        #expect(await recorder.lines == ["é first\n", "second\n", "last"])
    }

    @Test func nonzeroExitIncludesStderr() async {
        do {
            _ = try await DownloadRunner().run(executablePath: "/bin/sh", arguments: ["-c", "echo useful-error >&2; exit 7"])
            Issue.record("Expected failure")
        } catch {
            #expect(error.localizedDescription.contains("useful-error"))
        }
    }

    @Test func cancellationStopsProcessAndAllowsReuse() async throws {
        let runner = DownloadRunner()
        let recorder = LineRecorder()
        let task = Task {
            try await runner.run(executablePath: "/bin/sh", arguments: ["-c", "echo ready; exec /bin/sleep 30"]) { await recorder.append($0) }
        }
        for _ in 0..<200 {
            if await recorder.contains("ready") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.contains("ready"))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: .now) < .seconds(2))
        let output = try await runner.run(executablePath: "/bin/echo", arguments: ["reused"])
        #expect(output == "reused\n")
    }

    @Test func cancellationKillsChildrenThatIgnoreTermination() async throws {
        let runner = DownloadRunner()
        let recorder = LineRecorder()
        let task = Task {
            try await runner.run(executablePath: "/bin/sh", arguments: ["-c", "trap '' TERM; /bin/sleep 30 & echo child:$!; wait"]) { await recorder.append($0) }
        }
        for _ in 0..<200 {
            if await recorder.contains("child:") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let line = try #require(await recorder.lines.first { $0.hasPrefix("child:") })
        let pid = try #require(Int32(line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: .now) < .seconds(3))
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) != 0)
    }

    @Test func launchFailureDoesNotPoisonRunner() async throws {
        let runner = DownloadRunner()
        do { _ = try await runner.run(executablePath: "/does/not/exist", arguments: []); Issue.record("Expected failure") }
        catch { #expect(error is POSIXError) }
        #expect(try await runner.run(executablePath: "/bin/echo", arguments: ["ok"]) == "ok\n")
    }
}
