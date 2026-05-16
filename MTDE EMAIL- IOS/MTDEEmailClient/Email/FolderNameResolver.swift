import Foundation

enum FolderNameResolver {
    static func preferredNames(tab: MailFolderTab) -> [String] {
        switch tab {
        case .inbox: return ["INBOX"]
        case .sent:
            return [
                "Sent", "Sent Items", "Sent Mail", "SENT", "Outbox",
                "[Gmail]/Sent Mail", "INBOX.Sent", "INBOX/Sent",
            ]
        case .drafts:
            return [
                "Drafts", "Draft", "[Gmail]/Drafts", "INBOX.Drafts", "INBOX/Drafts",
                "INBOX.Draft", "Templates",
            ]
        case .trash:
            return [
                "Trash", "Deleted Items", "Bin", "Deleted Messages",
                "[Gmail]/Trash", "INBOX.Trash", "INBOX/Trash", "Junk", "Spam",
                "[Gmail]/Spam",
            ]
        case .folders: return []
        }
    }

    static func resolveTabToFolder(tab: MailFolderTab, availableFolders: [String]) -> String? {
        if tab == .folders { return nil }
        if tab == .inbox {
            return availableFolders.first { $0.caseInsensitiveCompare("INBOX") == .orderedSame }
                ?? availableFolders.first { $0.hasSuffix("INBOX") }
                ?? "INBOX"
        }
        let preferred = preferredNames(tab: tab)
        for name in preferred {
            if let m = matchExact(availableFolders, name) { return m }
        }
        for name in preferred {
            if let m = matchSuffix(availableFolders, name) { return m }
        }
        return fuzzyMatchTab(tab, availableFolders)
    }

    private static func fuzzyMatchTab(_ tab: MailFolderTab, folders: [String]) -> String? {
        let tokens: [String]
        switch tab {
        case .sent: tokens = ["sent", "outbox", "envoy"]
        case .drafts: tokens = ["draft", "brouillon", "مسودة", "مسودات"]
        case .trash: tokens = ["trash", "deleted", "bin", "junk", "spam", "papier", "gelöscht"]
        default: return nil
        }
        return folders.first { path in
            let leaf = lastPathSegment(path)
            let lower = leaf.lowercased()
            return tokens.contains { lower.contains($0) }
        }
    }

    private static func lastPathSegment(_ full: String) -> String {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let bySlash = (trimmed as NSString).lastPathComponent
        let byDot = bySlash.split(separator: ".").map(String.init).last ?? bySlash
        return byDot
    }

    private static func matchExact(_ available: [String], name: String) -> String? {
        available.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func matchSuffix(_ available: [String], segment: String) -> String? {
        let seg = segment.lowercased()
        return available.first { full in
            let lower = full.lowercased()
            return lower.hasSuffix("/\(seg)") || lower.hasSuffix(".\(seg)") || lower == seg
        }
    }
}
