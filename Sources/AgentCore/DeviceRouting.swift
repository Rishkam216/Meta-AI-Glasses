import Foundation

/// Metadata is for display/diagnostics only. Routing decisions use device ID and
/// advertised capabilities, never hard-coded operating-system pairings.
public struct DeviceIdentity: Codable, Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let platform: String

    public init(id: UUID = UUID(), displayName: String, platform: String) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
    }
}

public struct DeviceSnapshot: Sendable {
    public let identity: DeviceIdentity
    public let capabilities: [ToolDescriptor]

    public init(identity: DeviceIdentity, capabilities: [ToolDescriptor]) {
        self.identity = identity
        self.capabilities = capabilities
    }
}

public protocol DeviceExecuting: Sendable {
    var identity: DeviceIdentity { get }
    func capabilities() async -> [ToolDescriptor]
    func execute(_ request: ToolRequest) async -> ToolResult
}

/// Adapts a local ToolRuntime to the same logical device boundary a future
/// encrypted remote executor will implement.
public struct RuntimeDeviceExecutor: DeviceExecuting {
    public let identity: DeviceIdentity
    private let runtime: ToolRuntime

    public init(identity: DeviceIdentity, runtime: ToolRuntime) {
        self.identity = identity
        self.runtime = runtime
    }

    public func capabilities() async -> [ToolDescriptor] {
        await runtime.catalog()
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        await runtime.execute(request)
    }
}

public enum DeviceRoutingError: Error, Sendable, Equatable {
    case duplicateDevice(UUID)
    case unknownDevice(UUID)
    case capabilityUnavailable(deviceID: UUID, tool: String)
}

/// In-memory routing directory. This deliberately has no network transport yet.
/// A caller chooses a device explicitly or first asks for capability candidates.
public actor DeviceRouter {
    private var executors: [UUID: any DeviceExecuting] = [:]

    public init() {}

    public func register(_ executor: any DeviceExecuting) throws {
        let id = executor.identity.id
        guard executors[id] == nil else { throw DeviceRoutingError.duplicateDevice(id) }
        executors[id] = executor
    }

    public func unregister(_ deviceID: UUID) {
        executors.removeValue(forKey: deviceID)
    }

    public func snapshots() async -> [DeviceSnapshot] {
        // Copy the actor-isolated collection before awaiting remote/dynamic
        // capability calls so reentrancy cannot mutate the dictionary mid-iteration.
        let current = Array(executors.values)
        var values: [DeviceSnapshot] = []
        values.reserveCapacity(current.count)
        for executor in current {
            values.append(DeviceSnapshot(identity: executor.identity,
                                         capabilities: await executor.capabilities()))
        }
        return values.sorted { $0.identity.id.uuidString < $1.identity.id.uuidString }
    }

    public func candidates(for tool: String) async -> [DeviceSnapshot] {
        let all = await snapshots()
        return all.filter { snapshot in
            snapshot.capabilities.contains { $0.name == tool }
        }
    }

    public func route(tool: String, arguments: JSONValue = .object([:]),
                      to deviceID: UUID, sessionID: UUID,
                      approvalID: UUID? = nil) async throws -> ToolResult {
        guard let executor = executors[deviceID] else {
            throw DeviceRoutingError.unknownDevice(deviceID)
        }

        let capabilities = await executor.capabilities()
        guard capabilities.contains(where: { $0.name == tool }) else {
            throw DeviceRoutingError.capabilityUnavailable(deviceID: deviceID, tool: tool)
        }

        let request = ToolRequest(
            tool: tool,
            arguments: arguments,
            context: RequestContext(deviceID: deviceID, sessionID: sessionID),
            approvalID: approvalID
        )
        return await executor.execute(request)
    }
}
