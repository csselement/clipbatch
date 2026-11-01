import Foundation

struct ToolValidator {
    static func validate(_ kind: ToolKind, at url: URL, timeout: Duration = .seconds(30)) async throws -> String {
        let output = try await command(url.path, arguments: kind.versionArguments, timeout: timeout)
        let lines = output.components(separatedBy: .newlines)
        switch kind {
        case .ytDLP:
            guard let version = lines.first(where: { $0.range(of: #"^\d{4}\.\d{2}\.\d{2}"#, options: .regularExpression) != nil }),
                  version >= "2026.01.01" else {
                throw ToolSetupError.message("Update yt-dlp to a 2026 release or newer.")
            }
            return version
        case .deno:
            guard let version = lines.first(where: { $0.hasPrefix("deno ") }) else {
                throw ToolSetupError.message("Deno did not report a valid version.")
            }
            let numbers = version.dropFirst(5).split(separator: ".").prefix(2).compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] > 2 || (numbers[0] == 2 && numbers[1] >= 3) else {
                throw ToolSetupError.message("YouTube support needs Deno 2.3 or newer.")
            }
            return String(version.split(separator: " ")[1])
        case .ffmpeg, .ffprobe:
            guard let version = lines.first(where: { $0.hasPrefix("\(kind.rawValue) version ") }) else {
                throw ToolSetupError.message("\(kind.rawValue) did not report a valid version.")
            }
            if kind == .ffmpeg {
                let encoders = try await command(url.path, arguments: ["-hide_banner", "-encoders"], timeout: timeout)
                guard encoders.contains("libx264"), encoders.contains("libmp3lame") else {
                    throw ToolSetupError.message("This ffmpeg build lacks the H.264 or MP3 encoder BatchClip needs.")
                }
            }
            guard let number = version.split(separator: " ").dropFirst(2).first else {
                throw ToolSetupError.message("\(kind.rawValue) did not report a version number.")
            }
            return String(number).components(separatedBy: "-https:")[0]
        }
    }

    private static func command(_ executable: String, arguments: [String], timeout: Duration) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await DownloadRunner().run(executablePath: executable, arguments: arguments) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolSetupError.message("Checking this tool timed out. Install a fresh copy or try again.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
