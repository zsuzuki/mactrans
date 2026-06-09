import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private var anchorScreenNumber: NSNumber?
    private let model: AppModel

    var isVisible: Bool {
        panel?.isVisible == true
    }

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let wasVisible = panel?.isVisible == true
        if panel == nil {
            panel = makePanel()
        }
        if !wasVisible {
            reposition()
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func reposition() {
        guard let panel else { return }
        let screen = anchoredScreen()
        let visibleFrame = screen.visibleFrame
        let size = NSSize(width: 420, height: 360)
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 24,
            y: visibleFrame.minY + 24
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func anchoredScreen() -> NSScreen {
        if let anchorScreenNumber,
           let screen = NSScreen.screens.first(where: { $0.screenNumber == anchorScreenNumber }) {
            return screen
        }

        let resolvedScreen = NSScreen.primaryDisplay ?? NSScreen.main ?? NSScreen.screens[0]
        anchorScreenNumber = resolvedScreen.screenNumber
        return resolvedScreen
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

private extension NSScreen {
    var screenNumber: NSNumber? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    static var primaryDisplay: NSScreen? {
        screens.first(where: { $0.frame.contains(CGPoint.zero) }) ?? screens.first
    }
}
