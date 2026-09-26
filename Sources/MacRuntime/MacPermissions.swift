import AgentCore
import ApplicationServices
import CoreGraphics

public struct MacPermissions: PermissionChecking {
    private static let accessibilityPromptOptionKey = "AXTrustedCheckOptionPrompt"

    public init() {}

    public func isGranted(_ permission: Permission) async -> Bool {
        await MainActor.run {
            switch permission {
            case .accessibility: AXIsProcessTrusted()
            case .screenRecording: CGPreflightScreenCaptureAccess()
            }
        }
    }

    @MainActor
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Only the local menu action calls this. A tool request cannot trigger it.
    /// Prompting is asynchronous; this return value is not an approval.
    @MainActor
    public static func requestAccessibility() {
        // The C SDK exposes kAXTrustedCheckOptionPrompt as mutable global state,
        // which Swift 6 strict concurrency rejects even on MainActor. Its public
        // dictionary key is stable, so use the key value without touching that global.
        let options = [accessibilityPromptOptionKey: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
