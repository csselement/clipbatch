import SwiftUI

struct BatchFooter: View {
    let store: DownloaderStore
    @State private var showingTools = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text("Save to:").foregroundStyle(.secondary)
                Text(store.selectedFolder.path)
                    .lineLimit(1).truncationMode(.middle)
                    .help(store.selectedFolder.path)
                Button("Choose…") { store.chooseFolder() }.disabled(store.isRunning)
                Spacer(minLength: 20)
                Picker("Pacing", selection: Binding(get: { store.pacing }, set: { store.pacing = $0 })) {
                    ForEach(DownloadPacing.allCases) { pacing in Text(pacing.rawValue).tag(pacing) }
                }
                .frame(width: 180)
                .disabled(store.isRunning)
                .help(store.pacing.detail)
                Button { showingTools.toggle() } label: { Image(systemName: "wrench.and.screwdriver") }
                    .help("Tool status")
                    .accessibilityLabel("Tool status")
                    .popover(isPresented: $showingTools) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Download Tools").font(.headline)
                            Text(store.dependencySummary)
                            Text("yt-dlp: \(store.tools.ytDLP)\nffmpeg: \(store.tools.ffmpeg)\nffprobe: \(store.tools.ffprobe)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(20)
                    }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.globalMessage)
                        .font(.callout.weight(.medium)).lineLimit(2)
                        .accessibilityLabel("Batch status: \(store.globalMessage)")
                    Text(store.pacing.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if store.isRunning {
                    ProgressView().controlSize(.small)
                    Button { store.cancelBatch() } label: {
                        Label(store.isStopping ? "Stopping…" : "Stop Batch", systemImage: "stop.circle")
                            .frame(minWidth: 120)
                    }
                    .disabled(store.isStopping)
                } else {
                    Button { store.startBatch() } label: {
                        Label("Start Batch", systemImage: "arrow.down.circle.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canStart)
                    .help("Start queued downloads (⌘Return)")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}
