import Foundation

/// CalDAV client mirroring Android `RemoteCalendarSync` (probe, fetch embedded events, create/delete).
final class RemoteCalendarSync: @unchecked Sendable {
    struct CalDavProbeResult: Equatable {
        let statusCode: Int
        let snippet: String
    }

    struct IcalEventPreview: Identifiable, Equatable {
        var id: String { resourceHref ?? "\(title)|\(startInfo)" }
        let title: String
        let startInfo: String
        let resourceHref: String?
        let etag: String?
        let startEpochMillis: Int64?
        let endEpochMillis: Int64?
        let isAllDay: Bool
    }

    private static let userAgent = "MTDE-Mail/1.0 (iOS; CalDAV client)"
    private static let successCodes: Set<Int> = [200, 207]

    private static let propfindSimple = """
    <?xml version="1.0" encoding="utf-8"?>
    <propfind xmlns="DAV:">
      <prop>
        <resourcetype/>
        <displayname/>
      </prop>
    </propfind>
    """

    private static let calendarQuery = """
    <?xml version="1.0" encoding="utf-8"?>
    <C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:D="DAV:">
      <D:prop>
        <C:calendar-data/>
      </D:prop>
      <C:filter>
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            <C:time-range start="19700101T000000Z" end="20991231T235959Z"/>
          </C:comp-filter>
        </C:comp-filter>
      </C:filter>
    </C:calendar-query>
    """

    func probeCalDavCollection(config: PersistedAccountConfig) async -> Result<CalDavProbeResult, Error> {
        await makeCalResult {
            let url = try calDavCollectionBase(config)
            let session = InsecureURLSessionDelegate.session(for: config)
            var last = CalDavProbeResult(statusCode: 0, snippet: "")
            for base in [url, url.hasSuffix("/") ? url : url + "/"] {
                for xml in [Self.propfindSimple] {
                    for depth in ["0", "1"] {
                        for ct in ["text/xml; charset=utf-8", "application/xml; charset=utf-8"] {
                            last = try await propfindOnce(session: session, url: base, config: config, depth: depth, xml: xml, contentType: ct)
                            if Self.successCodes.contains(last.statusCode) { return last }
                        }
                    }
                }
            }
            return last
        }
    }

    func fetchCalDavEmbeddedEvents(config: PersistedAccountConfig, maxEvents: Int = 120) async -> Result<[IcalEventPreview], Error> {
        await makeCalResult {
            let session = InsecureURLSessionDelegate.session(for: config)
            let base = try calDavCollectionBase(config)
            let bases = [base, base.hasSuffix("/") ? base : base + "/"]
            var merged: [String: IcalEventPreview] = [:]
            func addAll(_ list: [IcalEventPreview]) {
                for e in list {
                    if merged.count >= maxEvents { return }
                    let key = "\(e.title)\u{0}\(e.startInfo)\u{0}\(e.resourceHref ?? "")"
                    if merged[key] == nil { merged[key] = e }
                }
            }
            for col in bases {
                addAll(try await reportCalendarQuery(session: session, collectionUrl: col, config: config, maxEvents: maxEvents))
                if merged.count >= maxEvents { break }
            }
            if merged.count < maxEvents {
                for col in bases {
                    addAll(try await propfindThenGetEvents(session: session, collectionUrl: col, config: config, maxEvents: maxEvents - merged.count))
                    if merged.count >= maxEvents { break }
                }
            }
            return Array(merged.values)
        }
    }

