import Foundation
import UsageButlerDomain

/// Version 1, network byte order, 56 bytes. SQLite never interprets byte totals
/// as signed integers or REAL. Durations are observed microseconds, not coverage
/// inferred from the existence of a minute row.
public struct HistoryMinute: Equatable, Sendable {
    public static let encodedSize = 56
    public private(set) var upload: UInt64 = 0
    public private(set) var download: UInt64 = 0
    public private(set) var uploadMicroseconds: UInt32 = 0
    public private(set) var downloadMicroseconds: UInt32 = 0
    public private(set) var uploadSamples: UInt16 = 0
    public private(set) var downloadSamples: UInt16 = 0
    public private(set) var peakUpload: Double = 0
    public private(set) var peakDownload: Double = 0
    public private(set) var firstMillisecond: Int32
    public private(set) var lastMillisecond: Int32
    public private(set) var quality: HistoryQuality

    public init(upload: UInt64?, download: UInt64?, durationNanoseconds: UInt64,
                firstMillisecond: Int32, lastMillisecond: Int32, quality: HistoryQuality = []) {
        self.firstMillisecond = firstMillisecond; self.lastMillisecond = lastMillisecond; self.quality = quality
        let duration = durationNanoseconds / 1_000
        let valid = duration > 0 && duration <= UInt64(UInt32.max)
        if let upload, valid {
            self.upload = upload; uploadSamples = 1; uploadMicroseconds = UInt32(duration)
            peakUpload = Double(upload) / (Double(durationNanoseconds) / 1e9)
        } else { self.quality.insert(.uploadGap) }
        if let download, valid {
            self.download = download; downloadSamples = 1; downloadMicroseconds = UInt32(duration)
            peakDownload = Double(download) / (Double(durationNanoseconds) / 1e9)
        } else { self.quality.insert(.downloadGap) }
    }

    public mutating func merge(_ other: Self) {
        quality.formUnion(other.quality)
        func add<T: FixedWidthInteger>(_ a: T, _ b: T, overflow: HistoryQuality) -> T {
            let result = a.addingReportingOverflow(b)
            if result.overflow { quality.insert(overflow); return 0 }
            return result.partialValue
        }
        upload = add(upload, other.upload, overflow: .uploadOverflow)
        download = add(download, other.download, overflow: .downloadOverflow)
        uploadMicroseconds = add(uploadMicroseconds, other.uploadMicroseconds, overflow: .uploadOverflow)
        downloadMicroseconds = add(downloadMicroseconds, other.downloadMicroseconds, overflow: .downloadOverflow)
        uploadSamples = add(uploadSamples, other.uploadSamples, overflow: .uploadOverflow)
        downloadSamples = add(downloadSamples, other.downloadSamples, overflow: .downloadOverflow)
        peakUpload = max(peakUpload, other.peakUpload); peakDownload = max(peakDownload, other.peakDownload)
        firstMillisecond = min(firstMillisecond, other.firstMillisecond)
        lastMillisecond = max(lastMillisecond, other.lastMillisecond)
    }

    public func shifted(milliseconds: Int32) -> Self {
        var copy = self
        copy.firstMillisecond += milliseconds; copy.lastMillisecond += milliseconds
        return copy
    }

    public var encoded: Data {
        var data = Data(); data.reserveCapacity(Self.encodedSize)
        func append<T: FixedWidthInteger>(_ number: T) {
            var big = number.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        append(upload); append(download); append(uploadMicroseconds); append(downloadMicroseconds)
        append(uploadSamples); append(downloadSamples); append(peakUpload.bitPattern); append(peakDownload.bitPattern)
        append(firstMillisecond); append(lastMillisecond); append(quality.rawValue)
        return data
    }

    public init?(encoded data: Data) {
        guard data.count == Self.encodedSize else { return nil }
        var offset = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
        upload = read(UInt64.self); download = read(UInt64.self)
        uploadMicroseconds = read(UInt32.self); downloadMicroseconds = read(UInt32.self)
        uploadSamples = read(UInt16.self); downloadSamples = read(UInt16.self)
        peakUpload = Double(bitPattern: read(UInt64.self)); peakDownload = Double(bitPattern: read(UInt64.self))
        firstMillisecond = read(Int32.self); lastMillisecond = read(Int32.self)
        quality = .init(rawValue: read(UInt32.self))
        guard peakUpload.isFinite, peakDownload.isFinite, peakUpload >= 0, peakDownload >= 0,
              firstMillisecond <= lastMillisecond else { return nil }
    }

    public var totals: HistoryTotals {
        var result = HistoryTotals()
        result.upload = quality.contains(.uploadOverflow) || uploadSamples == 0 ? nil : upload
        result.download = quality.contains(.downloadOverflow) || downloadSamples == 0 ? nil : download
        result.uploadObservedMicroseconds = UInt64(uploadMicroseconds)
        result.downloadObservedMicroseconds = UInt64(downloadMicroseconds)
        result.uploadSamples = UInt64(uploadSamples); result.downloadSamples = UInt64(downloadSamples)
        result.peakUpload = peakUpload; result.peakDownload = peakDownload; result.quality = quality
        return result
    }
}

extension HistoryTotals {
    /// A partial bucket contributes its known bytes and coverage. An overflow
    /// stays unknown, including when a later bucket itself fits UInt64.
    public mutating func merge(_ other: Self) {
        func sum(_ a: UInt64, _ b: UInt64) -> UInt64? {
            let result = a.addingReportingOverflow(b); return result.overflow ? nil : result.partialValue
        }
        func direction(_ a: UInt64?, _ b: UInt64?, samples: UInt64, prior: UInt64,
                       flag: HistoryQuality) -> UInt64? {
            if quality.contains(flag) || other.quality.contains(flag) { return nil }
            if samples == 0 { return a }
            if prior == 0 { return b }
            guard let a, let b, let result = sum(a, b) else { quality.insert(flag); return nil }
            return result
        }
        upload = direction(upload, other.upload, samples: other.uploadSamples, prior: uploadSamples, flag: .uploadOverflow)
        download = direction(download, other.download, samples: other.downloadSamples, prior: downloadSamples, flag: .downloadOverflow)
        uploadObservedMicroseconds = sum(uploadObservedMicroseconds, other.uploadObservedMicroseconds) ?? 0
        downloadObservedMicroseconds = sum(downloadObservedMicroseconds, other.downloadObservedMicroseconds) ?? 0
        uploadSamples = sum(uploadSamples, other.uploadSamples) ?? 0
        downloadSamples = sum(downloadSamples, other.downloadSamples) ?? 0
        peakUpload = max(peakUpload, other.peakUpload); peakDownload = max(peakDownload, other.peakDownload)
        quality.formUnion(other.quality)
        if uploadSamples == 0 { upload = nil }
        if downloadSamples == 0 { download = nil }
    }
}
