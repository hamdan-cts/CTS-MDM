import Foundation

/// Mirrors Android `MailRulesStore` / `AutoReplyStore` (SharedPreferences keys).
final class MailRulesStore {
    private let sp: UserDefaults
    private let rulesKey = "rules_json"
    private let autoApplyKey = "auto_apply_inbox"

    init(accountId: String) {
        let suite = "mtde_mail_rules_\(accountId)"
        sp = UserDefaults(suiteName: suite) ?? .standard
    }

    func loadRules() -> [SenderMoveRule] {
        guard let raw = sp.string(forKey: rulesKey), let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap(SenderMoveRule.decode(from: $0))
    }

    func saveRules(_ rules: [SenderMoveRule]) {
        let arr = rules.map(\.encode)
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
            sp.set(s, forKey: rulesKey)
        }
    }

    var autoApplyAfterInboxLoad: Bool {
        get { sp.bool(forKey: autoApplyKey) }
        set { sp.set(newValue, forKey: autoApplyKey) }
    }
}

final class AutoReplyStore {
    private let sp: UserDefaults
    private let vacPrefix = "vac_"

    init(accountId: String) {
        let suite = "mtde_auto_reply_\(accountId)"
        sp = UserDefaults(suiteName: suite) ?? .standard
    }

    var isEnabled: Bool {
        get { sp.bool(forKey: "enabled") }
        set { sp.set(newValue, forKey: "enabled") }
    }

    var subject: String {
        get { sp.string(forKey: "subject") ?? "" }
        set { sp.set(newValue, forKey: "subject") }
    }

    var body: String {
        get { sp.string(forKey: "body") ?? "" }
        set { sp.set(newValue, forKey: "body") }
    }

    var sendVacationOnInboxRefresh: Bool {
        get { sp.bool(forKey: "vac_on_refresh") }
        set { sp.set(newValue, forKey: "vac_on_refresh") }
    }

    var scheduleEnabled: Bool {
        get { sp.bool(forKey: "schedule_enabled") }
        set { sp.set(newValue, forKey: "schedule_enabled") }
    }

    var scheduleStartMillis: Int64 {
        get { Int64(sp.integer(forKey: "schedule_start_ms")) }
        set { sp.set(newValue, forKey: "schedule_start_ms") }
    }

    var scheduleEndMillis: Int64 {
        get { Int64(sp.integer(forKey: "schedule_end_ms")) }
        set { sp.set(newValue, forKey: "schedule_end_ms") }
    }

    func isWithinScheduledWindow(now: Date = Date()) -> Bool {
        guard scheduleEnabled else { return true }
        let s = scheduleStartMillis
        let e = scheduleEndMillis
        if s == 0 || e == 0 { return true }
        let lo = min(s, e)
        let hi = max(s, e)
        let t = Int64(now.timeIntervalSince1970 * 1000)
        return t >= lo && t <= hi
    }

    func consumeVacationSlotForSender(senderLower: String) -> Bool {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let key = "\(vacPrefix)\(senderLower)_\(day)"
        if sp.bool(forKey: key) { return false }
        sp.set(true, forKey: key)
        return true
    }

    func releaseVacationSlotForSender(senderLower: String) {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let key = "\(vacPrefix)\(senderLower)_\(day)"
        sp.set(false, forKey: key)
    }
}
