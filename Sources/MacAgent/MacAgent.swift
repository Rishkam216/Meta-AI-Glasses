import AgentCore
import AppKit
import MacRuntime

@main
@MainActor
enum MacAgent {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var controller: RealtimeAppSessionController?

    private var resultWindow: NSWindow?
    private var resultOutput: NSTextView?

    private var commandWindow: NSWindow?
    private var commandField: NSTextField?
    private var responseView: NSTextView?
    private var realtimeStatusLabel: NSTextField?
    private var sendButton: NSButton?

    private var openAgentItem: NSMenuItem?
    private var inspectItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var inspectTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Agent"

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "Meta AI Glasses · Runtime 0.2", action: nil, keyEquivalent: "")

        let openAgent = NSMenuItem(
            title: "Open Agent…",
            action: #selector(openRealtimeAgent),
            keyEquivalent: ""
        )
        openAgent.target = self
        openAgent.isEnabled = false
        openAgentItem = openAgent
        menu.addItem(openAgent)

        let inspect = NSMenuItem(
            title: "Inspect frontmost app in 3 seconds",
            action: #selector(inspectFrontmost),
            keyEquivalent: ""
        )
        inspect.target = self
        inspect.isEnabled = false
        inspectItem = inspect
        menu.addItem(inspect)

        menu.addItem(.separator())

        let permission = NSMenuItem(title: "Accessibility: checking", action: nil, keyEquivalent: "")
        permissionItem = permission
        menu.addItem(permission)

        let request = NSMenuItem(
            title: "Request Accessibility permission…",
            action: #selector(requestAccessibility),
            keyEquivalent: ""
        )
        request.target = self
        menu.addItem(request)

        let audit = NSMenuItem(title: "Show audit folder", action: #selector(showAuditFolder), keyEquivalent: "")
        audit.target = self
        menu.addItem(audit)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)

        status.menu = menu
        statusItem = status

        let controller = RealtimeAppSessionController()
        self.controller = controller
        Task {
            do {
                try await controller.start()
                openAgent.isEnabled = true
                inspect.isEnabled = true
                status.button?.title = "Agent"
            } catch {
                status.button?.title = "Agent · error"
                showResult("Runtime could not start: \(friendlyMessage(error))\nNo agent tools are enabled.")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        inspectTask?.cancel()
        realtimeTask?.cancel()
        if let controller {
            Task { await controller.close() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        permissionItem?.title = MacPermissions.accessibilityGranted
            ? "Accessibility: granted"
            : "Accessibility: not granted (current read/open-app slice does not need it)"
    }

    @objc private func requestAccessibility() {
        MacPermissions.requestAccessibility()
    }

    @objc private func showAuditFolder() {
        NSWorkspace.shared.open(MacRuntimeFactory.auditDirectory)
    }

    @objc private func openRealtimeAgent() {
        ensureCommandWindow()
        commandWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        commandField?.becomeFirstResponder()

        guard let controller else { return }
        Task { [weak self] in
            guard let self else { return }
            let signedIn = await controller.hasAgentSession()
            self.realtimeStatusLabel?.stringValue = signedIn
                ? "Authenticated agent session found. Read actions run directly; write actions require local approval."
                : "Sign in first: no valid agent session is stored in Keychain."
            self.sendButton?.isEnabled = signedIn && self.realtimeTask == nil
        }
    }

    @objc private func sendRealtimeTurn() {
        guard realtimeTask == nil,
              let controller,
              let commandField else { return }

        let text = commandField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            realtimeStatusLabel?.stringValue = "Enter a command first."
            return
        }

        sendButton?.isEnabled = false
        commandField.isEnabled = false
        realtimeStatusLabel?.stringValue = "Running…"
        statusItem?.button?.title = "Agent · running"

        realtimeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.realtimeTask = nil
                self.sendButton?.isEnabled = true
                self.commandField?.isEnabled = true
                self.statusItem?.button?.title = "Agent"
            }

            do {
                let result = try await controller.run(text: text)
                let assistant = result.assistantText.joined()
                self.responseView?.string = assistant.isEmpty
                    ? "The turn completed without assistant text."
                    : assistant
                self.realtimeStatusLabel?.stringValue = result.toolResults.isEmpty
                    ? "Completed."
                    : "Completed · \(result.toolResults.count) tool call(s)."
                self.commandField?.stringValue = ""
            } catch is CancellationError {
                self.realtimeStatusLabel?.stringValue = "Cancelled."
            } catch {
                self.responseView?.string = ""
                self.realtimeStatusLabel?.stringValue = self.friendlyMessage(error)
            }
        }
    }

    @objc private func inspectFrontmost() {
        guard let controller, inspectTask == nil else { return }
        inspectItem?.isEnabled = false
        statusItem?.button?.title = "Agent · 3s"

        inspectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.inspectTask = nil
                self.inspectItem?.isEnabled = true
                self.statusItem?.button?.title = "Agent"
            }

            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }

            guard let result = await controller.inspectFrontmost() else {
                self.showResult("Runtime is not ready.")
                return
            }
            do {
                self.showResult(String(decoding: try result.json(pretty: true), as: UTF8.self))
            } catch {
                self.showResult("Could not encode the tool result.")
            }
        }
    }

    private func ensureCommandWindow() {
        guard commandWindow == nil else { return }

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Personal Agent · Realtime Text"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 620, height: 420)

        guard let content = panel.contentView else { return }

        let authLabel = NSTextField(labelWithString: "Authentication: opaque agent session from Keychain · Realtime credential is minted by the backend")
        authLabel.frame = NSRect(x: 20, y: 452, width: 680, height: 20)
        authLabel.textColor = .secondaryLabelColor
        authLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(authLabel)

        let commandLabel = NSTextField(labelWithString: "Command")
        commandLabel.frame = NSRect(x: 20, y: 414, width: 680, height: 20)
        commandLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(commandLabel)

        let input = NSTextField(frame: NSRect(x: 20, y: 378, width: 590, height: 30))
        input.placeholderString = "Example: What app is active? or Open TextEdit"
        input.autoresizingMask = [.width, .minYMargin]
        input.target = self
        input.action = #selector(sendRealtimeTurn)
        commandField = input
        content.addSubview(input)

        let send = NSButton(frame: NSRect(x: 620, y: 378, width: 80, height: 30))
        send.title = "Send"
        send.bezelStyle = .rounded
        send.target = self
        send.action = #selector(sendRealtimeTurn)
        send.autoresizingMask = [.minXMargin, .minYMargin]
        send.isEnabled = false
        sendButton = send
        content.addSubview(send)

        let status = NSTextField(labelWithString: "Checking agent session…")
        status.frame = NSRect(x: 20, y: 346, width: 680, height: 22)
        status.textColor = .secondaryLabelColor
        status.autoresizingMask = [.width, .minYMargin]
        realtimeStatusLabel = status
        content.addSubview(status)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 680, height: 316))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let response = NSTextView(frame: scroll.bounds)
        response.isEditable = false
        response.isSelectable = true
        response.isVerticallyResizable = true
        response.autoresizingMask = [.width]
        response.textContainer?.widthTracksTextView = true
        response.font = .systemFont(ofSize: 14)
        response.textContainerInset = NSSize(width: 12, height: 12)
        response.string = "Assistant responses will appear here."
        scroll.documentView = response
        responseView = response
        content.addSubview(scroll)

        panel.center()
        commandWindow = panel
    }

    private func showResult(_ text: String) {
        if resultWindow == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Mac Runtime · Tool Result"
            panel.isReleasedWhenClosed = false

            let scroll = NSScrollView(frame: panel.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true

            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false
            view.isSelectable = true
            view.isVerticallyResizable = true
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            view.textContainerInset = NSSize(width: 16, height: 16)
            scroll.documentView = view
            panel.contentView?.addSubview(scroll)
            panel.center()
            resultWindow = panel
            resultOutput = view
        }

        resultOutput?.string = text
        resultWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func friendlyMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }

        if let provider = error as? OpenAIRealtimeError {
            switch provider {
            case .invalidCredential, .credentialUnavailable:
                return "The short-lived realtime credential is unavailable or invalid."
            case .handshakeTimeout:
                return "The realtime connection timed out during setup."
            case .handshakeFailed:
                return "The realtime connection could not be established."
            case .providerFailure(let code):
                return "OpenAI Realtime returned an error (\(code))."
            default:
                return "The realtime provider returned an invalid or unavailable response."
            }
        }

        if let protocolError = error as? RealtimeProtocolError {
            switch protocolError {
            case .providerEventLimitExceeded, .assistantTextLimitExceeded:
                return "The response exceeded this turn's limit. Start a new turn."
            case .providerClosed:
                return "The realtime connection closed before the turn finished."
            case .providerFailure(let code):
                return "The realtime provider returned an error (\(code))."
            default:
                return "The realtime turn failed its local protocol checks."
            }
        }

        return "The agent turn failed."
    }
}
