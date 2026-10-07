import AppKit
import SwiftUI

/// Manages the single settings window.
class SettingsController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 420)
        window.center()
        window.setFrameAutosaveName("GhosttySettings")
        self.init(window: window)
        window.delegate = self
    }

    func show(_ ghostty: Ghostty.App) {
        guard let window else { return }

        // The model is created each time the window opens so it starts from
        // the current files and released when the window closes.
        if window.contentViewController == nil {
            let model = SettingsModel(ghostty: ghostty)
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            hosting.sizingOptions = [.minSize]
            let frame = window.frame
            window.contentViewController = hosting
            window.setFrame(frame, display: false)
        }

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }

    // MARK: First Responder

    @IBAction func find(_ sender: Any?) {
        guard let window, let field = window.contentView?.firstDescendant(withClassName: "NSSearchField") else { return }
        window.makeFirstResponder(field)
    }

    @IBAction func close(_ sender: Any) {
        window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        window?.performClose(sender)
    }
}
