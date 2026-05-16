import Foundation

enum FromAddressParser {
    private static let angleEmail = try! NSRegularExpression(pattern: "<([^>]+)>", options: [])

    static func parsePrimaryEmail(fromHeader: String) -> String? {
        let t = fromHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        if let m = angleEmail.firstMatch(in: t, options: [], range: range),
           m.numberOfRanges > 1,
           let r = Range(m.range(at: 1), in: t) {
            return String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if t.contains("@") {
            let part = t.split(whereSeparator: { $0.isWhitespace }).map(String.init).first { $0.contains("@") } ?? t
            return part.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'")).lowercased()
        }
        return nil
    }
}
