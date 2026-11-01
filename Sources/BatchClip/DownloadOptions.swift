import Foundation

enum OutputMode: String, CaseIterable, Identifiable {
    case compatible = "Compatible"
    case original = "Original"
    var id: String { rawValue }
    func detail(for kind: DownloadKind) -> String {
        if self == .original { return kind == .video ? "Original video · no re-encoding" : "Original audio · no re-encoding" }
        return kind == .video ? "H.264 MP4" : "MP3 320 kbps"
    }
}

enum DownloadPacing: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case cautious = "Cautious"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .standard: "No scheduled waits. Stops on rate limits or bot checks."
        case .cautious: "Waits 8–18 seconds before downloads and spaces out requests."
        }
    }
    var arguments: [String] {
        let retries = ["--retry-sleep", "http:exp=5:60", "--retry-sleep", "fragment:exp=2:20"]
        return retries + (self == .cautious ? ["--sleep-requests", "1.5", "--sleep-interval", "8", "--max-sleep-interval", "18"] : [])
    }
}

enum DownloadPhase: String, Hashable {
    case preparing = "Preparing"
    case extracting = "Reading metadata"
    case waiting = "Waiting to protect against rate limits"
    case downloading = "Downloading"
    case merging = "Merging streams"
    case converting = "Converting"
    case checking = "Checking output"
    case extractingAudio = "Extracting original audio"
    case complete = "Complete"
}

struct ToolPaths: Sendable {
    var ytDLP: String
    var ffmpeg: String
    var ffprobe: String
    var deno: String? = nil
    static var installed: ToolPaths { ToolEnvironment.production.resolve() }

}

struct DownloadCommand {
    static func arguments(for item: DownloadItem, folder: URL, pacing: DownloadPacing, tools: ToolPaths) -> [String] {
        // Distinguish intentionally different jobs for the same URL.
        let suffix = item.outputMode == .original ? (item.kind == .audio ? " [original audio]" : " [original]") : (item.kind == .audio ? " [audio]" : "")
        var args = [
            "--ffmpeg-location", tools.ffmpeg,
            "--print", "before_dl:BC_TITLE:%(title)j",
            "--print", "before_dl:BC_THUMB:%(thumbnail)j",
            "--print", "after_move:BC_FILE:%(filepath)j",
            "--no-simulate", "--no-quiet", "--newline", "--progress", "--progress-delta", "0.3",
            "--progress-template", "download:BC_PROGRESS:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--progress-template", "postprocess:BC_POST:%(progress.postprocessor)s|%(progress.status)s",
            "--restrict-filenames", "-o", folder.appendingPathComponent("%(title).180B [%(id)s]\(suffix).%(ext)s").path,
            item.allowsPlaylist ? "--yes-playlist" : "--no-playlist"
        ] + pacing.arguments
        if let deno = tools.deno { args += ["--js-runtimes", "deno:\(deno)"] }
        switch (item.kind, item.outputMode) {
        case (.video, .compatible):
            args += ["-f", "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[vcodec^=avc1][ext=mp4]/bv*+ba/b", "-S", "vcodec:h264,ext:mp4:m4a", "--merge-output-format", "mp4"]
        case (.video, .original):
            args += ["-f", "bv*+ba/b"]
        case (.audio, .compatible):
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "320K"]
        case (.audio, .original):
            args += ["-f", "ba/b"]
        }
        // A URL can never be interpreted as a command option.
        args += ["--", item.url]
        return args
    }
}
