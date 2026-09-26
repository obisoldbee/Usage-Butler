import Foundation

public enum NettopCSVRecord: Equatable, Sendable {
    case header
    case process(pid: Int32, name: String, download: UInt64?, upload: UInt64?)
    case invalid
}

/// Incremental documented -P -L -n -x -J bytes_in,bytes_out format.
/// A repeated header closes the prior frame. No consumer timestamp is used
/// to turn a buffered multi-frame burst into fictitious 1 Hz source samples.
public struct NettopCSVParser: Sendable {
    public static let maximumLineBytes = 4_096
    private var line = Data()
    private var discarding = false
    private var incoming: Int?
    private var outgoing: Int?
    public init() {}
    public var bufferedBytes: Int { line.count }
    public mutating func feed(_ data: Data) -> [NettopCSVRecord] {
        var result: [NettopCSVRecord] = []
        for byte in data {
            if byte == 10 {
                if discarding { result.append(.invalid) }
                else if !line.isEmpty { result.append(parse(line)) }
                line.removeAll(keepingCapacity: true); discarding = false
            } else if byte != 13 {
                if line.count < Self.maximumLineBytes, !discarding { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return result
    }
    public mutating func finish() -> Bool {
        let clean = line.isEmpty && !discarding
        line.removeAll(); discarding = false
        return clean
    }
    private mutating func parse(_ data: Data) -> NettopCSVRecord {
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 32 }),
              let cells = Self.csv(text) else { return .invalid }
        if cells.first == "" {
            guard cells.filter({ $0 == "bytes_in" }).count == 1,
                  cells.filter({ $0 == "bytes_out" }).count == 1 else {
                incoming = nil; outgoing = nil; return .invalid
            }
            incoming = cells.firstIndex(of: "bytes_in"); outgoing = cells.firstIndex(of: "bytes_out")
            return .header
        }
        guard let incoming, let outgoing, cells.count > max(incoming, outgoing),
              let label = cells.first, let dot = label.lastIndex(of: "."),
              let pid = Int32(label[label.index(after: dot)...]), pid >= 0 else { return .invalid }
        let name = String(label[..<dot])
        guard !name.isEmpty, name.utf8.count <= 1_024 else { return .invalid }
        func counter(_ s: String) -> UInt64? {
            guard !s.isEmpty, s.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(s)
        }
        let down = counter(cells[incoming]), up = counter(cells[outgoing])
        // Empty means an unknown direction. Other malformed numbers invalidate
        // the frame rather than quietly masquerading as a complete enumeration.
        guard cells[incoming].isEmpty || down != nil,
              cells[outgoing].isEmpty || up != nil else { return .invalid }
        return .process(pid: pid, name: name, download: down, upload: up)
    }
    private static func csv(_ text: String) -> [String]? {
        var cells: [String] = [], current = "", quoted = false, closed = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i], next = text.index(after: i)
            if quoted {
                if c == "\"" {
                    if next < text.endIndex, text[next] == "\"" { current.append(c); i = text.index(after: next); continue }
                    quoted = false; closed = true
                } else { current.append(c) }
            } else if c == "," {
                cells.append(current); current = ""; closed = false
            } else if c == "\"", current.isEmpty, !closed { quoted = true }
            else if closed || c == "\"" { return nil }
            else { current.append(c) }
            i = next
        }
        guard !quoted else { return nil }
        cells.append(current)
        return cells.count <= 16 ? cells : nil
    }
}
