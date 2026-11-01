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
    var outputMode: OutputMode = .compatible
    var includePlaylist = false
    var status: DownloadStatus = .queued
    var log: String = ""
    var progressPercent: Double? = nil
    var progressText: String = ""
    var activityText: String = ""
    var title: String?
    var thumbnailURL: String = ""
    var downloadedFileURLs: [URL] = []
    var phase: DownloadPhase = .preparing
    var phaseStartedAt: Date?
    var phaseDurations: [DownloadPhase: TimeInterval] = [:]

    var outputDetail: String {
        outputMode == .original ? "Original \(kind.rawValue.lowercased())" : kind.detail
    }

    mutating func setPhase(_ newPhase: DownloadPhase, now: Date = Date()) {
        guard newPhase != phase || phaseStartedAt == nil else { return }
        finishTiming(now: now)
        phase = newPhase
        phaseStartedAt = newPhase == .complete ? nil : now
        activityText = newPhase.rawValue
        progressPercent = nil
        progressText = ""
    }

    mutating func finishTiming(now: Date = Date()) {
        if let started = phaseStartedAt {
            phaseDurations[phase, default: 0] += now.timeIntervalSince(started)
        }
        phaseStartedAt = nil
    }

    var timingSummary: String {
        phaseDurations.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue): \(String(format: "%.1f", $0.value))s" }
            .joined(separator: " · ")
    }

    var displayTitle: String {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? url : cleaned
    }

    var allowsPlaylist: Bool { includePlaylist }
}
