import Darwin
import Foundation
import UsageButlerCore

/// A bounded, private, atomically replaced store for the chart's minimal
/// timestamp/ratio/pressure history.
public actor MemoryHistoryDiskStore: MemoryHistoryStore {
    static let fileName = "memory-history.json"

    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)
    private static let permissionMask = mode_t(0o7777)

    private let configuration: MemoryHistoryDiskStoreConfiguration
    private var acceptsOperations = true

    public init(configuration: MemoryHistoryDiskStoreConfiguration) {
        self.configuration = configuration
    }

    public func load(
        referenceTimestamp: Date
    ) async -> MemoryHistoryStoreLoadResult {
        guard acceptsOperations else { return .failure(.shutdown) }
        guard Self.isFinite(referenceTimestamp) else {
            return .failure(.invalidInput)
        }

        do {
            let directoryDescriptor = try openHistoryDirectory()
            defer { Darwin.close(directoryDescriptor) }

            switch try inspectEntry(
                named: Self.fileName,
                in: directoryDescriptor,
                enforceByteLimit: true
            ) {
            case .missing:
                return .miss
            case .regular:
                break
            }

            let data = try readEntry(
                named: Self.fileName,
                in: directoryDescriptor,
                byteLimit: configuration.maximumFileBytes
            )
            do {
                try MemoryHistoryStrictSchema.validate(data)
            } catch {
                throw MemoryHistoryStoreFailure.corrupt
            }

            let envelope: MemoryHistoryEnvelopeDTO
            do {
                envelope = try Self.decoder().decode(
                    MemoryHistoryEnvelopeDTO.self,
                    from: data
                )
            } catch {
                throw MemoryHistoryStoreFailure.corrupt
            }

            let decoded: [MemoryHistoryPoint]
            do {
                decoded = try envelope.domainPoints()
            } catch MemoryHistoryPersistenceDTOError.unknownSchema {
                throw MemoryHistoryStoreFailure.unsupportedSchema
            } catch MemoryHistoryPersistenceDTOError.unknownVersion {
                throw MemoryHistoryStoreFailure.unsupportedVersion
            } catch {
                throw MemoryHistoryStoreFailure.corrupt
            }

            return .hit(pointsInValidWindow(
                decoded,
                referenceTimestamp: referenceTimestamp
            ))
        } catch let failure as MemoryHistoryStoreFailure {
            return .failure(failure)
        } catch {
            return .failure(.io)
        }
    }

    public func save(
        _ points: [MemoryHistoryPoint],
        referenceTimestamp: Date
    ) async -> MemoryHistoryStoreWriteResult {
        guard acceptsOperations else { return .failure(.shutdown) }
        guard Self.isFinite(referenceTimestamp),
              points.allSatisfy({ Self.isFinite($0.timestamp) }) else {
            return .failure(.invalidInput)
        }

        let persistedPoints = pointsInValidWindow(
            points,
            referenceTimestamp: referenceTimestamp
        )
        let envelope: MemoryHistoryEnvelopeDTO
        do {
            envelope = try MemoryHistoryEnvelopeDTO(points: persistedPoints)
        } catch {
            return .failure(.invalidInput)
        }

        let encoded: Data
        do {
            encoded = try Self.encoder().encode(envelope)
        } catch {
            return .failure(.invalidInput)
        }
        guard encoded.count <= configuration.maximumFileBytes else {
            return .failure(.oversized)
        }

        do {
            let directoryDescriptor = try openHistoryDirectory()
            defer { Darwin.close(directoryDescriptor) }

            _ = try inspectEntry(
                named: Self.fileName,
                in: directoryDescriptor,
                enforceByteLimit: false
            )
            try atomicallyReplace(
                entryNamed: Self.fileName,
                with: encoded,
                in: directoryDescriptor
            )
            return .success(persistedPointCount: persistedPoints.count)
        } catch let failure as MemoryHistoryStoreFailure {
            return .failure(failure)
        } catch {
            return .failure(.io)
        }
    }

    public func shutdown() async {
        acceptsOperations = false
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

    private static func isFinite(_ timestamp: Date) -> Bool {
        timestamp.timeIntervalSince1970.isFinite
    }

    private func pointsInValidWindow(
        _ points: [MemoryHistoryPoint],
        referenceTimestamp: Date
    ) -> [MemoryHistoryPoint] {
        let cutoff = referenceTimestamp.addingTimeInterval(
            -configuration.retention
        )
        var pointsByTimestamp: [Date: MemoryHistoryPoint] = [:]
        for point in points
        where point.timestamp >= cutoff && point.timestamp <= referenceTimestamp {
            pointsByTimestamp[point.timestamp] = point
        }
        return pointsByTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    private enum EntryInspection {
        case missing
        case regular
    }

    private func openHistoryDirectory() throws -> Int32 {
        let basePath = configuration.applicationSupportDirectory.path
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let baseDescriptor = basePath.withCString { Darwin.open($0, flags) }
        guard baseDescriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw MemoryHistoryStoreFailure.unsafeBaseDirectory
            }
            throw MemoryHistoryStoreFailure.io
        }

        var currentDescriptor = baseDescriptor
        do {
            try requireDirectory(
                descriptor: baseDescriptor,
                enforcePrivateMode: false
            )

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
                    throw MemoryHistoryStoreFailure.io
                }
                created = createResult == 0
                descriptor = component.withCString {
                    Darwin.openat(parentDescriptor, $0, flags)
                }
            } else if openError == ELOOP || openError == ENOTDIR {
                throw MemoryHistoryStoreFailure.unsafeDirectoryEntry
            } else {
                throw MemoryHistoryStoreFailure.io
            }
        }

        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw MemoryHistoryStoreFailure.unsafeDirectoryEntry
            }
            throw MemoryHistoryStoreFailure.io
        }

        do {
            if created, Darwin.fchmod(descriptor, Self.directoryMode) != 0 {
                throw MemoryHistoryStoreFailure.io
            }
            try requireDirectory(
                descriptor: descriptor,
                enforcePrivateMode: true
            )
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
            throw MemoryHistoryStoreFailure.io
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw MemoryHistoryStoreFailure.unsafeDirectoryEntry
        }
        if enforcePrivateMode,
           (status.st_mode & Self.permissionMask) != Self.directoryMode {
            throw MemoryHistoryStoreFailure.unsafeDirectoryMode
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
            if errno == ENOENT {
                return .missing
            }
            throw MemoryHistoryStoreFailure.io
        }

        let fileType = status.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) {
            throw MemoryHistoryStoreFailure.symbolicLink
        }
        guard fileType == mode_t(S_IFREG) else {
            throw MemoryHistoryStoreFailure.nonRegularFile
        }
        guard (status.st_mode & Self.permissionMask) == Self.fileMode else {
            throw MemoryHistoryStoreFailure.unsafeFileMode
        }
        if enforceByteLimit {
            guard status.st_size >= 0,
                  status.st_size <= off_t(configuration.maximumFileBytes) else {
                throw MemoryHistoryStoreFailure.oversized
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
            if errno == ELOOP {
                throw MemoryHistoryStoreFailure.symbolicLink
            }
            if errno == ENXIO || errno == ENOTDIR {
                throw MemoryHistoryStoreFailure.nonRegularFile
            }
            throw MemoryHistoryStoreFailure.io
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw MemoryHistoryStoreFailure.io
        }
        let fileType = status.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFREG) else {
            throw MemoryHistoryStoreFailure.nonRegularFile
        }
        guard (status.st_mode & Self.permissionMask) == Self.fileMode else {
            throw MemoryHistoryStoreFailure.unsafeFileMode
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(byteLimit) else {
            throw MemoryHistoryStoreFailure.oversized
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
                throw MemoryHistoryStoreFailure.io
            }
            guard result.count <= byteLimit - readCount else {
                throw MemoryHistoryStoreFailure.oversized
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
            throw MemoryHistoryStoreFailure.io
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
            throw MemoryHistoryStoreFailure.io
        }
        try writeAll(data, to: temporaryDescriptor)
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw MemoryHistoryStoreFailure.io
        }
        guard Darwin.close(temporaryDescriptor) == 0 else {
            temporaryDescriptor = -1
            throw MemoryHistoryStoreFailure.io
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
            throw MemoryHistoryStoreFailure.io
        }
        shouldRemoveTemporary = false

        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw MemoryHistoryStoreFailure.io
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
                    throw MemoryHistoryStoreFailure.io
                }
                guard written > 0 else {
                    throw MemoryHistoryStoreFailure.io
                }
                offset += written
            }
        }
    }
}
