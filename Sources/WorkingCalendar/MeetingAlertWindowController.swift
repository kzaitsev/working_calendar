import AppKit
import SwiftUI

@MainActor
final class MeetingAlertWindowController {
    private var panel: NSPanel?

    func show(
        alert: MeetingAlert,
        dismiss: @escaping () -> Void,
        snooze: @escaping () -> Void,
        join: @escaping () -> Void,
        requestAttention: Bool = true
    ) {
        let rootView = AlertOverlayView(
            alert: alert,
            dismiss: dismiss,
            snooze: snooze,
            join: join
        )

        let hostingView = NSHostingView(rootView: rootView)
        let size = NSSize(width: 560, height: 240)

        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newPanel.level = .statusBar
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            newPanel.isReleasedWhenClosed = false
            newPanel.hidesOnDeactivate = false
            newPanel.titleVisibility = .hidden
            newPanel.titlebarAppearsTransparent = true
            newPanel.isMovableByWindowBackground = true
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            panel = newPanel
        }

        guard let panel else { return }
        panel.contentView = hostingView
        panel.setContentSize(size)
        position(panel)
        panel.orderFrontRegardless()
        if requestAttention {
            NSApp.requestUserAttention(alert.rule.priority == .critical ? .criticalRequest : .informationalRequest)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = panel.frame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - frame.height - 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
