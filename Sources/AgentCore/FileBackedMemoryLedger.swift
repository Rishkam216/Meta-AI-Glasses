import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum MemoryPersistenceError: Error, Sendable, Equatable {
    case invalidMaximumSize
    case invalidPath
    case insecureDirectory
    case unsafeFile
    case fileTooLarge
    case corruptFile
    case unsupportedVersion(Int)
    case missingFile
    case busy
    case ioFailure
    /// Rename succeeded, but directory fsync failed. Re-read before retrying.
    case commitOutcomeUnknown
}

private struct MemoryFileEnvelope: Codable {
    let version: Int
    let principal: TenantContext
    let snapshot: PortableMemoryExport
}

/// Local/offline durable ledger, bound to exactly one authenticated principal.
/// Use a different URL for each principal, in an existing owner-only directory.
/// This is not the cloud database or a replacement for server-side row isolation.
/// Reads can throw: corrupt or unavailable storage must not look like empty memory.
public actor FileBackedMemoryLedger: MemoryServiceLedger {
    private let principal: TenantContext
    private let file: LockedMemoryFile

    public init(url: URL, principal: TenantContext, maxFileBytes: Int = 64 * 1_024 * 1_024) throws {
        self.principal = principal
        let file = try LockedMemoryFile(url: url, maxFileBytes: maxFileBytes)
        self.file = file
        try file.withLock {
            if let data = try file.read() {
                _ = try Self.decode(data, as: principal)
            } else {
                try Self.save(MemoryLedgerState(), as: principal, to: file)
            }
        }
    }

    public func insert(_ record: MemoryRecord, as principal: TenantContext) throws {
        try mutate(as: principal) { try $0.insert(record, as: principal) }
    }

    public func memory(id: UUID, as principal: TenantContext) throws -> MemoryRecord? {
        try read(as: principal) { $0.memory(id: id, as: principal) }
    }

    public func query(_ query: MemoryLedgerQuery, as principal: TenantContext) throws -> [MemoryRecord] {
        try read(as: principal) { $0.query(query, as: principal) }
    }

    public func supersede(with record: MemoryRecord, as principal: TenantContext,
                          at timestamp: Date = Date()) throws {
        try mutate(as: principal) { try $0.supersede(with: record, as: principal, at: timestamp) }
    }

    public func setProviderMapping(_ mapping: MemoryProviderMapping, as principal: TenantContext) throws {
        try mutate(as: principal) { try $0.setProviderMapping(mapping, as: principal) }
    }

    public func providerMappings(memoryID: UUID, as principal: TenantContext) throws -> [MemoryProviderMapping] {
        try read(as: principal) { $0.providerMappings(memoryID: memoryID, as: principal) }
    }

    public func export(as principal: TenantContext, at timestamp: Date = Date()) throws -> PortableMemoryExport {
        try read(as: principal) { $0.export(as: principal, at: timestamp) }
    }

    public func forget(id: UUID, as principal: TenantContext, at timestamp: Date = Date()) throws {
        try mutate(as: principal) { try $0.forget(id: id, as: principal, at: timestamp) }
    }

    public func enrollProviders(_ providers: Set<String>, as principal: TenantContext) throws {
        try mutate(as: principal) { try $0.enrollProviders(providers, as: principal) }
    }
    public func remember(_ record: MemoryRecord, replacing: Bool, providers: Set<String>,
                         as principal: TenantContext, at timestamp: Date) throws {
        try mutate(as: principal) { try $0.remember(record, replacing: replacing, providers: providers, as: principal, at: timestamp) }
    }
    public func forget(id: UUID, providers: Set<String>, as principal: TenantContext, at timestamp: Date) throws {
        try mutate(as: principal) { try $0.forget(id: id, providers: providers, as: principal, at: timestamp) }
    }
    public func markAttempt(_ entry: MemorySyncEntry, as principal: TenantContext, at timestamp: Date) throws -> Bool {
        try mutate(as: principal) { try $0.markAttempt(entry, as: principal, at: timestamp) }
    }
    public func acknowledge(_ entry: MemorySyncEntry, providerMemoryID: String?,
                            as principal: TenantContext, at timestamp: Date) throws -> Bool {
        try mutate(as: principal) { try $0.acknowledge(entry, providerMemoryID: providerMemoryID, as: principal, at: timestamp) }
    }

    private func read<T: Sendable>(as caller: TenantContext, _ body: @Sendable (MemoryLedgerState) throws -> T) throws -> T {
        guard caller == principal else { throw MemoryLedgerError.ownershipMismatch }
        return try file.withLock {
            guard let data = try file.read() else { throw MemoryPersistenceError.missingFile }
            return try body(Self.decode(data, as: principal))
        }
    }

    private func mutate<T: Sendable>(as caller: TenantContext, _ body: @Sendable (inout MemoryLedgerState) throws -> T) throws -> T {
        guard caller == principal else { throw MemoryLedgerError.ownershipMismatch }
        return try file.withLock {
            guard let data = try file.read() else { throw MemoryPersistenceError.missingFile }
            var state = try Self.decode(data, as: principal)
            let result = try body(&state)
            try Self.save(state, as: principal, to: file)
            return result
        }
    }

    private static func decode(_ data: Data, as principal: TenantContext) throws -> MemoryLedgerState {
        let envelope: MemoryFileEnvelope
        do { envelope = try JSONDecoder().decode(MemoryFileEnvelope.self, from: data) }
        catch { throw MemoryPersistenceError.corruptFile }
        guard envelope.version == 1 else { throw MemoryPersistenceError.unsupportedVersion(envelope.version) }
        guard envelope.principal == principal else { throw MemoryLedgerError.ownershipMismatch }
        do { return try MemoryLedgerState(restoring: envelope.snapshot, as: principal) }
        catch let error as MemoryPersistenceError { throw error }
        catch { throw MemoryPersistenceError.corruptFile }
    }

    private static func save(_ state: MemoryLedgerState, as principal: TenantContext,
                             to file: LockedMemoryFile) throws {
        let envelope = MemoryFileEnvelope(version: 1, principal: principal,
                                          snapshot: state.export(as: principal, at: Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Foundation's numeric date representation preserves fractional seconds.
        try file.replace(with: encoder.encode(envelope))
    }
}

/// All operations are synchronous and hold the advisory lock without suspension.
/// Directory-relative syscalls pin the directory and refuse symlink traversal.
/// The lock file must never be unlinked while this store is in use.
final class LockedMemoryFile: Sendable {
    private let directoryFD: Int32
    private let name: String
    private let maxFileBytes: Int

    init(url: URL, maxFileBytes: Int) throws {
        guard maxFileBytes > 0 else { throw MemoryPersistenceError.invalidMaximumSize }
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              !url.hasDirectoryPath, !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw MemoryPersistenceError.invalidPath
        }
        self.name = url.lastPathComponent
        self.maxFileBytes = maxFileBytes
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MemoryPersistenceError.ioFailure }
        do {
            for part in url.deletingLastPathComponent().pathComponents where part != "/" {
                guard part != ".", part != ".." else { throw MemoryPersistenceError.invalidPath }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw MemoryPersistenceError.insecureDirectory }
                close(fd)
                fd = next
            }
            try Self.prepareFreshDirectoryIfNeeded(fd, stateName: name)
        } catch {
            close(fd)
            throw error
        }
        directoryFD = fd
    }

    deinit { close(directoryFD) }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try Self.validateDirectory(directoryFD)
        let fd = openat(directoryFD, name + ".lock",
                        O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MemoryPersistenceError.unsafeFile }
        defer { close(fd) }
        try Self.validateFile(fd)
        // Do not block Swift's cooperative executor waiting for another process.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw MemoryPersistenceError.busy }
            throw MemoryPersistenceError.ioFailure
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    func read() throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw MemoryPersistenceError.unsafeFile
        }
        defer { close(fd) }
        let info = try Self.validateFile(fd)
        guard info.st_size > 0 else { throw MemoryPersistenceError.corruptFile }
        guard info.st_size <= off_t(maxFileBytes) else { throw MemoryPersistenceError.fileTooLarge }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Self.posixRead(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MemoryPersistenceError.ioFailure }
                offset += count
            }
        }
        return data
    }

    func replace(with data: Data) throws {
        guard data.count <= maxFileBytes else { throw MemoryPersistenceError.fileTooLarge }
        // Refuse a substituted symlink, hard link, device, or public file.
        _ = try read()
        let temporary = ".memory-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MemoryPersistenceError.ioFailure }
        defer {
            close(fd)
            _ = unlinkat(directoryFD, temporary, 0)
        }
        try Self.validateFile(fd)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MemoryPersistenceError.ioFailure }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw MemoryPersistenceError.ioFailure }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else {
            throw MemoryPersistenceError.ioFailure
        }
        guard fsync(directoryFD) == 0 else { throw MemoryPersistenceError.commitOutcomeUnknown }
    }

    /// Foundation does not guarantee that requested POSIX permissions survive
    /// directory creation identically on every supported platform. A brand-new
    /// owner-owned directory can be tightened before any state is trusted.
    /// Existing stores are never auto-repaired: permission drift after state or
    /// lock creation still fails closed.
    private static func prepareFreshDirectoryIfNeeded(_ fd: Int32, stateName: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw MemoryPersistenceError.insecureDirectory
        }
        if (info.st_mode & 0o077) == 0 { return }
        guard !entryExists(fd, name: stateName),
              !entryExists(fd, name: stateName + ".lock"),
              fchmod(fd, mode_t(0o700)) == 0 else {
            throw MemoryPersistenceError.insecureDirectory
        }
        try validateDirectory(fd)
    }

    private static func entryExists(_ directoryFD: Int32, name: String) -> Bool {
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        return errno != ENOENT
    }

    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
            throw MemoryPersistenceError.insecureDirectory
        }
    }

    @discardableResult
    private static func validateFile(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
            throw MemoryPersistenceError.unsafeFile
        }
        return info
    }

    private static func posixRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #else
        Glibc.read(fd, buffer, count)
        #endif
    }
}
