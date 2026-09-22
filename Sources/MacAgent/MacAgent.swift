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
    private var runtime: ToolRuntime?
    private var window: NSWindow?
    private var output: NSTextView?
    private var inspectItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var inspectTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Agent"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "Meta AI Glasses · Runtime 0.1", action: nil, keyEquivalent: "")
        let inspect = NSMenuItem(title: "Inspect frontmost app in 3 seconds", action: #selector(inspectFrontmost), keyEquivalent: "")
        inspect.target = self
        inspect.isEnabled = false
        inspectItem = inspect
        menu.addItem(inspect)
        menu.addItem(.separator())
        let permission = NSMenuItem(title: "Accessibility: checking", action: nil, keyEquivalent: "")
        permissionItem = permission
        menu.addItem(permission)
        let request = NSMenuItem(title: "Request Accessibility permission…", action: #selector(requestAccessibility), keyEquivalent: "")
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

        Task {
            do {
                runtime = try await MacRuntimeFactory.make()
                inspect.isEnabled = true
            } catch {
                showResult("Runtime could not start: \(error)\nNo tools are enabled.")
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        permissionItem?.title = MacPermissions.accessibilityGranted
            ? "Accessibility: granted" : "Accessibility: not granted (first tool does not need it)"
    }

    @objc private func requestAccessibility() {
        MacPermissions.requestAccessibility()
    }

    @objc private func showAuditFolder() {
        NSWorkspace.shared.open(MacRuntimeFactory.auditDirectory)
    }

    @objc private func inspectFrontmost() {
        guard let runtime, inspectTask == nil else { return }
        inspectItem?.isEnabled = false
        statusItem?.button?.title = "Agent · 3s"
        inspectTask = Task {
            defer {
                inspectTask = nil
                inspectItem?.isEnabled = true
                statusItem?.button?.title = "Agent"
            }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            let result = await runtime.execute(ToolRequest(tool: "ui.get_frontmost_app"))
            do {
                showResult(String(decoding: try result.json(pretty: true), as: UTF8.self))
            } catch {
                showResult("Could not encode the tool result.")
            }
        }
    }

    private func showResult(_ text: String) {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
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
            window = panel
            output = view
        }
        output?.string = text
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
