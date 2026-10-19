import Foundation

/// A captured scalar value, never a display preview or an absent/container placeholder.
public struct InspectorLeaf: Sendable {
    public let value: EntitlementValue

    public init?(_ value: EntitlementValue?) {
        guard let value else { return nil }
        switch value {
        case .array, .dictionary: return nil
        default: self.value = value
        }
    }

    /// Uses the same exact tagged scalar encoding as complete reports.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// Build off MainActor. Indexing is cancellable; rendering visits only the chosen page.
public struct LeafValueDocument: Sendable {
    public static let stringScalarsPerPage = 512
    // Whole triples make concatenated page base64 equal the complete base64 value.
    public static let dataBytesPerPage = 768
    public let leaf: InspectorLeaf
    public let pageCount: Int
    public let stringScalarCount: Int?
    private let stringPages: [Range<String.Index>]
    private let stringPageByteOffsets: [Int]

    public init(leaf: InspectorLeaf) throws {
        try Task.checkCancellation()
        self.leaf = leaf
        var pages: [Range<String.Index>] = []
        var byteOffsets: [Int] = []
        var byteOffset = 0
        var scalarCount: Int?
        switch leaf.value {
        case .string(let string):
            scalarCount = 0
            let scalars = string.unicodeScalars
            var start = scalars.startIndex
            while start < scalars.endIndex {
                try Task.checkCancellation()
                let end = scalars.index(start, offsetBy: Self.stringScalarsPerPage,
                                        limitedBy: scalars.endIndex) ?? scalars.endIndex
                scalarCount = (scalarCount ?? 0) + scalars.distance(from: start, to: end)
                byteOffsets.append(byteOffset)
                byteOffset += string.utf8.distance(from: start, to: end)
                pages.append(start..<end)
                start = end
            }
            if pages.isEmpty { pages.append(start..<start); byteOffsets.append(0) }
            pageCount = pages.count
        case .data(let data):
            pageCount = max(1, data.count / Self.dataBytesPerPage + (data.count % Self.dataBytesPerPage == 0 ? 0 : 1))
        default:
            pageCount = 1
        }
        stringScalarCount = scalarCount
        stringPages = pages
        stringPageByteOffsets = byteOffsets
    }

    public struct ScalarPosition: Sendable, Equatable {
        public let scalarOffset: Int
        public let byteOffset: Int
        public let pageIndex: Int
        public let scalar: Unicode.Scalar?
        public var detail: StringScalarDetail { StringScalarDetail(scalar: scalar) }
        public var byteCount: Int { scalar.map { String($0).utf8.count } ?? 0 }
    }

    /// Zero-based original scalar or EOF; visits at most one prepared 512-scalar page.
    public func scalarPosition(at offset: Int) -> ScalarPosition? {
        guard case .string(let string) = leaf.value, let count = stringScalarCount,
              offset >= 0, offset <= count else { return nil }
        let page = min(offset / Self.stringScalarsPerPage, pageCount - 1)
        let scalars = string.unicodeScalars
        var index = stringPages[page].lowerBound, byte = stringPageByteOffsets[page]
        for _ in 0..<(offset - page * Self.stringScalarsPerPage) {
            byte += String(scalars[index]).utf8.count
            scalars.formIndex(after: &index)
        }
        return ScalarPosition(scalarOffset: offset, byteOffset: byte, pageIndex: page,
                              scalar: index == scalars.endIndex ? nil : scalars[index])
    }

    public struct StringPage: Sendable {
        public let text: String
        public let highlight: NSRange?
        public let continuesBefore: Bool
        public let continuesAfter: Bool
    }

    /// Maps original UTF-8 byte positions into escaped display UTF-16, visiting only this page.
    public func stringPage(onPage requestedPage: Int, matching range: Range<Int>?) -> StringPage? {
        guard case .string(let string) = leaf.value else { return nil }
        let page = max(0, min(requestedPage, pageCount - 1))
        let startByte = stringPageByteOffsets[page]
        var byte = startByte, utf16 = 1
        var first: Int?, last: Int?
        var text = "\""
        for scalar in string.unicodeScalars[stringPages[page]] {
            let raw = String(scalar)
            let endByte = byte + raw.utf8.count
            let escaped = scalar == "\"" ? "\\\"" : DisplayText.escaped(raw)
            let endUTF16 = utf16 + escaped.utf16.count
            if let range, byte >= range.lowerBound, endByte <= range.upperBound {
                if first == nil { first = utf16 }
                last = endUTF16
            }
            text += escaped
            byte = endByte; utf16 = endUTF16
        }
        text += "\""
        let highlight: NSRange?
        if let first, let last { highlight = NSRange(location: first, length: last - first) }
        else { highlight = nil }
        return StringPage(text: text, highlight: highlight,
                          continuesBefore: highlight != nil && (range?.lowerBound ?? startByte) < startByte,
                          continuesAfter: highlight != nil && (range?.upperBound ?? byte) > byte)
    }

    /// A zero-length difference marks the closing quote at the exact end of the original string.
    public func stringDifferencePage(onPage requestedPage: Int, byteOffset: Int, scalarByteCount: Int) -> StringPage? {
        guard byteOffset >= 0, (0...4).contains(scalarByteCount), byteOffset <= Int.max - scalarByteCount else { return nil }
        guard let page = stringPage(onPage: requestedPage,
                                    matching: byteOffset..<(byteOffset + scalarByteCount)) else { return nil }
        guard scalarByteCount == 0, case .string(let string) = leaf.value else { return page }
        let index = max(0, min(requestedPage, pageCount - 1))
        let end = stringPageByteOffsets[index] + string.utf8.distance(from: stringPages[index].lowerBound,
                                                                     to: stringPages[index].upperBound)
        guard index == pageCount - 1, byteOffset == end else { return page }
        return StringPage(text: page.text, highlight: NSRange(location: page.text.utf16.count - 1, length: 1),
                          continuesBefore: false, continuesAfter: false)
    }

    public func text(onPage requestedPage: Int) -> String {
        let page = max(0, min(requestedPage, pageCount - 1))
        switch leaf.value {
        case .string(let string):
            // Preserve scalar boundaries and escape after slicing, so combining marks
            // and escaped controls cannot bypass the per-page rendering budget.
            return DisplayText.quoted(String(string.unicodeScalars[stringPages[page]]))
        case .data(let data):
            let offset = page * Self.dataBytesPerPage
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: min(Self.dataBytesPerPage, data.count - offset))
            return data[start..<end].base64EncodedString()
        default:
            return leaf.value.rendered
        }
    }
}

extension InspectorRow {
    public var hasLeafValue: Bool { InspectorLeaf(previous) != nil || InspectorLeaf(current) != nil }
}
