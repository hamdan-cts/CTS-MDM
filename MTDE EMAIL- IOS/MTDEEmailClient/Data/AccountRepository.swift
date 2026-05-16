import Foundation
import Security

/// Encrypted-equivalent storage: account JSON (including passwords) in the iOS Keychain.
/// JSON field names match Android `AccountRepository` for interoperability.
final class AccountRepository {
    private let service = "com.mtde.emailclient.mtde_secure_account"
    private let accountKey = "account_list_json_v3"
    private let activeIdKey = "active_account_id_v3"

    init() {
        migrateLegacySingleAccountIfNeeded()
    }

    func listAccounts() -> [PersistedAccountConfig] {
        readAccountsJson()
    }

    func getActiveAccountId() -> String? {
        (try? KeychainHelper.load(service: service, account: activeIdKey)).flatMap { String(data: $0, encoding: .utf8) }?.nilIfEmpty
    }

    func loadActiveAccount() -> PersistedAccountConfig? {
        let accounts = listAccounts()
        if accounts.isEmpty { return nil }
        let id = getActiveAccountId()
        if let id, let match = accounts.first(where: { $0.id == id }) { return match }
        let first = accounts[0]
        if getActiveAccountId() == nil {
            try? KeychainHelper.save(Data(first.id.utf8), service: service, account: activeIdKey)
        }
        return first
    }

    func setActiveAccountId(_ accountId: String) -> Bool {
        guard listAccounts().contains(where: { $0.id == accountId }) else { return false }
        try? KeychainHelper.save(Data(accountId.utf8), service: service, account: activeIdKey)
        return true
    }

    func upsertAndSetActive(_ config: PersistedAccountConfig) throws {
        var list = readAccountsJson()
        let idx = list.firstIndex {
            $0.username.caseInsensitiveCompare(config.username) == .orderedSame
                && $0.incomingHost.caseInsensitiveCompare(config.incomingHost) == .orderedSame
        }
        let toStore: PersistedAccountConfig
        if let idx {
            let keepId = list[idx].id
            toStore = PersistedAccountConfig(
                id: keepId,
                username: config.username,
                password: config.password,
                incomingHost: config.incomingHost,
                incomingPort: config.incomingPort,
                incomingProtocol: config.incomingProtocol,
                smtpHost: config.smtpHost,
                smtpPort: config.smtpPort,
                smtpSsl: config.smtpSsl,
                smtpStartTls: config.smtpStartTls,
                trustPrivateCerts: config.trustPrivateCerts,
                caldavUrl: config.caldavUrl
            )
            list[idx] = toStore
        } else {
            let id = config.id.isEmpty ? UUID().uuidString : config.id
            toStore = PersistedAccountConfig(
                id: id,
                username: config.username,
                password: config.password,
                incomingHost: config.incomingHost,
                incomingPort: config.incomingPort,
                incomingProtocol: config.incomingProtocol,
                smtpHost: config.smtpHost,
                smtpPort: config.smtpPort,
                smtpSsl: config.smtpSsl,
                smtpStartTls: config.smtpStartTls,
                trustPrivateCerts: config.trustPrivateCerts,
                caldavUrl: config.caldavUrl
            )
            list.append(toStore)
        }
        try writeAccountsJson(list)
        try KeychainHelper.save(Data(toStore.id.utf8), service: service, account: activeIdKey)
    }

    @discardableResult
    func removeAccount(_ accountId: String) throws -> Bool {
        var list = readAccountsJson()
        list.removeAll { $0.id == accountId }
        try writeAccountsJson(list)
        if list.isEmpty {
            try? KeychainHelper.delete(service: service, account: activeIdKey)
            return false
        }
        let active = getActiveAccountId()
        if active == nil || active == accountId {
            try KeychainHelper.save(Data(list[0].id.utf8), service: service, account: activeIdKey)
        }
        return true
    }

    func removeActiveAccount() throws -> Bool {
        guard let id = getActiveAccountId() else { return false }
        return try removeAccount(id)
    }

    private func migrateLegacySingleAccountIfNeeded() {
        if (try? KeychainHelper.load(service: service, account: accountKey)) != nil { return }
        guard let userData = try? KeychainHelper.load(service: service, account: "username"),
              let user = String(data: userData, encoding: .utf8), !user.isEmpty
        else { return }
        let pass = (try? KeychainHelper.load(service: service, account: "password")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let inHost = (try? KeychainHelper.load(service: service, account: "in_host")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let inPort = Int((try? KeychainHelper.load(service: service, account: "in_port")).flatMap { String(data: $0, encoding: .utf8) } ?? "993") ?? 993
        let inProto = (try? KeychainHelper.load(service: service, account: "in_proto")).flatMap { String(data: $0, encoding: .utf8) } ?? IncomingProtocol.IMAP.rawValue
        let smtpHost = (try? KeychainHelper.load(service: service, account: "smtp_host")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let smtpPort = Int((try? KeychainHelper.load(service: service, account: "smtp_port")).flatMap { String(data: $0, encoding: .utf8) } ?? "465") ?? 465
        let smtpSsl = ((try? KeychainHelper.load(service: service, account: "smtp_ssl")).flatMap { String(data: $0, encoding: .utf8) } ?? "1") == "1"
        let smtpStartTls = ((try? KeychainHelper.load(service: service, account: "smtp_starttls")).flatMap { String(data: $0, encoding: .utf8) } ?? "0") == "1"
        let trust = ((try? KeychainHelper.load(service: service, account: "trust_private_certs")).flatMap { String(data: $0, encoding: .utf8) } ?? "1") == "1"
        let caldav = (try? KeychainHelper.load(service: service, account: "caldav")).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        let proto = IncomingProtocol(rawValue: inProto.uppercased()) ?? .IMAP
        let cfg = PersistedAccountConfig(
            id: UUID().uuidString,
            username: user,
            password: pass,
            incomingHost: inHost,
            incomingPort: inPort,
            incomingProtocol: proto,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpSsl: smtpSsl,
            smtpStartTls: smtpStartTls,
            trustPrivateCerts: trust,
            caldavUrl: caldav
        )
        try? writeAccountsJson([cfg])
        try? KeychainHelper.save(Data(cfg.id.utf8), service: service, account: activeIdKey)
        let legacyKeys = ["username", "password", "in_host", "in_port", "in_proto", "smtp_host", "smtp_port", "smtp_ssl", "smtp_starttls", "trust_private_certs", "caldav"]
        for k in legacyKeys { try? KeychainHelper.delete(service: service, account: k) }
    }

    private func readAccountsJson() -> [PersistedAccountConfig] {
        guard let data = try? KeychainHelper.load(service: service, account: accountKey),
              let arr = try? JSONDecoder().decode([PersistedAccountConfig].self, from: data)
        else { return [] }
        return arr
    }

    private func writeAccountsJson(_ accounts: [PersistedAccountConfig]) throws {
        let data = try JSONEncoder().encode(accounts)
        try KeychainHelper.save(data, service: service, account: accountKey)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private enum KeychainHelper {
    static func save(_ data: Data, service: String, account: String) throws {
        try? delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return data
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
