import Foundation
import UIKit

#if canImport(MailCore2)
import MailCore2
#else
import MailCore
#endif

private func makeResult<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}

/// Native port of Android `MailEngine` using MailCore2 (IMAP/POP3/SMTP).
final class MailEngine: @unchecked Sendable {
    init() {}

    // MARK: - Sessions

    private func imapSession(_ c: PersistedAccountConfig) -> MCOIMAPSession {
        let s = MCOIMAPSession()
        s.hostname = c.incomingHost
        s.port = UInt32(c.incomingPort)
        s.username = c.username
        s.password = c.password
        s.connectionType = .TLS
        s.isCheckCertificateEnabled = !c.trustPrivateCerts
        return s
    }

    private func popSession(_ c: PersistedAccountConfig) -> MCOPOPSession {
        let s = MCOPOPSession()
        s.hostname = c.incomingHost
        s.port = UInt32(c.incomingPort)
        s.username = c.username
        s.password = c.password
        s.connectionType = .TLS
        s.isCheckCertificateEnabled = !c.trustPrivateCerts
        return s
    }

    private func smtpSession(_ c: PersistedAccountConfig) -> MCOSMTPSession {
        let s = MCOSMTPSession()
        s.hostname = c.smtpHost
        s.port = UInt32(c.smtpPort)
        s.username = c.username
        s.password = c.password
        s.isCheckCertificateEnabled = !c.trustPrivateCerts
        if c.smtpSsl {
            s.connectionType = .TLS
        } else if c.smtpStartTls {
            s.connectionType = .startTLS
        } else {
            s.connectionType = .clear
        }
        return s
    }

    // MARK: - Test / folders

    func testIncoming(config: PersistedAccountConfig) async -> Result<[String], Error> {
        do {
            let folders = try await listFolders(config: config)
            return .success(Array(folders.prefix(25)))
        } catch {
            return .failure(error)
        }
    }

    func listFolders(config: PersistedAccountConfig) async throws -> [String] {
        switch config.incomingProtocol {
        case .POP3:
            return ["INBOX"]
        case .IMAP:
            let s = imapSession(config)
            return try await withCheckedThrowingContinuation { cont in
                guard let op = s.fetchAllFoldersOperation() else {
                    cont.resume(throwing: NSError(domain: "Mail", code: 0, userInfo: [NSLocalizedDescriptionKey: "No folder op"]))
                    return
                }
                op.start { err, folders in
                    if let err { cont.resume(throwing: err); return }
                    let paths = (folders as? [MCOIMAPFolder])?.map(\.path).filter { !$0.isEmpty } ?? []
                    cont.resume(returning: paths)
                }
            }
        }
    }

    // MARK: - Summaries

    func fetchMessageSummaries(
        config: PersistedAccountConfig,
        folderFullName: String,
        maxMessages: Int = 60,
    ) async -> Result<[MailMessageSummary], Error> {
        do {
            switch config.incomingProtocol {
            case .POP3:
                return .success(try await fetchPopSummaries(config: config, maxMessages: maxMessages))
            case .IMAP:
                return .success(try await fetchImapSummaries(config: config, folder: folderFullName, maxMessages: maxMessages))
            }
        } catch {
            return .failure(error)
        }
    }

