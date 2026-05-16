import Foundation

enum ComposeIntent: Equatable, Identifiable {
    case new
    case reply(MailMessageDetail)
    case replyAll(MailMessageDetail)
    case forward(MailMessageDetail)

    var id: String {
        switch self {
        case .new: return "new"
        case .reply(let d): return "reply-\(d.serverKey)"
        case .replyAll(let d): return "replyall-\(d.serverKey)"
        case .forward(let d): return "fwd-\(d.serverKey)"
        }
    }
}

enum ComposeLogic {
    static func normalizeMailbox(_ emailish: String) -> String {
        let s = emailish.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner: String
        if let r = s.range(of: "<"), let r2 = s.range(of: ">", range: r.upperBound..<s.endIndex) {
            inner = String(s[r.upperBound..<r2])
        } else {
            inner = s
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func selfMailbox(_ config: PersistedAccountConfig) -> String {
        normalizeMailbox(config.username)
    }

    static func replySubject(_ subject: String) -> String {
        let t = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("re:") { return subject }
        return "Re: \(subject)"
    }

    static func forwardSubject(_ subject: String) -> String {
        let t = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let tl = t.lowercased()
        if tl.hasPrefix("fwd:") || tl.hasPrefix("fw:") { return subject }
        return "Fwd: \(subject)"
    }

    static func quoteForReply(_ detail: MailMessageDetail, dateFmt: DateFormatter) -> String {
        let whenStr = detail.date.map { dateFmt.string(from: $0) } ?? ""
        let body = detail.bodyPlain.isEmpty ? "(no plain text body)" : detail.bodyPlain
        var lines: [String] = ["", "On \(whenStr), \(detail.from) wrote:"]
        lines += body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
        return lines.joined(separator: "\n")
    }

    static func forwardBodyHtml(_ detail: MailMessageDetail, dateFmt: DateFormatter) -> String {
        let whenStr = detail.date.map { dateFmt.string(from: $0) } ?? ""
        let headerLines = """
        <p><b>---------- Forwarded message ----------</b></p>
        <p><b>From:</b> \(esc(detail.from))<br/>
        <b>To:</b> \(esc(detail.to))<br/>
        \(detail.cc.isEmpty ? "" : "<b>Cc:</b> \(esc(detail.cc))<br/>")
        <b>Date:</b> \(esc(whenStr))<br/>
        <b>Subject:</b> \(esc(detail.subject))</p><hr/>
        """
        let bodyBlock: String
        if let html = detail.bodyHtml?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
            bodyBlock = "<div style=\"margin:8px 0;border-left:3px solid #1976d2;padding-left:10px;\">\(html)</div>"
        } else {
            let plain = detail.bodyPlain.isEmpty ? "(no plain text body)" : detail.bodyPlain
            bodyBlock = "<pre style=\"white-space:pre-wrap;font-family:inherit;\">\(esc(plain))</pre>"
        }
        return "<div>\(headerLines)\(bodyBlock)</div>"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func replyToAddress(_ detail: MailMessageDetail) -> String {
        detail.replyToEmails.first
            ?? detail.fromEmails.first
            ?? ""
    }

    static func replyAllRecipients(_ detail: MailMessageDetail, config: PersistedAccountConfig) -> (String, String) {
        let selfM = selfMailbox(config)
        func notSelf(_ e: String) -> Bool { normalizeMailbox(e) != selfM }
        var toSet: [String] = []
        var toSeen = Set<String>()
        for e in detail.replyToEmails + detail.fromEmails + detail.toEmails {
            let t = e.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, notSelf(t) else { continue }
            let k = normalizeMailbox(t)
            if !toSeen.contains(k) {
                toSeen.insert(k)
                toSet.append(t)
            }
        }
        var ccSet: [String] = []
        var ccSeen = Set<String>()
        for addr in detail.ccEmails {
            let t = addr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, notSelf(t) else { continue }
            let k = normalizeMailbox(t)
            if toSeen.contains(k) { continue }
            if !ccSeen.contains(k) {
                ccSeen.insert(k)
                ccSet.append(t)
            }
        }
        return (toSet.joined(separator: ", "), ccSet.joined(separator: ", "))
    }
}
