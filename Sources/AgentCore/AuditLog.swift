import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct AuditEvent: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case started, completed }
    public let timestamp: Date
    public let requestID: UUID
    public let tool: String
    public let risk: RiskLevel?
    public let phase: Phase
    public let status: ToolResult.Status?
    public let errorCode: ErrorCode?

    init(request: ToolRequest, risk: RiskLevel?, phase: Phase, result: ToolResult? = nil) {
        timestamp = Date(); requestID = request.id; tool = request.tool
        self.risk = risk; self.phase = phase
        status = result?.status; errorCode = result?.error?.code
    }
}

public protocol AuditSink: Sendable {
    func append(_ event: AuditEvent) async throws
}

/// Local metadata only. No arguments, results, window titles, or credentials.
public actor FileAuditLog: AuditSink {
    private let file: FileHandle

    /// Parent must already exist. Refuse symlink targets; require a regular file.
    public init(url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw POSIXError(.EACCES)
        }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public func append(_ event: AuditEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)
        try file.write(contentsOf: data)
        try file.synchronize()
    }
}
