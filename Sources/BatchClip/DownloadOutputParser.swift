import Foundation

enum DownloadEvent: Equatable {
    case title(String), thumbnail(String), file(URL)
    case progress(Double?, String)
    case phase(DownloadPhase)
}

/// DownloadRunner supplies complete lines, so pipe boundaries cannot truncate events.
struct DownloadOutputParser {
    static func event(for line: String) -> DownloadEvent? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, type) in [("BC_TITLE:", 0), ("BC_THUMB:", 1), ("BC_FILE:", 2)] {
            if line.hasPrefix(prefix),
               let value = try? JSONDecoder().decode(String.self, from: Data(line.dropFirst(prefix.count).utf8)) {
                switch type {
                case 0: return .title(value)
                case 1: return .thumbnail(value)
                default: return .file(URL(fileURLWithPath: value))
                }
            }
        }
        if line.hasPrefix("BC_PROGRESS:") {
            let parts = line.dropFirst("BC_PROGRESS:".count).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let percent = parts.first.flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            let valid = percent.flatMap { (0...100).contains($0) ? $0 : nil }
            let details = parts.enumerated().compactMap { index, part -> String? in
                guard !part.isEmpty, part != "NA", part != "Unknown", part != "N/A" else { return nil }
                return index == 2 ? "ETA \(part)" : part
            }.joined(separator: " · ")
            return .progress(valid, details)
        }
        let lower = line.lowercased()
        if lower.contains("sleeping") || lower.contains("sleep interval") { return .phase(.waiting) }
        if line.hasPrefix("BC_POST:") {
            if lower.contains("merger") { return .phase(.merging) }
            if lower.contains("extractaudio") || lower.contains("videoconvertor") { return .phase(.converting) }
            return .phase(.checking)
        }
        if lower.hasPrefix("[merger]") { return .phase(.merging) }
        if lower.hasPrefix("[extractaudio]") { return .phase(.converting) }
        if lower.hasPrefix("[download]") { return .phase(.downloading) }
        if lower.contains("extracting url") || lower.contains("downloading webpage") || lower.contains("api json") || lower.contains("downloading player") { return .phase(.extracting) }
        return nil
    }
}
