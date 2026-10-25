import AppKit
import FileProviderUI
import WesomeCloudShared

/// Finder's Sign In action hands recovery to the app, where existing credentials
/// are tried before an account login is requested.
open class FinderRecoveryViewController: FPUIActionExtensionViewController {
    private let status = NSTextField(wrappingLabelWithString: "Opening WesomeCloud to reconnect Finder…")
    private var hasOpenedApp = false

    open override func loadView() {
        let button = NSButton(title: "Open WesomeCloud", target: self, action: #selector(openApp))
        let stack = NSStackView(views: [status, button])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 130)
        view = stack
    }

    open override func prepare(forError error: Error) {
        loadViewIfNeeded()
    }

    open override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasOpenedApp else { return }
        hasOpenedApp = true
        openApp()
    }

    @objc private func openApp() {
        if NSWorkspace.shared.open(FinderRecovery.url) {
            extensionContext.completeRequest()
        } else {
            status.stringValue = "WesomeCloud could not open. Open the app from Applications to reconnect Finder."
        }
    }
}
