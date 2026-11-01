import AppKit
import SwiftUI

struct ContentView: View {
    let store: DownloaderStore
    @State private var linkKind: DownloadKind = .video

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HSplitView {
                    EntryPanel(store: store, linkKind: $linkKind)
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)

                    QueuePanel(store: store)
                        .frame(minWidth: 460)
                }
                Divider()
                BatchFooter(store: store)
            }
        }
        .alert(item: Binding(
            get: { store.downloadAlert },
            set: { store.downloadAlert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct EntryPanel: View {
    let store: DownloaderStore
    @Binding var linkKind: DownloadKind
    @AppStorage("outputMode") private var outputMode: OutputMode = .compatible
    @State private var includePlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Links")
                .font(.headline)
            Text("Paste one URL per line.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LinkListEditor(text: Binding(get: { store.pendingText }, set: { store.pendingText = $0 }))
                .padding(8)
                .utilitySurface(cornerRadius: 8)
                .frame(minHeight: 120, maxHeight: .infinity)
                .accessibilityLabel("Links to add")
                .disabled(store.isRunning)

            Picker("Type", selection: $linkKind) {
                ForEach(DownloadKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: kind.symbolName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Picker("Output", selection: $outputMode) {
                Text("Compatible").tag(OutputMode.compatible)
                Text("Original / fastest").tag(OutputMode.original)
            }
            Text(outputMode.detail(for: linkKind))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Download entire playlists", isOn: $includePlaylist)
                .toggleStyle(.checkbox)
                .help("Off downloads a single video. Turn on to include all entries from playlist links.")

            HStack {
                Button("Import…") { store.openTextFile() }
                Spacer()
                Button { store.addLinks(kind: linkKind, outputMode: outputMode, includePlaylist: includePlaylist) } label: {
                    Label("Add to Batch", systemImage: "plus")
                }
                .disabled(store.pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(.bordered)
            .disabled(store.isRunning)

            if store.hasMissingDependencies {
                DependencySetupView(store: store)
            }
        }
        .padding(20)
    }
}

private struct DependencySetupView: View {
    let store: DownloaderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text(store.dependencySetupMessage)
                        .font(.caption)
                        .foregroundStyle(.primary)

                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(store.dependencySetupCommands)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.dependencySetupCommands, forType: .string)
                store.globalMessage = "Setup commands copied"
            } label: {
                Label("Copy Setup Commands", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct QueuePanel: View {
    let store: DownloaderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Batch")
                    .font(.headline)
                Text("\(store.items.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.retryFailedItems()
                } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRunning || !store.hasFailedItems)

                Button {
                    store.clearFinished()
                } label: {
                    Label("Clear Done", systemImage: "checkmark.circle")
                }
                .disabled(store.isRunning || !store.hasFinishedItems)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let warning = store.rateLimitWarning {
                RateLimitWarningView(message: warning)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                Divider()
            }

            if store.items.isEmpty {
                ContentUnavailableView(
                    "No Links Queued",
                    systemImage: "tray",
                    description: Text("Paste one link per line, choose video or audio, then add them to the batch.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.items) { item in
                        QueueRow(
                            item: item,
                            isStarting: store.isStartingNext(item),
                            canRemove: !store.isRunning,
                            onRemove: { store.removeItem(id: item.id) },
                            onRetry: { store.retryFailedItems(itemID: item.id) }
                        )
                            .padding(.vertical, 6)
                    }
                    .onDelete(perform: store.removeItems)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct RateLimitWarningView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct QueueRow: View {
    let item: DownloadItem
    let isStarting: Bool
    let canRemove: Bool
    let onRemove: () -> Void
    let onRetry: () -> Void
    @State private var showingDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbolName)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    if let thumbURL = URL(string: item.thumbnailURL), !item.thumbnailURL.isEmpty {
                        AsyncImage(url: thumbURL) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .scaledToFill()
                            } else if phase.error != nil {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, height: 27)
                            } else {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 48, height: 27)
                            }
                        }
                        .frame(width: 48, height: 27)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .font(.callout)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text((URL(string: item.url)?.host ?? "") + (item.allowsPlaylist ? " · Playlist" : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(item.outputDetail)
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isStarting && item.status == .queued {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Starting...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .running = item.status {
                    ProgressView(value: item.progressPercent, total: 100)
                        .progressViewStyle(.linear)
                }

            }

            Spacer()

            if !item.log.isEmpty {
                Button { showingDetails = true } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help("Show details and timings")
                .accessibilityLabel("Show download details")
            }

            if item.status.isFinished, !item.downloadedFileURLs.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(item.downloadedFileURLs)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Show downloaded file in Finder")
                .accessibilityLabel("Show downloaded file in Finder")
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove from batch")
            .accessibilityLabel("Remove from batch")
            .disabled(!canRemove)
            .opacity(canRemove ? 0.8 : 0.25)

            StatusIcon(status: item.status, isStarting: isStarting)
        }
        .contextMenu {
            if item.status.isFailed {
                Button("Retry Download", action: onRetry).disabled(!canRemove)
            }
            Button("Remove from Batch", action: onRemove).disabled(!canRemove)
        }
        .sheet(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.displayTitle).font(.headline).lineLimit(2)
                if !item.timingSummary.isEmpty {
                    Text(item.timingSummary).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(item.log).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { showingDetails = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(20)
            .frame(width: 660, height: 420)
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .queued: .secondary
        case .running: .blue
        case .finished: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        guard case .running = item.status else {
            return item.status.label
        }

        let activity = item.activityText.isEmpty ? item.status.label : item.activityText
        return item.progressText.isEmpty ? activity : "\(activity) - \(item.progressText)"
    }
}

private struct StatusIcon: View {
    let status: DownloadStatus
    let isStarting: Bool

    var body: some View {
        Group {
            switch status {
            case .queued:
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "circle")
                }
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 24, height: 24)
    }
}

#Preview {
    ContentView(store: DownloaderStore())
}

private extension View {
    func utilitySurface(cornerRadius: CGFloat) -> some View {
        modifier(UtilitySurface(cornerRadius: cornerRadius))
    }
}

private struct UtilitySurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.background, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.separator, lineWidth: 1)
                }
        }
    }
}

private struct LinkListEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PasteAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.allowsUndo = true
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        textView.onPasteComplete = { [weak textView] pastedText in
            guard
                let textView,
                let pastedText,
                !pastedText.isEmpty,
                !pastedText.hasSuffix("\n"),
                !pastedText.hasSuffix("\r"),
                !pastedText.hasSuffix("\r\n")
            else { return }

            textView.insertText("\n", replacementRange: textView.selectedRange())
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.textView = textView
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: LinkListEditor
        weak var textView: NSTextView?

        init(_ parent: LinkListEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class PasteAwareTextView: NSTextView {
    var onPasteComplete: ((String?) -> Void)?

    override func paste(_ sender: Any?) {
        let pastedText = NSPasteboard.general.string(forType: .string)
        super.paste(sender)
        onPasteComplete?(pastedText)
    }
}
