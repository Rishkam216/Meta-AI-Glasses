import AgentCore
import ApplicationServices
import CoreGraphics

public struct MacPermissions: PermissionChecking {
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
