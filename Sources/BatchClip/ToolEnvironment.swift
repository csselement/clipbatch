import Foundation

enum ToolKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case ytDLP = "yt-dlp", ffmpeg, ffprobe, deno
    var id: String { rawValue }
    var title: String { self == .deno ? "Deno · YouTube support" : rawValue }
    var versionArguments: [String] { self == .ffmpeg || self == .ffprobe ? ["-version"] : ["--version"] }
}

struct ToolEnvironment: Sendable {
    var root: URL
    var searchDirectories: [String]
    var environmentPath: String

    static var production: ToolEnvironment {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["BATCHCLIP_TEST_TOOLS_DIRECTORY"] {
            return ToolEnvironment(root: URL(fileURLWithPath: path), searchDirectories: [], environmentPath: "")
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ToolEnvironment(root: support.appendingPathComponent("BatchClip/Tools", isDirectory: true),
                               searchDirectories: ToolLocator.defaultSearchDirectories,
                               environmentPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    var receiptURL: URL { root.appendingPathComponent("installed.json") }
    func receipt() -> [String: String] {
        guard let data = try? Data(contentsOf: receiptURL),
              let paths = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return paths
    }

    func managedPath(for kind: ToolKind) -> String? {
        guard let relative = receipt()[kind.rawValue] else { return nil }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "versions", UUID(uuidString: String(components[1])) != nil,
              components[2] == kind.rawValue else { return nil }
        return root.appendingPathComponent(relative).path
    }

    func path(for kind: ToolKind) -> String {
        if let managed = managedPath(for: kind), FileManager.default.isExecutableFile(atPath: managed) { return managed }
        return ToolLocator.executablePath(named: kind.rawValue, searchDirectories: searchDirectories, environmentPath: environmentPath)
    }

    func resolve() -> ToolPaths {
        let ffmpeg = path(for: .ffmpeg)
        let siblingProbe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        let probe = FileManager.default.isExecutableFile(atPath: siblingProbe) ? siblingProbe : path(for: .ffprobe)
        let deno = path(for: .deno)
        return ToolPaths(ytDLP: path(for: .ytDLP), ffmpeg: ffmpeg, ffprobe: probe,
                         deno: FileManager.default.isExecutableFile(atPath: deno) ? deno : nil)
    }
}

extension ToolPaths {
    func path(for kind: ToolKind) -> String? {
        switch kind {
        case .ytDLP: ytDLP
        case .ffmpeg: ffmpeg
        case .ffprobe: ffprobe
        case .deno: deno
        }
    }
}
