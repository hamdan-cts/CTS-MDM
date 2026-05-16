import Foundation

enum SenderRuleMatchKind: String, Codable {
    case addressEquals = "ADDRESS"
    case domainSuffix = "DOMAIN"
    case legacyContainsHeader = "LEGACY"
}

struct SenderMoveRule: Equatable, Identifiable {
    var id: String { "\(senderPattern)|\(targetFolder)|\(matchKind.rawValue)" }
    let senderPattern: String
    let targetFolder: String
    let matchKind: SenderRuleMatchKind

    var senderContains: String { senderPattern }

    func matchesMessageFrom(fromHeader: String) -> Bool {
        let pattern = senderPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return false }
        switch matchKind {
        case .addressEquals:
            guard let email = FromAddressParser.parsePrimaryEmail(fromHeader: fromHeader) else { return false }
            return email.caseInsensitiveCompare(pattern.lowercased()) == .orderedSame
        case .domainSuffix:
            guard let email = FromAddressParser.parsePrimaryEmail(fromHeader: fromHeader) else { return false }
            let dom = normalizeDomainPattern(pattern)
            if dom.isEmpty { return false }
            return email.lowercased().hasSuffix("@\(dom)")
        case .legacyContainsHeader:
            return fromHeader.range(of: pattern, options: .caseInsensitive) != nil
        }
    }

    func encode() -> [String: Any] {
        [
            "senderPattern": senderPattern.trimmingCharacters(in: .whitespacesAndNewlines),
            "folder": targetFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            "kind": matchKind.rawValue,
        ]
    }

    static func decode(from o: [String: Any]) -> SenderMoveRule? {
        let pattern = (o["senderPattern"] as? String ?? o["sender"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (o["folder"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty || folder.isEmpty { return nil }
        let kindStr = (o["kind"] as? String ?? "").uppercased()
        let kind: SenderRuleMatchKind
        switch kindStr {
        case "DOMAIN": kind = .domainSuffix
        case "LEGACY": kind = .legacyContainsHeader
        case "ADDRESS": kind = .addressEquals
        default: kind = o["kind"] != nil ? .addressEquals : .legacyContainsHeader
        }
        return SenderMoveRule(senderPattern: pattern, targetFolder: folder, matchKind: kind)
    }
}

private func normalizeDomainPattern(_ pattern: String) -> String {
    var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if p.hasPrefix("@") { p.removeFirst() }
    return p.trimmingCharacters(in: .whitespacesAndNewlines)
}
