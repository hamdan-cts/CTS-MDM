import Foundation

/// URLSession that mirrors Android `OkHttpFactory` when `trustPrivateCerts` is true.
final class InsecureURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let trustAll: Bool

    init(trustAll: Bool) {
        self.trustAll = trustAll
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        guard trustAll,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func session(for config: PersistedAccountConfig) -> URLSession {
        let d = InsecureURLSessionDelegate(trustAll: config.trustPrivateCerts)
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c, delegate: d, delegateQueue: nil)
    }
}
