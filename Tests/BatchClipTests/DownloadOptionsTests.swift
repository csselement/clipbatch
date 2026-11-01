import Foundation
import Testing
@testable import BatchClip

struct DownloadOptionsTests {
    let tools = ToolPaths(ytDLP: "/yt-dlp", ffmpeg: "/ffmpeg", ffprobe: "/ffprobe")

    @Test func standardHasNoArtificialSleepAndCautiousHasOnePacingLayer() {
        let item = DownloadItem(url: "https://example.com/video", kind: .video)
        let standard = DownloadCommand.arguments(for: item, folder: URL(fileURLWithPath: "/tmp"), pacing: .standard, tools: tools)
        let cautious = DownloadCommand.arguments(for: item, folder: URL(fileURLWithPath: "/tmp"), pacing: .cautious, tools: tools)
        #expect(!standard.contains("--sleep-interval"))
        #expect(!standard.contains("--sleep-requests"))
        #expect(standard.contains("--retry-sleep"))
        #expect(cautious.filter { $0 == "--sleep-interval" }.count == 1)
        #expect(cautious.contains("8") && cautious.contains("18"))
        #expect(!cautious.contains("--exec"))
        #expect(Array(standard.suffix(2)) == ["--", item.url])
    }

    @Test func passesManagedDenoPathAsOneArgument() {
        var configured = tools
        configured.deno = "/Users/example/Application Support/BatchClip/Tools/deno"
        let item = DownloadItem(url: "https://youtube.com/watch?v=video", kind: .video)
        let args = DownloadCommand.arguments(for: item, folder: URL(fileURLWithPath: "/tmp"), pacing: .standard, tools: configured)
        let index = args.firstIndex(of: "--js-runtimes")!
        #expect(args[index + 1] == "deno:/Users/example/Application Support/BatchClip/Tools/deno")
    }

    @Test func originalVideoDoesNotRequestConversionOrForceMP4() {
        let item = DownloadItem(url: "https://example.com/video", kind: .video, outputMode: .original)
        let args = DownloadCommand.arguments(for: item, folder: URL(fileURLWithPath: "/tmp"), pacing: .standard, tools: tools)
        #expect(!args.contains("--exec"))
        #expect(!args.contains("--recode-video"))
        #expect(!args.contains("--merge-output-format"))
        #expect(args.contains("bv*+ba/b"))
    }

    @Test func playlistRequiresExplicitChoice() {
        var item = DownloadItem(url: "https://youtube.com/watch?v=video&list=playlist", kind: .video)
        #expect(!item.allowsPlaylist)
        item.includePlaylist = true
        #expect(item.allowsPlaylist)
        let args = DownloadCommand.arguments(for: item, folder: URL(fileURLWithPath: "/tmp"), pacing: .cautious, tools: tools)
        #expect(args.contains("--yes-playlist"))
    }

    @Test func parsesStructuredProgressMetadataAndWaiting() {
        #expect(DownloadOutputParser.event(for: "BC_TITLE:\"A title with \\n newline\"\n") == .title("A title with \n newline"))
        #expect(DownloadOutputParser.event(for: "BC_PROGRESS: 42.5%| 2MiB/s|00:03\n") == .progress(42.5, "42.5% · 2MiB/s · ETA 00:03"))
        #expect(DownloadOutputParser.event(for: "[download] Sleeping 12.0 seconds ...") == .phase(.waiting))
        #expect(DownloadOutputParser.event(for: "BC_POST:Merger|started") == .phase(.merging))
        #expect(DownloadOutputParser.event(for: "BC_PROGRESS: NA|NA|NA") == .progress(nil, ""))
    }

    @Test func phaseTransitionClearsDownloadPercentageAndAccumulatesTimings() {
        var item = DownloadItem(url: "https://example.com/video", kind: .video)
        item.setPhase(.downloading, now: Date(timeIntervalSince1970: 10))
        item.progressPercent = 100
        item.progressText = "100%"
        item.setPhase(.converting, now: Date(timeIntervalSince1970: 15))
        #expect(item.progressPercent == nil && item.progressText.isEmpty)
        #expect(item.phaseDurations[.downloading] == 5)
        item.setPhase(.complete, now: Date(timeIntervalSince1970: 18))
        #expect(item.phaseDurations[.converting] == 3)
        #expect(item.phaseStartedAt == nil)
    }
}
