import Foundation

/// Versioned upstream downloads and SHA-256 values are reviewed together.
/// No installer scripts, package manager, administrator access, or Python install.
struct ToolDownload: Sendable {
    var kind: ToolKind
    var version: String
    var url: URL
    var sha256: String
    var isZip: Bool
    var executableName: String? = nil
    var supportDirectory: String? = nil
}

enum ToolArchitecture: String, Sendable {
    case arm64, intel
    static var current: ToolArchitecture {
        #if arch(arm64)
        .arm64
        #else
        .intel
        #endif
    }
}

struct ToolDownloadCatalog {
    static func downloads(for requested: Set<ToolKind>, architecture: ToolArchitecture = .current) -> [ToolDownload] {
        var kinds = requested
        // yt-dlp locates ffprobe beside the ffmpeg executable. Install the pair together.
        if !kinds.isDisjoint(with: [.ffmpeg, .ffprobe]) { kinds.formUnion([.ffmpeg, .ffprobe]) }
        let arm = architecture == .arm64
        let ffBase = "https://ffmpeg.martin-riedl.de/download/macos/" + (arm ? "arm64/1789931890_9.0.2" : "amd64/1789931006_9.0.2")
        // Use the official one-directory bundle: the single-file binary unpacks Python
        // every time it runs, adding substantial startup cost to every queued clip.
        let all: [ToolDownload] = [
            .init(kind: .ytDLP, version: "2026.10.26", url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos.zip")!, sha256: "20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1", isZip: true, executableName: "yt-dlp_macos", supportDirectory: "_internal"),
            .init(kind: .ffmpeg, version: "9.0.2", url: URL(string: ffBase + "/ffmpeg.zip")!, sha256: arm ? "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924" : "7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4", isZip: true),
            .init(kind: .ffprobe, version: "9.0.2", url: URL(string: ffBase + "/ffprobe.zip")!, sha256: arm ? "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6" : "2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd", isZip: true),
            .init(kind: .deno, version: "2.9.8", url: URL(string: "https://github.com/denoland/deno/releases/download/v2.9.8/deno-\(arm ? "aarch64" : "x86_64")-apple-darwin.zip")!, sha256: arm ? "9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e" : "4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c", isZip: true)
        ]
        return all.filter { kinds.contains($0.kind) }
    }
}
