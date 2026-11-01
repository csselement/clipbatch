import AppKit
import SwiftUI

struct ToolSetupView: View {
    let store: DownloaderStore
    @Environment(\.dismiss) private var dismiss
    @State private var showManualSetup = false
    private var manager: ToolManager { store.dependencies }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(manager.needsSetup ? "Get ready to download" : "Download tools are ready")
                    .font(.title2.weight(.semibold))
                Text(manager.needsSetup ? "BatchClip can download the tools it needs. No Terminal, Homebrew, or administrator password required." : "You’re ready to download. BatchClip will use the tools below.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 14) {
                ForEach(manager.availability) { tool in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tool.ready ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(tool.ready ? Color.green : Color.secondary)
                            .font(.title3).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.kind.title).font(.headline)
                            Text(tool.detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).help(tool.detail)
                        }
                        Spacer()
                        if tool.ready, let path = tool.path {
                            Text(path.hasPrefix(manager.environment.root.path + "/") ? "BatchClip" : "Already installed")
                                .font(.caption).foregroundStyle(.secondary).help(path)
                        }
                    }
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if manager.isInstalling {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: manager.progress.fraction)
                    Text(manager.progress.message).font(.callout).foregroundStyle(.secondary)
                }
            } else if manager.isChecking {
                HStack { ProgressView().controlSize(.small); Text("Checking installed tools…").foregroundStyle(.secondary) }
            } else if let error = manager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if manager.needsSetup && !manager.progress.message.isEmpty {
                Text(manager.progress.message).font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Working tools are reused. Missing tools are installed privately for BatchClip; other apps and system tools are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("Download sources:").foregroundStyle(.secondary)
                    Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp/releases")!)
                    Link("FFmpeg builds", destination: URL(string: "https://ffmpeg.martin-riedl.de/")!)
                    Link("Deno", destination: URL(string: "https://github.com/denoland/deno/releases")!)
                }.font(.caption)
            }
            DisclosureGroup("Prefer Homebrew?", isExpanded: $showManualSetup) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If you manage tools yourself, run these commands in Terminal, then choose Check Again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(store.dependencySetupCommands).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy Commands") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.dependencySetupCommands, forType: .string)
                    }
                }.padding(.top, 6)
            }
            Divider()
            HStack {
                Button("Check Again") { Task { await manager.refresh() } }
                    .disabled(manager.isBusy || store.isRunning)
                Spacer()
                if manager.isInstalling && manager.progress.fraction >= 1 {
                    Text("Finishing setup…").foregroundStyle(.secondary)
                } else if manager.isInstalling {
                    Button(manager.isCancelling ? "Cancelling…" : "Cancel Setup") { manager.cancelInstallation() }
                        .disabled(manager.isCancelling)
                } else {
                    Button(manager.needsSetup ? "Not Now" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if manager.needsSetup {
                        Button(manager.errorMessage == nil ? "Install Download Tools" : "Retry Setup") { manager.installMissingTools() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(manager.isBusy || store.isRunning)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 570)
        .interactiveDismissDisabled(manager.isBusy)
    }
}
