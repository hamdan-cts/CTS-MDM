import SwiftUI
import WebKit

struct MessageDetailView: View {
    let config: PersistedAccountConfig
    let folderFullName: String
    let serverKey: UInt32
    let mail: MailEngine
    var onClose: () -> Void
    var draftsFolderFullName: String?
    var onDraftSaved: () -> Void = {}

    @State private var detail: MailMessageDetail?
    @State private var loading = true
    @State private var error: String?
    @State private var composeIntent: ComposeIntent?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("Loading…") }
                else if let errMsg = error { Text(errMsg).foregroundStyle(.red) }
                else if let d = detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(d.from).font(.subheadline)
                            Text("To: \(d.to)").font(.caption)
                            if !d.cc.isEmpty { Text("Cc: \(d.cc)").font(.caption) }
                            Divider()
                            if let html = d.bodyHtml, !html.isEmpty {
                                MailHTMLView(html: html)
                                    .frame(minHeight: 280)
                            } else {
                                Text(d.bodyPlain)
                                    .font(.body)
                            }
                            if !d.attachments.isEmpty {
                                Text("Attachments").font(.headline)
                                ForEach(d.attachments, id: \.fileName) { a in
                                    Text("\(a.fileName) (\(a.sizeBytes) bytes)")
                                        .font(.caption)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(detail?.subject ?? "Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { onClose() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if detail != nil {
                        Button("Reply") { if let d = detail { composeIntent = .reply(d) } }
                        Button("Forward") { if let d = detail { composeIntent = .forward(d) } }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $composeIntent) { intent in
            ComposeEmailView(
                intent: intent,
                config: config,
                mail: mail,
                draftsFolderFullName: draftsFolderFullName,
                onDraftSaved: onDraftSaved,
                onDismiss: { composeIntent = nil },
                onSent: {
                    composeIntent = nil
                    Task { await load() }
                },
            )
        }
    }

    private func load() async {
        loading = true
        error = nil
        let r = await mail.fetchMessageDetail(config: config, folderFullName: folderFullName, serverKey: serverKey)
        await MainActor.run {
            loading = false
            switch r {
            case .success(let d): detail = d
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}

private struct MailHTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.backgroundColor = .clear
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.loadHTMLString(html, baseURL: nil)
    }
}
