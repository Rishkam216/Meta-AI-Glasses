import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ContextPersistenceError: Error, Sendable, Equatable {
    case invalidMaximumSize
    case invalidParentDirectory
    case pathIsSymlink
    case notRegularFile
    case wrongOwner
    case fileTooLarge
    case corruptFile
    case unsupportedVersion(Int)
    case duplicateItemID
    case ioFailure
}

private struct ContextFileEnvelope: Codable {
    static let currentVersion = 1

    let version: Int
    let items: [ContextItem]
}

/// Durable local/offline ContextStoring implementation.
///
/// This is intentionally a local-device reference store, not the future cloud
/// multi-tenant database. Cloud persistence must additionally enforce tenant
/// isolation at the database layer (for example, row-level security).
///
/// Mutations are written as a complete atomic snapshot in the same directory:
/// create a new 0600 regular file, fsync it, then rename it over the old state.
/// In-memory state is changed only after the rename succeeds. The parent
/// directory must already exist, be owned by the current user, and not be a
/// symlink. The state file itself is always opened with O_NOFOLLOW.
public actor FileBackedContextService: ContextStoring {
    private let url: URL
    private let freshnessPolicy: ContextFreshnessPolicy
    private let maxFileBytes: Int
    private var itemsByPrincipal: [TenantContext: [UUID: ContextItem]]

    public init(url: URL,
                freshnessPolicy: ContextFreshnessPolicy = try! ContextFreshnessPolicy(),
                maxFileBytes: Int = 64 * 1_024 * 1_024) throws {
        guard maxFileBytes > 0 else {
            throw ContextPersistenceError.invalidMaximumSize
        }
        self.url = url
        self.freshnessPolicy = freshnessPolicy
        self.maxFileBytes = maxFileBytes
        try Self.validateParent(of: url)
        itemsByPrincipal = try Self.load(from: url, maxFileBytes: maxFileBytes)
    }

    public func put(_ item: ContextItem, as principal: TenantContext) throws {
        guard item.isOwned(by: principal) else {
            throw ContextServiceError.ownershipMismatch
        }

        var next = itemsByPrincipal
        next[principal, default: [:]][item.id] = item
        try persist(next)
        itemsByPrincipal = next
    }

    public func get(_ id: UUID, as principal: TenantContext) -> ContextItem? {
        itemsByPrincipal[principal]?[id]
    }

    public func query(_ query: ContextQuery, as principal: TenantContext,
                      now: Date = Date()) -> [ContextItem] {
        guard let partition = itemsByPrincipal[principal] else { return [] }
        return orderedContextItems(
            partition.values,
            matching: query,
            freshnessPolicy: freshnessPolicy,
            now: now
        )
    }

    @discardableResult
    public func remove(_ id: UUID, as principal: TenantContext) throws -> Bool {
        guard var partition = itemsByPrincipal[principal],
              partition.removeValue(forKey: id) != nil else {
            return false
        }

        var next = itemsByPrincipal
        if partition.isEmpty {
            next.removeValue(forKey: principal)
        } else {
            next[principal] = partition
        }
        try persist(next)
        itemsByPrincipal = next
        return true
    }

    public func removeAll(as principal: TenantContext) throws {
        guard itemsByPrincipal[principal] != nil else { return }
        var next = itemsByPrincipal
        next.removeValue(forKey: principal)
        try persist(next)
        itemsByPrincipal = next
    }

    public func count(as principal: TenantContext) -> Int {
        itemsByPrincipal[principal]?.count ?? 0
    }

    private func persist(_ state: [TenantContext: [UUID: ContextItem]]) throws {
        try Self.validateParent(of: url)
        try Self.refuseSymlinkTarget(url)

        let items = state.values.flatMap { $0.values }.sorted(by: Self.itemOrder)
        let envelope = ContextFileEnvelope(
            version: ContextFileEnvelope.currentVersion,
            items: items
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maxFileBytes else {
            throw ContextPersistenceError.fileTooLarge
        }

        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        let fd = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else { throw ContextPersistenceError.ioFailure }

        var shouldRemoveTemporary = true
        defer {
            close(fd)
            if shouldRemoveTemporary {
                unlink(temporary.path)
            }
        }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              fchmod(fd, 0o600) == 0 else {
            throw ContextPersistenceError.ioFailure
        }

        try Self.writeAll(data, to: fd)
        guard fsync(fd) == 0 else { throw ContextPersistenceError.ioFailure }

        #if canImport(Darwin)
        let renameResult = Darwin.rename(temporary.path, url.path)
        #else
        let renameResult = Glibc.rename(temporary.path, url.path)
        #endif
        guard renameResult == 0 else { throw ContextPersistenceError.ioFailure }
        shouldRemoveTemporary = false

        // Best-effort parent fsync strengthens rename durability. A platform may
        // reject directory fsync; the file rename has already completed, so do
        // not report a false failure after the durable state became visible.
        let directoryFD = open(parent.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            close(directoryFD)
        }
    }

    private static func load(from url: URL,
                             maxFileBytes: Int) throws -> [TenantContext: [UUID: ContextItem]] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [:] }
            if errno == ELOOP { throw ContextPersistenceError.pathIsSymlink }
            throw ContextPersistenceError.ioFailure
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ContextPersistenceError.ioFailure
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ContextPersistenceError.notRegularFile
        }
        guard info.st_uid == geteuid() else {
            throw ContextPersistenceError.wrongOwner
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw ContextPersistenceError.ioFailure
        }
        guard info.st_size >= 0, info.st_size <= off_t(maxFileBytes) else {
            throw ContextPersistenceError.fileTooLarge
        }
        guard info.st_size > 0 else {
            throw ContextPersistenceError.corruptFile
        }

        let data = try readAll(from: fd, byteCount: Int(info.st_size))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: ContextFileEnvelope
        do {
            envelope = try decoder.decode(ContextFileEnvelope.self, from: data)
        } catch {
            throw ContextPersistenceError.corruptFile
        }
        guard envelope.version == ContextFileEnvelope.currentVersion else {
            throw ContextPersistenceError.unsupportedVersion(envelope.version)
        }

        var state: [TenantContext: [UUID: ContextItem]] = [:]
        for item in envelope.items {
            if state[item.tenant]?[item.id] != nil {
                throw ContextPersistenceError.duplicateItemID
            }
            state[item.tenant, default: [:]][item.id] = item
        }
        return state
    }

    private static func validateParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var info = stat()
        guard lstat(parent.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw ContextPersistenceError.invalidParentDirectory
        }
    }

    private static func refuseSymlinkTarget(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw ContextPersistenceError.pathIsSymlink
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw ContextPersistenceError.notRegularFile
            }
            guard info.st_uid == geteuid() else {
                throw ContextPersistenceError.wrongOwner
            }
            return
        }
        guard errno == ENOENT else { throw ContextPersistenceError.ioFailure }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ContextPersistenceError.ioFailure }
                offset += written
            }
        }
    }

    private static func readAll(from fd: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        let completed = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return byteCount == 0 }
            var offset = 0
            while offset < byteCount {
                let amount = read(fd, base.advanced(by: offset), byteCount - offset)
                if amount < 0, errno == EINTR { continue }
                if amount <= 0 { return false }
                offset += amount
            }
            return true
        }
        guard completed else { throw ContextPersistenceError.ioFailure }
        return data
    }

    private static func itemOrder(_ lhs: ContextItem, _ rhs: ContextItem) -> Bool {
        let left = principalOrderKey(lhs.tenant)
        let right = principalOrderKey(rhs.tenant)
        if left != right { return left.lexicographicallyPrecedes(right) }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func principalOrderKey(_ principal: TenantContext) -> [String] {
        [
            principal.tenantID.uuidString,
            principal.userID.uuidString,
            principal.accountID?.uuidString ?? ""
        ]
    }
}
