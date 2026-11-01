import SwiftUI

struct BatchFooter: View {
    let store: DownloaderStore

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
                Button { store.showingToolSetup = true } label: { Image(systemName: "wrench.and.screwdriver") }
                    .help("Manage download tools")
                    .accessibilityLabel("Manage download tools")
                    .disabled(store.isRunning)

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
                } else if store.hasMissingDependencies || store.needsYouTubeSetup {
                    Button { store.showingToolSetup = true } label: {
                        Label("Set Up Tools…", systemImage: "arrow.down.circle")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
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
