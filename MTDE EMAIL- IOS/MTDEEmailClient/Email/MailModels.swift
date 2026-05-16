import Foundation

struct MailMessageSummary: Identifiable, Equatable {
    var id: String { "\(folderFullName)|\(serverKey)" }
    let folderFullName: String
    /// IMAP UID, or POP3 message index.
    let serverKey: UInt32
    let subject: String
    let from: String
    let sentDate: Date?
    let seen: Bool
    let flagged: Bool
    let hasAttachment: Bool
}

struct MailAttachment: Equatable {
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let data: Data
}

struct MailMessageDetail: Equatable {
    let folderFullName: String
    let serverKey: UInt32
    let subject: String
    let from: String
    let to: String
    let cc: String
    let date: Date?
    let flagged: Bool
    let seen: Bool
    let bodyPlain: String
    let bodyHtml: String?
    let fromEmails: [String]
    let replyToEmails: [String]
    let toEmails: [String]
    let ccEmails: [String]
    let attachments: [MailAttachment]
}

struct OutboundAttachment: Equatable {
    let fileName: String
    let mimeType: String
    let data: Data
}

enum MailFolderTab: String, CaseIterable, Identifiable, Hashable {
    case inbox = "INBOX"
    case sent = "SENT"
    case drafts = "DRAFTS"
    case trash = "TRASH"
    case folders = "FOLDERS"

    var id: String { rawValue }
}
