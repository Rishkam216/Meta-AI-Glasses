import AgentCore
import Foundation
import Testing
@testable import MacRuntime

@Test func mapsForegroundAppWithoutAccessibilityPermission() async throws {
    let tool = FrontmostAppTool(read: {
        FrontmostApp(processID: 42, bundleIdentifier: "com.apple.Safari", name: "Safari")
    })
    let output = try await tool.execute(EmptyInput())
    #expect(output.processID == 42)
    #expect(output.bundleIdentifier == "com.apple.Safari")
    #expect(output.name == "Safari")
    #expect(tool.descriptor.permissions.isEmpty)
}

@Test func noForegroundAppHasStructuredFailure() async throws {
    let tool = FrontmostAppTool(read: { nil })
    do {
        _ = try await tool.execute(EmptyInput())
        Issue.record("Expected unavailable error")
    } catch let error as ToolFailure {
        #expect(error.code == .unavailable)
        #expect(error.retryable)
    }
}

// An opt-in integration test: CI often has no interactive desktop.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MAC_GUI_TESTS"] == "1"))
func nativeForegroundAppSmokeTest() async throws {
    let output = try await FrontmostAppTool().execute(EmptyInput())
    #expect(output.processID > 0)
}
