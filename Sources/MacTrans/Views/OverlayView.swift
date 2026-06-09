import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranscriptStore
    @State private var autoScroll = true
    @State private var lastCompletedSegmentID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MacTrans")
                    .font(.headline)
                Spacer()
                Button {
                    autoScroll.toggle()
                } label: {
                    Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help(autoScroll ? "Auto-scroll is on" : "Resume auto-scroll")

                Button {
                    model.toggleRecording()
                } label: {
                    Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.plain)
                .help(model.isRecording ? "Stop recording" : "Start recording")

                Text("\(store.segments.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    ScrollActivityObserver {
                        autoScroll = false
                    } onReachBottom: {
                        autoScroll = true
                    }
                    .frame(width: 0, height: 0)

                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.segments.isEmpty {
                            Text("...")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 96)
                        } else {
                            ForEach(store.segments) { segment in
                                TranscriptSegmentView(segment: segment)
                                    .id(segment.id)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .onChange(of: store.segments) { _, segments in
                    guard autoScroll else { return }
                    guard let completed = segments.last(where: { $0.state == .translated || $0.state == .failed }) else {
                        return
                    }
                    guard completed.id != lastCompletedSegmentID else { return }
                    lastCompletedSegmentID = completed.id
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(completed.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ScrollActivityObserver: NSViewRepresentable {
    var onUserScroll: () -> Void
    var onReachBottom: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onUserScroll = onUserScroll
        view.onReachBottom = onReachBottom
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ObserverView else { return }
        view.onUserScroll = onUserScroll
        view.onReachBottom = onReachBottom
    }

    @MainActor
    private final class ObserverView: NSView {
        var onUserScroll: (() -> Void)?
        var onReachBottom: (() -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        private func installIfNeeded() {
            guard observedScrollView == nil else { return }
            guard let scrollView = sequence(first: superview, next: { $0?.superview }).first(where: { $0 is NSScrollView }) as? NSScrollView else {
                return
            }
            observedScrollView = scrollView
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak scrollView] event in
                if let scrollView, event.window === scrollView.window {
                    if self?.isNearBottom(scrollView) == true {
                        self?.onReachBottom?()
                    } else {
                        self?.onUserScroll?()
                    }
                }
                return event
            }
        }

        private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleMaxY = scrollView.contentView.bounds.maxY
            return documentHeight - visibleMaxY < 36
        }
    }
}

private struct TranscriptSegmentView: View {
    var segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(segment.sourceText)
                .font(.system(size: 15, weight: .semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(translationText)
                .font(.system(size: 14))
                .foregroundStyle(segment.state == .failed ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var translationText: String {
        if segment.state == .failed {
            return segment.errorMessage ?? "..."
        }
        return segment.translatedText.isEmpty ? "..." : segment.translatedText
    }
}
