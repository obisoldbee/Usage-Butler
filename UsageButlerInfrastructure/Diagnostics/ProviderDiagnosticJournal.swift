import CryptoKit
import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// Serial, bounded local evidence. Failures here never change a quota result.
public actor ProviderDiagnosticJournal: ProviderDiagnosticRecording {
    public static let fileName = "provider-events-v1.json"
    public enum State: String, Sendable { case ready, unavailable }
    private let directory: URL
    private var events: [ProviderDiagnosticEvent] = []
    private var loaded = false
    private var state: State = .ready
    private static let maximumBytes = 2_000_000

    public init(directory: URL) { self.directory = directory }

    public func record(_ event: ProviderDiagnosticEvent) async {
        do {
            let fd = try openDirectory()
            defer { close(fd) }
            try loadIfNeeded(fd: fd)
            let previousCount = events.count
            prune(now: event.timestamp)
            if event.reason == .recovered,
               events.last(where: { $0.provider == event.provider })?.reason == .recovered ||
                (event.reason == .recovered && !events.contains(where: { $0.provider == event.provider })) {
                if previousCount != events.count || state == .unavailable { try persist(fd: fd) }
                state = .ready
                return
            }
            guard event.isSafe, (try JSONEncoder().encode(event)).count <= 8192 else { throw JournalError.invalid }
            events.append(event)
            prune(now: event.timestamp)
            try persist(fd: fd)
            state = .ready
        } catch { state = .unavailable }
    }

    public func snapshot(now: Date = Date()) -> (events: [ProviderDiagnosticEvent], state: State) {
        do {
            let fd = try openDirectory(); defer { close(fd) }
            try loadIfNeeded(fd: fd)
            let previousCount = events.count
            prune(now: now)
            if events.count != previousCount { try persist(fd: fd) }
        } catch { state = .unavailable }
        return (events, state)
    }

    private func persist(fd: Int32) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(events)
        guard data.count <= Self.maximumBytes else { throw JournalError.invalid }
        let name = ".events-\(UUID().uuidString).tmp"
        let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw JournalError.io }
        defer { close(output); unlinkat(fd, name, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw JournalError.io }; offset += count
            }
        }
        guard fsync(output) == 0, renameat(fd, name, fd, Self.fileName) == 0 else { throw JournalError.io }
    }

    private func prune(now: Date) {
        events = Array(events.filter { $0.timestamp >= now.addingTimeInterval(-7 * 86400) }
            .sorted { $0.timestamp < $1.timestamp }.suffix(200))
    }

    private func loadIfNeeded(fd: Int32) throws {
        guard !loaded else { return }
        let input = openat(fd, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if input < 0 && errno == ENOENT { loaded = true; return }
        guard input >= 0 else { throw JournalError.io }; defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size <= Self.maximumBytes else { throw JournalError.invalid }
        let data = try FileHandle(fileDescriptor: input, closeOnDealloc: false).read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw JournalError.invalid }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        events = try decoder.decode([ProviderDiagnosticEvent].self, from: data)
        guard events.count <= 200, events.allSatisfy(\.isSafe) else { throw JournalError.invalid }
        loaded = true
    }

    private func openDirectory() throws -> Int32 {
        // Open each directory relative to its parent; never follow symlink substitutions.
        var fd = open("/", O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw JournalError.io }
        // Foundation standardization rewrites existing /private/tmp to the /tmp symlink.
        // Preserve the caller's explicit path and reject traversal instead.
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.pathComponents.contains("..") else { close(fd); throw JournalError.invalid }
        for component in directory.pathComponents.dropFirst() {
            if mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { close(fd); throw JournalError.io }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd); guard next >= 0 else { throw JournalError.io }; fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw JournalError.invalid
        }
        return fd
    }
    private enum JournalError: Error { case io, invalid }
}

public enum DiagnosticCLIIdentity {
    /// Only an executable digest and a strictly numeric package version leave this boundary.
    public static func read(executable: URL) -> (version: String?, digest: String?) {
        let resolved = executable.resolvingSymlinksInPath()
        let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        let digest = size <= 64_000_000 ? (try? Data(contentsOf: resolved)).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } : nil
        let package = resolved.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")
        var version: String?
        if let data = try? Data(contentsOf: package), data.count < 65_536,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["name"] as? String == "mmx-cli", let value = object["version"] as? String,
           value.range(of: #"^\d{1,5}\.\d{1,5}\.\d{1,5}$"#, options: .regularExpression) != nil { version = value }
        return (version, digest)
    }
}
