import SwiftUI
import UIKit

struct ComposeEmailView: View {
    let intent: ComposeIntent
    let config: PersistedAccountConfig
    let mail: MailEngine
    var draftsFolderFullName: String?
    var onDraftSaved: () -> Void = {}
    var onDismiss: () -> Void
    var onSent: () -> Void

    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var requestReadReceipt = false
    @State private var highImportance = false

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("To", text: $to)
                    TextField("Cc", text: $cc)
                    TextField("Bcc", text: $bcc)
                    TextField("Subject", text: $subject)
                }
                Section("Message") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 180)
                }
                Section {
                    Toggle("Request read receipt", isOn: $requestReadReceipt)
                    Toggle("High importance", isOn: $highImportance)
                }
                if let sendError {
                    Section { Text(sendError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await saveDraftIfNeeded(); onDismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(sending || to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: applyIntent)
        }
    }

    private var title: String {
        switch intent {
        case .new: return "Compose"
        case .reply: return "Reply"
        case .replyAll: return "Reply all"
        case .forward: return "Forward"
        }
    }

    private func applyIntent() {
        sendError = nil
        switch intent {
        case .new:
            to = ""
            cc = ""
            bcc = ""
            subject = ""
            bodyText = ""
        case .reply(let d):
            to = ComposeLogic.replyToAddress(d)
            cc = ""
            bcc = ""
            subject = ComposeLogic.replySubject(d.subject)
            bodyText = ComposeLogic.quoteForReply(d, dateFmt: dateFmt)
        case .replyAll(let d):
            let p = ComposeLogic.replyAllRecipients(d, config: config)
            to = p.0
            cc = p.1
            bcc = ""
            subject = ComposeLogic.replySubject(d.subject)
            bodyText = ComposeLogic.quoteForReply(d, dateFmt: dateFmt)
        case .forward(let d):
            to = ""
            cc = ""
            bcc = ""
            subject = ComposeLogic.forwardSubject(d.subject)
            bodyText = stripTags(ComposeLogic.forwardBodyHtml(d, dateFmt: dateFmt))
        }
    }

    private func stripTags(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil,
              )
        else { return html }
        return attr.string
    }

    private func send() async {
        sending = true
        sendError = nil
        let body: String
        let bodyIsHtml: Bool
        switch intent {
        case .forward(let d):
            body = ComposeLogic.forwardBodyHtml(d, dateFmt: dateFmt)
            bodyIsHtml = true
        default:
            body = bodyText
            bodyIsHtml = false
        }
        let r = await mail.sendMessage(
            config: config,
            to: to,
            subject: subject,
            body: body,
            cc: cc.isEmpty ? nil : cc,
            bcc: bcc.isEmpty ? nil : bcc,
            attachments: [],
            bodyIsHtml: bodyIsHtml,
            requestReadReceipt: requestReadReceipt,
            highImportance: highImportance,
        )
        await MainActor.run {
            sending = false
            switch r {
            case .failure(let e): sendError = e.localizedDescription
            case .success: onSent()
            }
        }
    }

    private func saveDraftIfNeeded() async {
        guard config.incomingProtocol == .IMAP,
              let folder = draftsFolderFullName?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty
        else { return }
        let html = "<pre>\(bodyText.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</pre>"
        let meaningful = !to.isEmpty || !cc.isEmpty || !bcc.isEmpty || !subject.isEmpty || !bodyText.isEmpty
        guard meaningful else { return }
        _ = await mail.appendDraftToImapFolder(
            config: config,
            draftsFolderFullName: folder,
            to: to,
            cc: cc.isEmpty ? nil : cc,
            bcc: bcc.isEmpty ? nil : bcc,
            subject: subject,
            bodyHtml: html,
            attachments: [],
        )
        onDraftSaved()
    }
}
