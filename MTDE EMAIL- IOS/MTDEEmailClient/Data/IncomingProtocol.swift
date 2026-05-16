import Foundation

/// Matches Android `IncomingProtocol.name` (IMAP / POP3).
enum IncomingProtocol: String, Codable, CaseIterable, Identifiable {
    case IMAP
    case POP3

    var id: String { rawValue }
}
