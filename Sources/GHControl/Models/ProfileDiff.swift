import Foundation

struct ProfileDiff: Identifiable {
    let baselineName: String
    let tunedName: String
    let changes: [ProfileChange]
    let baselineFieldCount: Int
    let tunedFieldCount: Int

    var id: String { baselineName + "|" + tunedName }
}

struct ProfileChange: Identifiable {
    enum Kind {
        case added
        case removed
        case changed
    }

    let key: String
    let before: String?
    let after: String?

    var id: String { key }
    var kind: Kind {
        switch (before, after) {
        case (nil, .some): .added
        case (.some, nil): .removed
        default: .changed
        }
    }
}

enum AdrenalinProfileParser {
    static func compare(baselineData: Data, baselineName: String, tunedData: Data, tunedName: String) throws -> ProfileDiff {
        let baseline = try fields(in: baselineData)
        let tuned = try fields(in: tunedData)
        let keys = Set(baseline.keys).union(tuned.keys).sorted()
        let changes = keys.compactMap { key -> ProfileChange? in
            let beforeValues = baseline[key]
            let afterValues = tuned[key]
            guard beforeValues != afterValues else { return nil }
            return ProfileChange(
                key: key,
                before: beforeValues?.joined(separator: " · "),
                after: afterValues?.joined(separator: " · ")
            )
        }

        return ProfileDiff(
            baselineName: baselineName,
            tunedName: tunedName,
            changes: changes,
            baselineFieldCount: baseline.values.reduce(0) { $0 + $1.count },
            tunedFieldCount: tuned.values.reduce(0) { $0 + $1.count }
        )
    }

    private static func fields(in data: Data) throws -> [String: [String]] {
        guard data.count <= 5 * 1_024 * 1_024 else { throw ParseError.fileTooLarge }
        let parser = XMLParser(data: data)
        let delegate = FieldCollector()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? ParseError.invalidXML
        }
        guard !delegate.fields.isEmpty else { throw ParseError.noFields }
        return delegate.fields.mapValues { $0.sorted() }
    }

    enum ParseError: LocalizedError {
        case fileTooLarge
        case invalidXML
        case noFields

        var errorDescription: String? {
            switch self {
            case .fileTooLarge: "XML 文件超过 5 MiB，已拒绝读取。"
            case .invalidXML: "文件不是有效的 XML。"
            case .noFields: "XML 中没有可比较的字段。"
            }
        }
    }
}

private final class FieldCollector: NSObject, XMLParserDelegate {
    private struct Frame {
        let component: String
        var text = ""
        var hasChild = false
    }

    private var frames: [Frame] = []
    var fields: [String: [String]] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if !frames.isEmpty { frames[frames.count - 1].hasChild = true }
        let attributes = attributeDict.keys.sorted().map { "\($0)=\(attributeDict[$0] ?? "")" }
        let component = attributes.isEmpty ? elementName : "\(elementName)[\(attributes.joined(separator: ","))]"
        frames.append(Frame(component: component))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].text.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].text.append(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let frame = frames.popLast(), !frame.hasChild else { return }
        let value = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = frames.map(\.component).appending(frame.component).joined(separator: "/")
        fields[key, default: []].append(value.isEmpty ? "(空值)" : value)
    }
}

private extension Array where Element == String {
    func appending(_ element: String) -> [String] { self + [element] }
}