    private func fetchImapSummaries(config: PersistedAccountConfig, folder: String, maxMessages: Int) async throws -> [MailMessageSummary] {
        let s = imapSession(config)
        let info: MCOIMAPFolderInfo = try await withCheckedThrowingContinuation { cont in
            s.folderInfoOperation(folder).start { err, inf in
                if let err { cont.resume(throwing: err); return }
                guard let inf else {
                    cont.resume(throwing: NSError(domain: "Mail", code: 1, userInfo: [NSLocalizedDescriptionKey: "No folder info"]))
                    return
                }
                cont.resume(returning: inf)
            }
        }
        let count = info.messageCount
        if count == 0 { return [] }
        let take = min(maxMessages, count)
        let start = max(1, count - take + 1)
        let numbers = MCOIndexSet(range: MCORange(location: UInt64(start), length: UInt64(take)))
        let msgs: [MCOIMAPMessage] = try await withCheckedThrowingContinuation { cont in
            s.fetchMessagesByNumberOperation(withFolder: folder, requestKind: [.headers, .structure, .flags], numbers: numbers).start { err, arr, _ in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (arr as? [MCOIMAPMessage]) ?? [])
            }
        }
        return msgs.reversed().map { self.mapImapSummary(folder: folder, msg: $0) }
    }

    private func fetchPopSummaries(config: PersistedAccountConfig, maxMessages: Int) async throws -> [MailMessageSummary] {
        let s = popSession(config)
        let infos: [MCOPOPMessageInfo] = try await withCheckedThrowingContinuation { cont in
            s.fetchMessagesOperation().start { err, arr in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (arr as? [MCOPOPMessageInfo]) ?? [])
            }
        }
        let tail = Array(infos.suffix(maxMessages))
        var rows: [MailMessageSummary] = []
        for info in tail.reversed() {
            let hdr: MCOMessageHeader = try await withCheckedThrowingContinuation { cont in
                s.fetchHeaderOperation(withIndex: info.index).start { err, h in
                    if let err { cont.resume(throwing: err); return }
                    guard let h else {
                        cont.resume(throwing: NSError(domain: "Mail", code: 2, userInfo: [NSLocalizedDescriptionKey: "No header"]))
                        return
                    }
                    cont.resume(returning: h)
                }
            }
            let subj = hdr.subject ?? "(No subject)"
            let from = self.formatAddresses(hdr.from)
            let seen = true
            rows.append(
                MailMessageSummary(
                    folderFullName: "INBOX",
                    serverKey: info.index,
                    subject: subj,
                    from: from,
                    sentDate: hdr.date,
                    seen: seen,
                    flagged: false,
                    hasAttachment: false,
                ),
            )
        }
        return rows
    }

    private func mapImapSummary(folder: String, msg: MCOIMAPMessage) -> MailMessageSummary {
        let subj = msg.header.subject ?? "(No subject)"
        let from = formatAddresses(msg.header.from)
        let seen = msg.flags.contains(.seen)
        let flagged = msg.flags.contains(.flagged)
        let mime = msg.mainPart?.mimeType?.lowercased() ?? ""
        let hasAtt = mime.contains("multipart/")
        return MailMessageSummary(
            folderFullName: folder,
            serverKey: msg.uid,
            subject: subj,
            from: from,
            sentDate: msg.header.date,
            seen: seen,
            flagged: flagged,
            hasAttachment: hasAtt,
        )
    }

    // MARK: - Detail

    func fetchMessageDetail(
        config: PersistedAccountConfig,
        folderFullName: String,
        serverKey: UInt32,
        markAsRead: Bool = true,
    ) async -> Result<MailMessageDetail, Error> {
        await makeResult {
            switch config.incomingProtocol {
            case .IMAP:
                try await fetchImapDetail(config: config, folder: folderFullName, uid: serverKey, markAsRead: markAsRead)
            case .POP3:
                try await fetchPopDetail(config: config, index: serverKey, markAsRead: markAsRead)
            }
        }
    }

    private func fetchImapDetail(config: PersistedAccountConfig, folder: String, uid: UInt32, markAsRead: Bool) async throws -> MailMessageDetail {
        let s = imapSession(config)
        if markAsRead {
            let uids = MCOIndexSet(index: uid)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.storeFlagsOperation(withFolder: folder, uids: uids, kind: .add, flags: .seen).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            s.fetchMessageOperation(withFolder: folder, uid: uid).start { err, d in
                if let err { cont.resume(throwing: err); return }
                guard let d = d as? Data else {
                    cont.resume(throwing: NSError(domain: "Mail", code: 3, userInfo: [NSLocalizedDescriptionKey: "Empty message"]))
                    return
                }
                cont.resume(returning: d)
            }
        }
        return try parseDetail(folder: folder, serverKey: uid, data: data)
    }

    private func fetchPopDetail(config: PersistedAccountConfig, index: UInt32, markAsRead: Bool) async throws -> MailMessageDetail {
        let s = popSession(config)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            s.fetchMessageOperation(withIndex: index).start { err, d in
                if let err { cont.resume(throwing: err); return }
                guard let d = d as? Data else {
                    cont.resume(throwing: NSError(domain: "Mail", code: 4, userInfo: [NSLocalizedDescriptionKey: "Empty message"]))
                    return
                }
                cont.resume(returning: d)
            }
        }
        _ = markAsRead
        return try parseDetail(folder: "INBOX", serverKey: index, data: data)
    }

    private func parseDetail(folder: String, serverKey: UInt32, data: Data) throws -> MailMessageDetail {
        guard let p = MCOMessageParser(data: data) else {
            throw NSError(domain: "Mail", code: 5, userInfo: [NSLocalizedDescriptionKey: "Parse failed"])
        }
        let hdr = p.header
        let plain = p.plainTextBodyRendering() ?? ""
        let html = p.htmlBodyRendering()
        let fromStr = formatAddresses(hdr.from)
        let toStr = formatAddresses(hdr.to)
        let ccStr = formatAddresses(hdr.cc)
        let fromEmails = addressesArray(hdr.from).compactMap(\.mailbox)
        let replyToEmails = addressesArray(hdr.replyTo).compactMap(\.mailbox)
        let toEmails = addressesArray(hdr.to).compactMap(\.mailbox)
        let ccEmails = addressesArray(hdr.cc).compactMap(\.mailbox)
        let atts = (p.attachments() as? [MCOAttachment])?.compactMap { att -> MailAttachment? in
            guard let d = att.data else { return nil }
            let name = att.filename ?? "attachment"
            let mime = att.mimeType ?? "application/octet-stream"
            return MailAttachment(fileName: name, mimeType: mime, sizeBytes: d.count, data: d)
        } ?? []
        return MailMessageDetail(
            folderFullName: folder,
            serverKey: serverKey,
            subject: hdr.subject ?? "(No subject)",
            from: fromStr,
            to: toStr,
            cc: ccStr,
            date: hdr.date,
            flagged: false,
            seen: true,
            bodyPlain: plain,
            bodyHtml: html,
            fromEmails: fromEmails,
            replyToEmails: replyToEmails,
            toEmails: toEmails,
            ccEmails: ccEmails,
            attachments: atts,
        )
    }

    // MARK: - SMTP

    func testSmtp(config: PersistedAccountConfig) async -> Result<Void, Error> {
        await makeResult {
            let s = smtpSession(config)
            let from = MCOAddress(mailbox: config.username)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.checkAccountOperation(withFrom: from).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
    }

    func sendMessage(
        config: PersistedAccountConfig,
        to: String,
        subject: String,
        body: String,
        cc: String? = nil,
        bcc: String? = nil,
        attachments: [OutboundAttachment] = [],
        bodyIsHtml: Bool = false,
        requestReadReceipt: Bool = false,
        highImportance: Bool = false,
    ) async -> Result<Void, Error> {
        await makeResult {
            let builder = MCOMessageBuilder()
            builder.header.from = MCOAddress(mailbox: config.username)
            builder.header.to = parseAddresses(to)
            if let cc, !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                builder.header.cc = parseAddresses(cc)
            }
            if let bcc, !bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                builder.header.bcc = parseAddresses(bcc)
            }
            builder.header.subject = subject
            if requestReadReceipt {
                let r = MCOAddress(mailbox: config.username).nonEncodedRFC822String()
                builder.header.setExtraHeaderValue(r, forName: "Disposition-Notification-To")
                builder.header.setExtraHeaderValue(r, forName: "Return-Receipt-To")
            }
            if highImportance {
                builder.header.setExtraHeaderValue("1", forName: "X-Priority")
                builder.header.setExtraHeaderValue("high", forName: "Importance")
                builder.header.setExtraHeaderValue("urgent", forName: "Priority")
            }
            if attachments.isEmpty && !bodyIsHtml {
                builder.textBody = body
            } else if attachments.isEmpty && bodyIsHtml {
                builder.htmlBody = body
                let plain = stripHTML(body).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                builder.textBody = plain.isEmpty ? " " : plain
            } else if !attachments.isEmpty && !bodyIsHtml {
                builder.textBody = body
                for a in attachments {
                    let att = MCOAttachment()
                    att.mimeType = a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType
                    att.filename = a.fileName
                    att.data = a.data
                    builder.addAttachment(att)
                }
            } else {
                builder.htmlBody = body
                builder.textBody = stripHTML(body).isEmpty ? " " : stripHTML(body)
                for a in attachments {
                    let att = MCOAttachment()
                    att.mimeType = a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType
                    att.filename = a.fileName
                    att.data = a.data
                    builder.addAttachment(att)
                }
            }
            guard let rfc = builder.data() else {
                throw NSError(domain: "Mail", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not build message"])
            }
            let s = smtpSession(config)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.sendOperation(with: rfc).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
    }

    func appendDraftToImapFolder(
        config: PersistedAccountConfig,
        draftsFolderFullName: String,
        to: String,
        cc: String?,
        bcc: String?,
        subject: String,
        bodyHtml: String,
        attachments: [OutboundAttachment],
    ) async -> Result<Void, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else {
                throw NSError(domain: "Mail", code: 7, userInfo: [NSLocalizedDescriptionKey: "IMAP required for server drafts"])
            }
            let builder = MCOMessageBuilder()
            builder.header.from = MCOAddress(mailbox: config.username)
            let toTrim = to.trimmingCharacters(in: .whitespacesAndNewlines)
            if !toTrim.isEmpty {
                builder.header.to = parseAddresses(toTrim)
            } else {
                builder.header.to = [MCOAddress(mailbox: config.username)]
            }
            if let cc, !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { builder.header.cc = parseAddresses(cc) }
            if let bcc, !bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { builder.header.bcc = parseAddresses(bcc) }
            builder.header.subject = subject.isEmpty ? "(Draft)" : subject
            builder.htmlBody = bodyHtml
            let plain = stripHTML(bodyHtml)
            builder.textBody = plain.isEmpty ? " " : plain
            for a in attachments {
                let att = MCOAttachment()
                att.mimeType = a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType
                att.filename = a.fileName
                att.data = a.data
                builder.addAttachment(att)
            }
            guard let rfc = builder.data() else {
                throw NSError(domain: "Mail", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not build draft"])
            }
            let s = imapSession(config)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.appendMessageOperation(withFolder: draftsFolderFullName, messageData: rfc, flags: .draft).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
    }

    // MARK: - Folder counts

    func getFolderMessageCount(config: PersistedAccountConfig, folderFullName: String) async -> Result<Int, Error> {
        await makeResult {
            switch config.incomingProtocol {
            case .POP3:
                guard folderFullName.uppercased() == "INBOX" else { return 0 }
                let s = popSession(config)
                let infos: [MCOPOPMessageInfo] = try await withCheckedThrowingContinuation { cont in
                    s.fetchMessagesOperation().start { err, arr in
                        if let err { cont.resume(throwing: err) }
                        else { cont.resume(returning: (arr as? [MCOPOPMessageInfo]) ?? []) }
                    }
                }
                return infos.count
            case .IMAP:
                let s = imapSession(config)
                let info: MCOIMAPFolderInfo = try await withCheckedThrowingContinuation { cont in
                    s.folderInfoOperation(folderFullName).start { err, inf in
                        if let err { cont.resume(throwing: err) }
                        else if let inf { cont.resume(returning: inf) }
                        else { cont.resume(throwing: NSError(domain: "Mail", code: 9, userInfo: [NSLocalizedDescriptionKey: "No folder"])) }
                    }
                }
                return info.messageCount
            }
        }
    }

    func getFolderUnreadMessageCount(config: PersistedAccountConfig, folderFullName: String) async -> Result<Int, Error> {
        await makeResult {
            switch config.incomingProtocol {
            case .POP3:
                return 0
            case .IMAP:
                let s = imapSession(config)
                let st: MCOIMAPFolderStatus = try await withCheckedThrowingContinuation { cont in
                    s.folderStatusOperation(folderFullName).start { err, st in
                        if let err { cont.resume(throwing: err) }
                        else if let st { cont.resume(returning: st) }
                        else { cont.resume(throwing: NSError(domain: "Mail", code: 10, userInfo: [NSLocalizedDescriptionKey: "No status"])) }
                    }
                }
                return Int(st.unseenCount)
            }
        }
    }

    // MARK: - IMAP folder ops

    func createImapFolder(config: PersistedAccountConfig, parentFullName: String, childName: String) async -> Result<String, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else {
                throw NSError(domain: "Mail", code: 11, userInfo: [NSLocalizedDescriptionKey: "Folders require IMAP"])
            }
            let folders = try await listFolders(config: config)
            let sep = imapDelimiter(from: folders)
            let clean = childName.replacingOccurrences(of: String(sep), with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                throw NSError(domain: "Mail", code: 12, userInfo: [NSLocalizedDescriptionKey: "Empty folder name"])
            }
            let full: String
            if parentFullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                full = clean
            } else {
                full = "\(parentFullName)\(sep)\(clean)"
            }
            let s = imapSession(config)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.createFolderOperation(full).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
            return full
        }
    }

    func renameImapFolder(config: PersistedAccountConfig, oldFullName: String, newLeafName: String) async -> Result<String, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else {
                throw NSError(domain: "Mail", code: 13, userInfo: [NSLocalizedDescriptionKey: "Folders require IMAP"])
            }
            let folders = try await listFolders(config: config)
            let sep = imapDelimiter(from: folders)
            let clean = newLeafName.replacingOccurrences(of: String(sep), with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                throw NSError(domain: "Mail", code: 14, userInfo: [NSLocalizedDescriptionKey: "Empty name"])
            }
            let parent = parentPathString(oldFullName, delimiter: sep)
            let newFull = parent.isEmpty ? clean : "\(parent)\(sep)\(clean)"
            let s = imapSession(config)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.renameFolderOperation(oldFullName, otherName: clean).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
            return newFull
        }
    }

    func moveImapFolderUnderParent(config: PersistedAccountConfig, folderFullName: String, newParentFullName: String) async -> Result<String, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else {
                throw NSError(domain: "Mail", code: 15, userInfo: [NSLocalizedDescriptionKey: "Folders require IMAP"])
            }
            if folderFullName.uppercased() == "INBOX" {
                throw NSError(domain: "Mail", code: 16, userInfo: [NSLocalizedDescriptionKey: "Cannot move INBOX"])
            }
            let folders = try await listFolders(config: config)
            let sep = imapDelimiter(from: folders)
            let leaf: String
            if let idx = folderFullName.lastIndex(of: sep) {
                leaf = String(folderFullName[folderFullName.index(after: idx)...])
            } else {
                leaf = folderFullName
            }
            guard !leaf.isEmpty else {
                throw NSError(domain: "Mail", code: 17, userInfo: [NSLocalizedDescriptionKey: "Could not determine folder name"])
            }
            func isUnder(_ child: String, _ ancestor: String) -> Bool {
                if ancestor.isEmpty { return false }
                return child == ancestor || child.hasPrefix("\(ancestor)/") || child.hasPrefix("\(ancestor).")
            }
            if isUnder(newParentFullName, folderFullName) {
                throw NSError(domain: "Mail", code: 18, userInfo: [NSLocalizedDescriptionKey: "Cannot move under itself or a subfolder"])
            }
            let newFull: String
            if newParentFullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newFull = leaf
            } else {
                newFull = "\(newParentFullName)\(sep)\(leaf)"
            }
            if newFull == folderFullName {
                throw NSError(domain: "Mail", code: 19, userInfo: [NSLocalizedDescriptionKey: "Already in that location"])
            }
            let s = imapSession(config)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.renameFolderOperation(folderFullName, otherName: newFull).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
            return newFull
        }
    }

    private func parentPathString(_ full: String, delimiter: Character) -> String {
        if let idx = full.lastIndex(of: delimiter) {
            return String(full[..<idx])
        }
        if let idx = full.lastIndex(of: "/") { return String(full[..<idx]) }
        if let idx = full.lastIndex(of: ".") { return String(full[..<idx]) }
        return ""
    }

    private func imapDelimiter(from folders: [String]) -> Character {
        if folders.contains(where: { $0.contains("/") }) { return "/" }
        if folders.contains(where: { $0.contains(".") }) { return "." }
        return "."
    }

    // MARK: - Message ops (IMAP)

    func moveMessage(config: PersistedAccountConfig, fromFolder: String, serverKey: UInt32, toFolder: String) async -> Result<Void, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else {
                throw NSError(domain: "Mail", code: 20, userInfo: [NSLocalizedDescriptionKey: "Move requires IMAP"])
            }
            let s = imapSession(config)
            let uids = MCOIndexSet(index: serverKey)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.moveMessagesOperation(withFolder: fromFolder, uids: uids, destFolder: toFolder).start { err, _ in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
    }

    func deleteMessageInFolder(config: PersistedAccountConfig, folderFullName: String, serverKey: UInt32) async -> Result<Void, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else {
                throw NSError(domain: "Mail", code: 21, userInfo: [NSLocalizedDescriptionKey: "Delete in folder requires IMAP"])
            }
            let s = imapSession(config)
            let uids = MCOIndexSet(index: serverKey)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.storeFlagsOperation(withFolder: folderFullName, uids: uids, kind: .add, flags: .deleted).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.expungeOperation(folderFullName).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
    }

    func setMessageFlagged(config: PersistedAccountConfig, folderFullName: String, serverKey: UInt32, flagged: Bool) async -> Result<Void, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else { return () }
            guard config.incomingProtocol == .IMAP else { return () }
            let s = imapSession(config)
            let uids = MCOIndexSet(index: serverKey)
            let kind: MCOIMAPStoreFlagsRequestKind = flagged ? .add : .remove
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.storeFlagsOperation(withFolder: folderFullName, uids: uids, kind: kind, flags: .flagged).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
    }

    func setMessageSeen(config: PersistedAccountConfig, folderFullName: String, serverKey: UInt32, seen: Bool) async -> Result<Void, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP else { return () }
            let s = imapSession(config)
            let uids = MCOIndexSet(index: serverKey)
            let kind: MCOIMAPStoreFlagsRequestKind = seen ? .add : .remove
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                s.storeFlagsOperation(withFolder: folderFullName, uids: uids, kind: kind, flags: .seen).start { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        }
    }

    func applySenderMoveRules(
        config: PersistedAccountConfig,
        inboxFolderName: String,
        rules: [SenderMoveRule],
        maxMoves: Int = 40,
    ) async -> Result<Int, Error> {
        await makeResult {
            guard config.incomingProtocol == .IMAP, !rules.isEmpty else { return 0 }
            var total = 0
            let cap = min(max(maxMoves, 1), 80)
            for _ in 0..<cap {
                let batch = try await fetchImapSummaries(config: config, folder: inboxFolderName, maxMessages: 200)
                guard let victim = batch.first(where: { m in
                    rules.contains { r in
                        r.matchesMessageFrom(fromHeader: m.from)
                            && !r.targetFolder.caseInsensitiveCompare(inboxFolderName).isOrderedSame
                    }
                }) else { break }
                guard let rule = rules.first(where: {
                    $0.matchesMessageFrom(fromHeader: victim.from)
                        && !$0.targetFolder.caseInsensitiveCompare(inboxFolderName).isOrderedSame
                }) else { break }
                try await moveMessage(config: config, fromFolder: inboxFolderName, serverKey: victim.serverKey, toFolder: rule.targetFolder).get()
                total += 1
            }
            return total
        }
    }

    func sendAutoRepliesForUnread(
        config: PersistedAccountConfig,
        summaries: [MailMessageSummary],
        replySubject: String,
        replyBody: String,
        store: AutoReplyStore,
        maxSends: Int = 5,
    ) async -> Result<Int, Error> {
        await makeResult {
            guard store.isEnabled, store.isWithinScheduledWindow() else { return 0 }
            let subj = replySubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Automatic reply" : replySubject
            let text = replyBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : replyBody
            var sent = 0
            let cap = min(max(maxSends, 0), 15)
            for m in summaries {
                if sent >= cap { break }
                if m.seen { continue }
                guard let peer = FromAddressParser.parsePrimaryEmail(fromHeader: m.from) else { continue }
                if peer.caseInsensitiveCompare(config.username.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame { continue }
                guard store.consumeVacationSlotForSender(senderLower: peer) else { continue }
                let r = await sendMessage(
                    config: config,
                    to: peer,
                    subject: subj,
                    body: text,
                    bodyIsHtml: false,
                )
                switch r {
                case .success:
                    sent += 1
                case .failure:
                    store.releaseVacationSlotForSender(senderLower: peer)
                }
            }
            return sent
        }
    }

    // MARK: - Helpers

    private func formatAddresses(_ v: Any?) -> String {
        addressesArray(v).map { $0.nonEncodedRFC822String() }.joined(separator: ", ")
    }

    private func addressesArray(_ v: Any?) -> [MCOAddress] {
        if let a = v as? MCOAddress { return [a] }
        if let arr = v as? [MCOAddress] { return arr }
        if let arr = v as? NSArray {
            return (0..<arr.count).compactMap { arr[$0] as? MCOAddress }
        }
        return []
    }

    private func parseAddresses(_ raw: String) -> [MCOAddress] {
        raw.split(separator: ",").compactMap { piece -> MCOAddress? in
            let t = String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if let r1 = t.range(of: "<"), let r2 = t.range(of: ">", range: r1.upperBound..<t.endIndex) {
                let mail = String(t[r1.upperBound..<r2])
                let dn = String(t[..<r1.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return MCOAddress(displayName: dn.isEmpty ? nil : dn, mailbox: mail)
            }
            return MCOAddress(mailbox: t)
        }
    }

    private func stripHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        if let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil,
        ) {
            return attr.string
        }
        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }
}