    func createCalendarEvent(
        config: PersistedAccountConfig,
        summary: String,
        dtStart: String,
        description: String? = nil,
        durationMinutes: Int = 60,
    ) async -> Result<String, Error> {
        await makeCalResult {
            let session = InsecureURLSessionDelegate.session(for: config)
            let base = try calDavCollectionBase(config)
            let col = base.hasSuffix("/") ? base : base + "/"
            let id = UUID().uuidString
            let fileName = "\(id).ics"
            let hostPart = config.username.split(separator: "@").last.map(String.init) ?? "local"
            let uid = "\(id)@\(hostPart)"
            let dur = min(max(durationMinutes, 1), 24 * 60)
            let descLine: String
            if let d = description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                descLine = "DESCRIPTION:\(escapeIcal(d))\r\n"
            } else {
                descLine = ""
            }
            let ics = """
            BEGIN:VCALENDAR\r
            VERSION:2.0\r
            PRODID:-//MTDE Mail//EN\r
            CALSCALE:GREGORIAN\r
            BEGIN:VEVENT\r
            UID:\(uid)\r
            DTSTAMP:\(icalUtcNow())\r
            DTSTART:\(dtStart)\r
            DURATION:PT\(dur)M\r
            SUMMARY:\(escapeIcal(summary.trimmingCharacters(in: .whitespacesAndNewlines)))\r
            \(descLine)END:VEVENT\r
            END:VCALENDAR\r
            """
            guard let url = URL(string: col)?.appendingPathComponent(fileName) else {
                throw NSError(domain: "CalDAV", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
            }
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(basicAuth(config: config), forHTTPHeaderField: "Authorization")
            req.setValue("*", forHTTPHeaderField: "If-None-Match")
            req.httpBody = ics.data(using: .utf8)
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "CalDAV", code: 2, userInfo: [NSLocalizedDescriptionKey: "PUT failed"])
            }
            return url.absoluteString
        }
    }

    func deleteCalendarEvent(config: PersistedAccountConfig, resourceHref: String, etag: String?) async -> Result<Void, Error> {
        await makeCalResult {
            let session = InsecureURLSessionDelegate.session(for: config)
            let base = try calDavCollectionBase(config)
            let col = base.hasSuffix("/") ? base : base + "/"
            let urlStr = resolveHref(collection: col, href: resourceHref)
            guard let url = URL(string: urlStr) else {
                throw NSError(domain: "CalDAV", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bad href"])
            }
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(basicAuth(config: config), forHTTPHeaderField: "Authorization")
            if let et = etag?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")), !et.isEmpty {
                req.setValue(et, forHTTPHeaderField: "If-Match")
            }
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "CalDAV", code: 4, userInfo: [NSLocalizedDescriptionKey: "DELETE failed"])
            }
            return ()
        }
    }

    // MARK: - Internals

    private func calDavCollectionBase(_ config: PersistedAccountConfig) throws -> String {
        let raw = config.caldavUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw NSError(domain: "CalDAV", code: 5, userInfo: [NSLocalizedDescriptionKey: "CalDAV URL empty"])
        }
        return normalizeDavUrl(resolveFortimailHostPlaceholder(raw, incomingHost: config.incomingHost))
    }

    private func normalizeDavUrl(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func resolveFortimailHostPlaceholder(_ raw: String, incomingHost: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = incomingHost.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        host = host.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        if host.isEmpty { return t }
        if t.hasPrefix("https:///") { return "https://\(host)/" + t.dropFirst("https:///".count) }
        if t.hasPrefix("http:///") { return "http://\(host)/" + t.dropFirst("http:///".count) }
        return t
    }

    private func basicAuth(config: PersistedAccountConfig) -> String {
        let raw = "\(config.username):\(config.password)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }

    private func propfindOnce(
        session: URLSession,
        url: String,
        config: PersistedAccountConfig,
        depth: String,
        xml: String,
        contentType: String,
    ) async throws -> CalDavProbeResult {
        guard let u = URL(string: url) else { return CalDavProbeResult(statusCode: 0, snippet: "bad url") }
        var req = URLRequest(url: u)
        req.httpMethod = "PROPFIND"
        req.httpBody = xml.data(using: .utf8)
        req.setValue(depth, forHTTPHeaderField: "Depth")
        req.setValue(basicAuth(config: config), forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("text/xml, application/xml, application/x-www-form-urlencoded, */*", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let snip = String(data: data, encoding: .utf8).map { String($0.prefix(500)) } ?? ""
            return CalDavProbeResult(statusCode: code, snippet: snip)
        } catch {
            return CalDavProbeResult(statusCode: 0, snippet: error.localizedDescription)
        }
    }

    private func reportCalendarQuery(
        session: URLSession,
        collectionUrl: String,
        config: PersistedAccountConfig,
        maxEvents: Int,
    ) async throws -> [IcalEventPreview] {
        guard let u = URL(string: collectionUrl) else { return [] }
        for depth in ["1", "infinity"] {
            var req = URLRequest(url: u)
            req.httpMethod = "REPORT"
            req.httpBody = Self.calendarQuery.data(using: .utf8)
            req.setValue(depth, forHTTPHeaderField: "Depth")
            req.setValue(basicAuth(config: config), forHTTPHeaderField: "Authorization")
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, Self.successCodes.contains(http.statusCode),
                  let xml = String(data: data, encoding: .utf8)
            else { continue }
            let blocks = extractCalendarDataBlocks(xml)
            var out: [IcalEventPreview] = []
            for b in blocks {
                out.append(contentsOf: parseIcsToPreviews(b, limit: maxEvents - out.count, href: nil, etag: nil))
                if out.count >= maxEvents { return out }
            }
        }
        return []
    }

    private func propfindThenGetEvents(
        session: URLSession,
        collectionUrl: String,
        config: PersistedAccountConfig,
        maxEvents: Int,
    ) async throws -> [IcalEventPreview] {
        if maxEvents <= 0 { return [] }
        guard let u = URL(string: collectionUrl) else { return [] }
        var req = URLRequest(url: u)
        req.httpMethod = "PROPFIND"
        req.httpBody = Self.propfindSimple.data(using: .utf8)
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue(basicAuth(config: config), forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, Self.successCodes.contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8)
        else { return [] }
        let hrefs = extractDavHrefs(xml)
        var merged: [IcalEventPreview] = []
        for href in hrefs {
            if merged.count >= maxEvents { break }
            let resolved = resolveHref(collection: collectionUrl, href: href)
            guard looksLikeCalendarObject(resolved: resolved, collection: collectionUrl) else { continue }
            guard let urlResolved = URL(string: resolved) else { continue }
            var greq = URLRequest(url: urlResolved)
            greq.setValue(basicAuth(config: config), forHTTPHeaderField: "Authorization")
            greq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (gdata, gresp) = try await session.data(for: greq)
            guard let gr = gresp as? HTTPURLResponse, gr.statusCode == 200,
                  let ics = String(data: gdata, encoding: .utf8), ics.contains("BEGIN:VEVENT")
            else { continue }
            let etag = gr.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            merged.append(contentsOf: parseIcsToPreviews(ics, limit: maxEvents - merged.count, href: resolved, etag: etag))
        }
        return merged
    }

    private func looksLikeCalendarObject(resolved: String, collection: String) -> Bool {
        let r = resolved.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let c = collection.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if r == c { return false }
        return r.hasPrefix(c + "/") && r.count > c.count + 1
    }

    private func resolveHref(collection: String, href: String) -> String {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.lowercased().hasPrefix("http://") || h.lowercased().hasPrefix("https://") { return h }
        if let base = URL(string: collection), let r = URL(string: h, relativeTo: base) {
            return r.absoluteString
        }
        return collection
    }

    private func extractDavHrefs(_ xml: String) -> [String] {
        var out: [String] = []
        let pattern = try? NSRegularExpression(pattern: "<href[^>]*>([^<]+)</href>", options: [.caseInsensitive])
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        pattern?.enumerateMatches(in: xml, options: [], range: range) { m, _, _ in
            guard let m, m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: xml) else { return }
            let t = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
        }
        return out
    }

    private func extractCalendarDataBlocks(_ xml: String) -> [String] {
        var blocks: [String] = []
        let pattern = try? NSRegularExpression(
            pattern: "<calendar-data[^>]*>([\\s\\S]*?)</calendar-data>",
            options: [.caseInsensitive],
        )
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        pattern?.enumerateMatches(in: xml, options: [], range: range) { m, _, _ in
            guard let m, m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: xml) else { return }
            let inner = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.contains("BEGIN:VCALENDAR") { blocks.append(inner) }
        }
        return blocks
    }

    private func parseIcsToPreviews(_ ics: String, limit: Int, href: String?, etag: String?) -> [IcalEventPreview] {
        if limit <= 0 { return [] }
        var out: [IcalEventPreview] = []
        let events = ics.components(separatedBy: "BEGIN:VEVENT")
        for chunk in events.dropFirst() {
            if out.count >= limit { break }
            guard let end = chunk.range(of: "END:VEVENT") else { continue }
            let body = String(chunk[..<end.lowerBound])
            let title = lineValue(body, key: "SUMMARY") ?? "(No title)"
            let start = lineValue(body, key: "DTSTART") ?? ""
            out.append(
                IcalEventPreview(
                    title: title,
                    startInfo: start,
                    resourceHref: href,
                    etag: etag,
                    startEpochMillis: nil,
                    endEpochMillis: nil,
                    isAllDay: start.count == 8 && start.allSatisfy { $0.isNumber },
                ),
            )
        }
        return out
    }

    private func lineValue(_ block: String, key: String) -> String? {
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.uppercased().hasPrefix("\(key.uppercased()):") {
                return String(t.dropFirst("\(key):".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func escapeIcal(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    private func icalUtcNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: Date())
    }
}

private func makeCalResult<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
