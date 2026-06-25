import AppKit
import SwiftUI

struct ContentView: View {
    let store: DownloaderStore
    @State private var linkKind: DownloadKind = .video

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderView(store: store)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                Divider()

                HSplitView {
                    EntryPanel(store: store, linkKind: $linkKind)
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)

                    QueuePanel(store: store)
                        .frame(minWidth: 460)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
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

private struct HeaderView: View {
    let store: DownloaderStore

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BatchClip")
                    .font(.title2.weight(.semibold))
                Text("Video saves as H.264 MP4. Audio saves as MP3 320 kbps.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(store.globalMessage)
                    .font(.callout.weight(.medium))
                Text(store.dependencySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EntryPanel: View {
    let store: DownloaderStore
    @Binding var linkKind: DownloadKind

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Links")
                    .font(.headline)

                LinkListEditor(text: Binding(
                    get: { store.pendingText },
                    set: { store.pendingText = $0 }
                ))
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .utilitySurface(cornerRadius: 8)
                .frame(minHeight: 180)
                .accessibilityLabel("Links to add")
            }

            Picker("Type", selection: $linkKind) {
                ForEach(DownloadKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: kind.symbolName)
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: Binding(
                get: { store.isRateLimitEnabled },
                set: { store.isRateLimitEnabled = $0 }
            )) {
                Label("Enable rate-limiting", systemImage: "timer")
            }
            .toggleStyle(.checkbox)
            .disabled(store.isRunning || !store.canDisableRateLimit)

            Text(store.rateLimitControlMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                store.addLinks(kind: linkKind)
            } label: {
                Label("Add to Batch", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRunning || store.pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            VStack(alignment: .leading, spacing: 8) {
                Text("Download Folder")
                    .font(.headline)

                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(store.selectedFolder.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Browse") {
                        store.chooseFolder()
                    }
                    .disabled(store.isRunning)
                }
                .padding(10)
                .utilitySurface(cornerRadius: 8)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    store.startBatch()
                } label: {
                    Label("Start Batch", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStart)

                Button {
                    store.cancelBatch()
                } label: {
                    Label("Stop Batch", systemImage: "stop.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!store.isRunning)
            }
        }
        .padding(20)
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
                            onRemove: { store.removeItem(id: item.id) }
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
                    }
                }

                HStack(spacing: 8) {
                    Text(item.kind.detail)
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
            .disabled(!canRemove)
            .opacity(canRemove ? 0.8 : 0.25)

            StatusIcon(status: item.status, isStarting: isStarting)
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
