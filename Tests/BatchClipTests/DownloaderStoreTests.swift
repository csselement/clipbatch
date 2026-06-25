import Testing
@testable import BatchClip

@MainActor
struct DownloaderStoreTests {
    @Test func addLinksIsIgnoredWhileBatchIsRunning() {
        let store = DownloaderStore()
        store.isRunning = true
        store.pendingText = "https://example.com/video\n"

        store.addLinks(kind: .video)

        #expect(store.items.isEmpty)
        #expect(store.pendingText == "https://example.com/video\n")
    }

    @Test func retryFailedItemsClearsStaleProgressState() {
        let store = DownloaderStore()
        store.items = [
            DownloadItem(
                url: "https://example.com/video",
                kind: .video,
                status: .failed("Failed"),
                log: "old log",
                progressPercent: 42,
                progressText: "42%",
                activityText: "Old failure"
            )
        ]

        store.retryFailedItems()

        #expect(store.items[0].status == .queued)
        #expect(store.items[0].log.isEmpty)
        #expect(store.items[0].progressPercent == nil)
        #expect(store.items[0].progressText.isEmpty)
        #expect(store.items[0].activityText.isEmpty)
    }
}
