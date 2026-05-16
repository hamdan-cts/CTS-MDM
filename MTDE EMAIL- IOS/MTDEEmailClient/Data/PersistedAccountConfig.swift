import Foundation

struct PersistedAccountConfig: Codable, Equatable, Identifiable {
    var id: String
    var username: String
    var password: String
    var incomingHost: String
    var incomingPort: Int
    var incomingProtocol: IncomingProtocol
    var smtpHost: String
    var smtpPort: Int
    var smtpSsl: Bool
    var smtpStartTls: Bool
    /// Self-signed or private CA (typical on internal mail servers).
    var trustPrivateCerts: Bool
    var caldavUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, username, password
        case incomingHost = "in_host"
        case incomingPort = "in_port"
        case incomingProtocol = "in_proto"
        case smtpHost = "smtp_host"
        case smtpPort = "smtp_port"
        case smtpSsl = "smtp_ssl"
        case smtpStartTls = "smtp_starttls"
        case trustPrivateCerts = "trust_private"
        case caldavUrl = "caldav"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id).nilIfEmpty ?? UUID().uuidString
        username = try c.decode(String.self, forKey: .username)
        password = try c.decode(String.self, forKey: .password)
        incomingHost = try c.decode(String.self, forKey: .incomingHost)
        incomingPort = try c.decodeIfPresent(Int.self, forKey: .incomingPort) ?? 993
        incomingProtocol = try c.decodeIfPresent(IncomingProtocol.self, forKey: .incomingProtocol) ?? .IMAP
        smtpHost = try c.decode(String.self, forKey: .smtpHost)
        smtpPort = try c.decodeIfPresent(Int.self, forKey: .smtpPort) ?? 465
        smtpSsl = try c.decodeIfPresent(Bool.self, forKey: .smtpSsl) ?? true
        smtpStartTls = try c.decodeIfPresent(Bool.self, forKey: .smtpStartTls) ?? false
        trustPrivateCerts = try c.decodeIfPresent(Bool.self, forKey: .trustPrivateCerts) ?? true
        let cal = try c.decodeIfPresent(String.self, forKey: .caldavUrl) ?? ""
        caldavUrl = cal.isEmpty ? nil : cal
    }

    init(
        id: String,
        username: String,
        password: String,
        incomingHost: String,
        incomingPort: Int,
        incomingProtocol: IncomingProtocol,
        smtpHost: String,
        smtpPort: Int,
        smtpSsl: Bool,
        smtpStartTls: Bool,
        trustPrivateCerts: Bool,
        caldavUrl: String?,
    ) {
        self.id = id
        self.username = username
        self.password = password
        self.incomingHost = incomingHost
        self.incomingPort = incomingPort
        self.incomingProtocol = incomingProtocol
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSsl = smtpSsl
        self.smtpStartTls = smtpStartTls
        self.trustPrivateCerts = trustPrivateCerts
        self.caldavUrl = caldavUrl
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(username, forKey: .username)
        try c.encode(password, forKey: .password)
        try c.encode(incomingHost, forKey: .incomingHost)
        try c.encode(incomingPort, forKey: .incomingPort)
        try c.encode(incomingProtocol, forKey: .incomingProtocol)
        try c.encode(smtpHost, forKey: .smtpHost)
        try c.encode(smtpPort, forKey: .smtpPort)
        try c.encode(smtpSsl, forKey: .smtpSsl)
        try c.encode(smtpStartTls, forKey: .smtpStartTls)
        try c.encode(trustPrivateCerts, forKey: .trustPrivateCerts)
        try c.encode(caldavUrl ?? "", forKey: .caldavUrl)
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        switch self {
        case .none: return nil
        case .some(let s): return s.isEmpty ? nil : s
        }
    }
}
