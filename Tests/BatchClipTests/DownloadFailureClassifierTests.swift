import Testing
@testable import BatchClip

struct DownloadFailureClassifierTests {
    @Test func classifiesUnavailableTwitterVideo() {
        let details = DownloadFailureClassifier.details(
            from: "ERROR: [twitter] 2070144987224743956: Video #1 is unavailable"
        )

        #expect(details.title == "No X Video Found")
        #expect(details.rowStatus == "No video found")
        #expect(!details.stopsBatch)
    }

    @Test func classifiesMissingTwitterVideo() {
        let details = DownloadFailureClassifier.details(
            from: "ERROR: [twitter] 2070144987224743956: No video could be found in this tweet"
        )

        #expect(details.title == "No X Video Found")
        #expect(details.rowStatus == "No video found")
        #expect(!details.stopsBatch)
    }
}
