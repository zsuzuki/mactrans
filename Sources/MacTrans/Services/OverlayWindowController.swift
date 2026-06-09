import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func reposition() {
        guard let panel else { return }
        let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
        let size = NSSize(width: 420, height: 360)
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 24,
            y: visibleFrame.minY + 24
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func makePanel() -> NSPanel {
        let rootView = OverlayView(model: model, store: model.transcriptStore)
        let hostingController = NSHostingController(rootView: rootView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.title = "MacTrans Overlay"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        return panel
    }
}
