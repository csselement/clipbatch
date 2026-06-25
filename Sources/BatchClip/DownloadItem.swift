import Foundation

enum DownloadKind: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        }
    }

    var detail: String {
        switch self {
        case .video: "H.264 MP4"
        case .audio: "MP3 320 kbps"
        }
    }
}

enum DownloadStatus: Equatable {
    case queued
    case running
    case finished
    case failed(String)

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Downloading"
        case .finished: "Done"
        case .failed(let message): message.isEmpty ? "Failed" : message
        }
    }

    var isFinished: Bool {
        self == .finished
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }

        return false
    }
}

struct DownloadItem: Identifiable, Equatable {
    let id = UUID()
    var url: String
    var kind: DownloadKind
    var status: DownloadStatus = .queued
    var log: String = ""
    var progressPercent: Double? = nil
    var progressText: String = ""
    var activityText: String = ""
    var title: String?
    var thumbnailURL: String = ""

    var displayTitle: String {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? url : cleaned
    }

    var allowsPlaylist: Bool {
        guard let components = URLComponents(string: url) else {
            return false
        }

        return components.queryItems?.contains {
            $0.name.lowercased() == "list" && !($0.value ?? "").isEmpty
        } ?? false
    }
}
