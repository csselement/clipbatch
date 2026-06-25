import Testing
@testable import BatchClip

struct DependencyInstallerTests {
    @Test func commandsUseOnlyBrewInstallWhenHomebrewExists() {
        #expect(DependencyInstaller.commands(hasHomebrew: true) == "brew install yt-dlp ffmpeg")
    }

    @Test func commandsIncludeHomebrewInstallWhenHomebrewIsMissing() {
        let commands = DependencyInstaller.commands(hasHomebrew: false)

        #expect(commands.contains("https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"))
        #expect(commands.contains("brew install yt-dlp ffmpeg"))
    }
}
