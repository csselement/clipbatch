import Foundation
import Testing
@testable import BatchClip

struct ToolLocatorTests {
    @Test func findsExecutableInConfiguredSearchDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batchclip-tool-locator-\(UUID().uuidString)", isDirectory: true)
        let executable = directory.appendingPathComponent("demo-tool")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let path = ToolLocator.executablePath(
            named: "demo-tool",
            searchDirectories: [directory.path],
            environmentPath: ""
        )

        #expect(path == executable.path)
    }

    @Test func fallsBackToFirstSearchDirectoryWhenToolIsMissing() {
        let path = ToolLocator.executablePath(
            named: "missing-tool",
            searchDirectories: ["/tmp/batchclip-missing"],
            environmentPath: ""
        )

        #expect(path == "/tmp/batchclip-missing/missing-tool")
    }
}
