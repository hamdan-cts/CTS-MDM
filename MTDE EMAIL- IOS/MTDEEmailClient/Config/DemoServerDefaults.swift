import Foundation

/// Default CTS lab server (edit for production builds) — mirrors Android `DemoServerDefaults`.
enum DemoServerDefaults {
    static let mailHost = "172.16.17.35"
    static let username = "local1@cts.com"
    static let password = "Test@123!"
    static let incomingPortIMAP = "993"
    static let smtpPortSMTPS = "465"
    static let defaultCalDavURL = "https://172.16.17.35/calendar/users/local1@cts.com/calendar"
}
