import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// A per-provider, bounded, private, atomically replaced last-good cache.
///
/// Every filesystem traversal is descriptor-relative below an injected Application Support
/// directory. Cache entries and directory components are opened without following symlinks.
public actor ProviderQuotaDiskCache: ProviderQuotaCache {
    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)
    private static let permissionMask = mode_t(0o7777)

    private let configuration: ProviderQuotaDiskCacheConfiguration
    private let now: @Sendable () -> Date
    private var acceptsOperations = true

    public init(
        configuration: ProviderQuotaDiskCacheConfiguration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
    }

    public func load(providerID: ProviderID) async -> ProviderQuotaCacheLoadResult {
        guard acceptsOperations else {
            return .failure(ProviderQuotaCacheFailure.shutdown())
        }

        do {
            let directoryDescriptor = try openCacheDirectory()
            defer { Darwin.close(directoryDescriptor) }

            let fileName = Self.cacheFileName(for: providerID)
            switch try inspectEntry(
                named: fileName,
                in: directoryDescriptor,
                enforceByteLimit: true
            ) {
            case .missing:
                return .miss
            case .regular:
                break
            }

            let data = try readEntry(
                named: fileName,
                in: directoryDescriptor,
                byteLimit: configuration.maximumFileBytes
            )
            let envelope: ProviderQuotaCacheEnvelopeDTO
            do {
                envelope = try Self.decoder().decode(
                    ProviderQuotaCacheEnvelopeDTO.self,
                    from: data
                )
            } catch {
                throw ProviderQuotaCacheFailure.corrupt("cache.read.decode_invalid")
            }

            do {
                return .hit(try envelope.domain(requestedProviderID: providerID))
            } catch ProviderQuotaCacheEnvelopeValidationError.unknownSchema {
                throw ProviderQuotaCacheFailure.unsupportedSchema(
                    "cache.read.unknown_schema"
                )
            } catch ProviderQuotaCacheEnvelopeValidationError.unknownVersion {
                throw ProviderQuotaCacheFailure.unsupportedSchema(
                    "cache.read.unknown_version"
                )
            } catch ProviderQuotaCacheEnvelopeValidationError.identityMismatch {
                throw ProviderQuotaCacheFailure.identityMismatch(
                    "cache.read.identity_mismatch"
                )
            } catch ProviderQuotaPersistenceDTOError.invalidIdentity {
                throw ProviderQuotaCacheFailure.identityMismatch(
                    "cache.read.source_identity_mismatch"
                )
            } catch ProviderQuotaPersistenceDTOError.unsafePersistedValue {
                throw ProviderQuotaCacheFailure.corrupt("cache.read.privacy_violation")
            } catch {
                throw ProviderQuotaCacheFailure.corrupt("cache.read.invalid_payload")
            }
        } catch let failure as ProviderFailure {
            return .failure(failure)
        } catch {
            return .failure(ProviderQuotaCacheFailure.unavailable("cache.read.unknown"))
        }
    }

    public func save(_ data: ProviderQuotaData) async -> ProviderQuotaCacheWriteResult {
        guard acceptsOperations else {
            return .failure(ProviderQuotaCacheFailure.shutdown())
        }

        do {
            let envelope: ProviderQuotaCacheEnvelopeDTO
            do {
                envelope = try ProviderQuotaCacheEnvelopeDTO(domain: data)
            } catch ProviderQuotaPersistenceDTOError.invalidIdentity {
                throw ProviderQuotaCacheFailure.identityMismatch(
                    "cache.write.source_identity_mismatch"
                )
            } catch ProviderQuotaPersistenceDTOError.unsafePersistedValue {
                throw ProviderQuotaCacheFailure.rejected("cache.write.privacy_rejected")
            } catch {
                throw ProviderQuotaCacheFailure.rejected("cache.write.invalid_payload")
            }

            let encoded: Data
            do {
                encoded = try Self.encoder().encode(envelope)
            } catch {
                throw ProviderQuotaCacheFailure.rejected("cache.write.encode_failed")
            }
            guard encoded.count <= configuration.maximumFileBytes else {
                throw ProviderQuotaCacheFailure.corrupt("cache.write.oversized")
            }

            let directoryDescriptor = try openCacheDirectory()
            defer { Darwin.close(directoryDescriptor) }
            let fileName = Self.cacheFileName(for: data.providerID)

            // A regular private file may be replaced. Symlinks, devices, pipes, directories,
            // and permissive files are rejected before any destination mutation.
            _ = try inspectEntry(
                named: fileName,
                in: directoryDescriptor,
                enforceByteLimit: false
            )
            try atomicallyReplace(
                entryNamed: fileName,
                with: encoded,
                in: directoryDescriptor
            )
            return .success(writtenAt: now())
        } catch let failure as ProviderFailure {
            return .failure(failure)
        } catch {
            return .failure(ProviderQuotaCacheFailure.unavailable("cache.write.unknown"))
        }
    }

    public func clear(providerID: ProviderID) async -> ProviderQuotaCacheClearResult {
        guard acceptsOperations else {
            return .failure(ProviderQuotaCacheFailure.shutdown())
        }

        do {
            let directoryDescriptor = try openCacheDirectory()
            defer { Darwin.close(directoryDescriptor) }
            let fileName = Self.cacheFileName(for: providerID)

            switch try inspectEntry(
                named: fileName,
                in: directoryDescriptor,
                enforceByteLimit: false
            ) {
            case .missing:
                return .success(clearedAt: now(), removedEntry: false)
            case .regular:
                break
            }

            let unlinkResult = fileName.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            guard unlinkResult == 0 else {
                throw ProviderQuotaCacheFailure.io(
                    operation: "file.clear",
                    errorNumber: errno
                )
            }
            return .success(clearedAt: now(), removedEntry: true)
        } catch let failure as ProviderFailure {
            return .failure(failure)
        } catch {
            return .failure(ProviderQuotaCacheFailure.unavailable("cache.clear.unknown"))
        }
    }

    public func shutdown() async {
        acceptsOperations = false
    }

    static func cacheFileName(for providerID: ProviderID) -> String {
        "\(providerID.rawValue).quota-last-good.json"
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private enum EntryInspection {
        case missing
        case regular
    }

    private func openCacheDirectory() throws -> Int32 {
        let basePath = configuration.applicationSupportDirectory.path
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let baseDescriptor = basePath.withCString { Darwin.open($0, flags) }
        guard baseDescriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == ELOOP || errorNumber == ENOTDIR {
                throw ProviderQuotaCacheFailure.permission("cache.directory.unsafe_base")
            }
            throw ProviderQuotaCacheFailure.io(
                operation: "directory.open_base",
                errorNumber: errorNumber
            )
        }

        var currentDescriptor = baseDescriptor
        do {
            try requireDirectory(descriptor: baseDescriptor, enforcePrivateMode: false)

            for component in configuration.versionedRelativeDirectory {
                let nextDescriptor = try openOrCreateDirectory(
                    named: component,
                    relativeTo: currentDescriptor
                )
                if currentDescriptor != baseDescriptor {
                    Darwin.close(currentDescriptor)
                }
                currentDescriptor = nextDescriptor
            }

            if currentDescriptor != baseDescriptor {
                Darwin.close(baseDescriptor)
            }
            return currentDescriptor
        } catch {
            if currentDescriptor != baseDescriptor {
                Darwin.close(currentDescriptor)
            }
            Darwin.close(baseDescriptor)
            throw error
        }
    }

    private func openOrCreateDirectory(
        named component: String,
        relativeTo parentDescriptor: Int32
    ) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var created = false
        var descriptor = component.withCString {
            Darwin.openat(parentDescriptor, $0, flags)
        }
        if descriptor < 0 {
            let openError = errno
            if openError == ENOENT {
                let createResult = component.withCString {
                    Darwin.mkdirat(parentDescriptor, $0, Self.directoryMode)
                }
                if createResult != 0 && errno != EEXIST {
                    throw ProviderQuotaCacheFailure.io(operation: "directory.create")
                }
                created = createResult == 0
                descriptor = component.withCString {
                    Darwin.openat(parentDescriptor, $0, flags)
                }
            } else if openError == ELOOP || openError == ENOTDIR {
                throw ProviderQuotaCacheFailure.permission("cache.directory.unsafe_entry")
            } else {
                throw ProviderQuotaCacheFailure.io(
                    operation: "directory.open",
                    errorNumber: openError
                )
            }
        }

        guard descriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == ELOOP || errorNumber == ENOTDIR {
                throw ProviderQuotaCacheFailure.permission("cache.directory.unsafe_entry")
            }
            throw ProviderQuotaCacheFailure.io(
                operation: "directory.open_created",
                errorNumber: errorNumber
            )
        }

        do {
            if created, Darwin.fchmod(descriptor, Self.directoryMode) != 0 {
                throw ProviderQuotaCacheFailure.io(operation: "directory.chmod")
            }
            try requireDirectory(descriptor: descriptor, enforcePrivateMode: true)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func requireDirectory(
        descriptor: Int32,
        enforcePrivateMode: Bool
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw ProviderQuotaCacheFailure.io(operation: "directory.stat")
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ProviderQuotaCacheFailure.permission("cache.directory.non_directory")
        }
        if enforcePrivateMode,
           (status.st_mode & Self.permissionMask) != Self.directoryMode {
            throw ProviderQuotaCacheFailure.permission("cache.directory.unsafe_mode")
        }
    }

    private func inspectEntry(
        named fileName: String,
        in directoryDescriptor: Int32,
        enforceByteLimit: Bool
    ) throws -> EntryInspection {
        var status = stat()
        let result = fileName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT {
                return .missing
            }
            throw ProviderQuotaCacheFailure.io(
                operation: "file.inspect",
                errorNumber: errorNumber
            )
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ProviderQuotaCacheFailure.permission("cache.file.symlink_or_nonregular")
        }
        guard (status.st_mode & Self.permissionMask) == Self.fileMode else {
            throw ProviderQuotaCacheFailure.permission("cache.file.unsafe_mode")
        }
        if enforceByteLimit {
            guard status.st_size >= 0,
                  status.st_size <= off_t(configuration.maximumFileBytes) else {
                throw ProviderQuotaCacheFailure.corrupt("cache.file.oversized")
            }
        }
        return .regular
    }

    private func readEntry(
        named fileName: String,
        in directoryDescriptor: Int32,
        byteLimit: Int
    ) throws -> Data {
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let descriptor = fileName.withCString {
            Darwin.openat(directoryDescriptor, $0, flags)
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == ELOOP || errorNumber == ENXIO || errorNumber == ENOTDIR {
                throw ProviderQuotaCacheFailure.permission(
                    "cache.file.symlink_or_nonregular"
                )
            }
            throw ProviderQuotaCacheFailure.io(
                operation: "file.open_read",
                errorNumber: errorNumber
            )
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw ProviderQuotaCacheFailure.io(operation: "file.stat_open")
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ProviderQuotaCacheFailure.permission("cache.file.symlink_or_nonregular")
        }
        guard (status.st_mode & Self.permissionMask) == Self.fileMode else {
            throw ProviderQuotaCacheFailure.permission("cache.file.unsafe_mode")
        }
        guard status.st_size >= 0, status.st_size <= off_t(byteLimit) else {
            throw ProviderQuotaCacheFailure.corrupt("cache.file.oversized")
        }

        var result = Data()
        result.reserveCapacity(min(Int(status.st_size), byteLimit))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let address = bytes.baseAddress else { return 0 }
                return Darwin.read(descriptor, address, bytes.count)
            }
            if readCount == 0 {
                break
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw ProviderQuotaCacheFailure.io(operation: "file.read")
            }
            guard result.count <= byteLimit - readCount else {
                throw ProviderQuotaCacheFailure.corrupt("cache.file.oversized")
            }
            result.append(buffer, count: readCount)
        }
        return result
    }

    private func atomicallyReplace(
        entryNamed fileName: String,
        with data: Data,
        in directoryDescriptor: Int32
    ) throws {
        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(directoryDescriptor, $0, flags, Self.fileMode)
        }
        guard temporaryDescriptor >= 0 else {
            throw ProviderQuotaCacheFailure.io(operation: "temp.create")
        }

        var shouldRemoveTemporary = true
        defer {
            if temporaryDescriptor >= 0 {
                Darwin.close(temporaryDescriptor)
            }
            if shouldRemoveTemporary {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        guard Darwin.fchmod(temporaryDescriptor, Self.fileMode) == 0 else {
            throw ProviderQuotaCacheFailure.io(operation: "temp.chmod")
        }
        try writeAll(data, to: temporaryDescriptor)
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw ProviderQuotaCacheFailure.io(operation: "temp.fsync")
        }
        guard Darwin.close(temporaryDescriptor) == 0 else {
            temporaryDescriptor = -1
            throw ProviderQuotaCacheFailure.io(operation: "temp.close")
        }
        temporaryDescriptor = -1

        let renameResult = temporaryName.withCString { temporaryPointer in
            fileName.withCString { destinationPointer in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    destinationPointer
                )
            }
        }
        guard renameResult == 0 else {
            throw ProviderQuotaCacheFailure.io(operation: "file.rename")
        }
        shouldRemoveTemporary = false

        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw ProviderQuotaCacheFailure.io(operation: "directory.fsync")
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ProviderQuotaCacheFailure.io(operation: "temp.write")
                }
                guard written > 0 else {
                    throw ProviderQuotaCacheFailure.unavailable("cache.temp.write_zero")
                }
                offset += written
            }
        }
    }
}
