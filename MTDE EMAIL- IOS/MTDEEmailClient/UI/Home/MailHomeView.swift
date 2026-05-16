import SwiftUI

struct MailHomeView: View {
    @EnvironmentObject private var app: AppState
    private let mail = MailEngine()

    @State private var primary: PrimarySection = .mail
    @State private var selectedTab: MailFolderTab = .inbox
    @State private var customFolder: String?
    @State private var folders: [String] = []
    @State private var messages: [MailMessageSummary] = []
    @State private var loadingMessages = false
    @State private var error: String?
    @State private var search = ""
    @State private var refreshNonce = 0

    @State private var showAddAccount = false
    @State private var selectedMessage: SelectedMessage?
    @State private var composeIntent: ComposeIntent?
    @State private var showRules = false
    @State private var showAutoReply = false

    private enum PrimarySection: Hashable {
        case mail, calendar
    }

    private var account: PersistedAccountConfig? { app.repo.loadActiveAccount() }

    var body: some View {
        Group {
            if let account {
                mainContent(account: account)
            } else {
                Text("No account. Please sign in again.")
            }
        }
        .sheet(isPresented: $showAddAccount) {
            LoginView(onFinished: { showAddAccount = false })
                .environmentObject(app)
        }
        .sheet(item: $selectedMessage) { sel in
            if let acc = app.repo.loadActiveAccount() {
                MessageDetailView(
                    config: acc,
                    folderFullName: sel.folder,
                    serverKey: sel.serverKey,
                    mail: mail,
                    onClose: { selectedMessage = nil },
                    draftsFolderFullName: FolderNameResolver.resolveTabToFolder(tab: .drafts, availableFolders: folders),
                    onDraftSaved: { refreshNonce += 1 },
                )
            }
        }
        .sheet(item: $composeIntent) { intent in
            if let acc = app.repo.loadActiveAccount() {
                ComposeEmailView(
                    intent: intent,
                    config: acc,
                    mail: mail,
                    draftsFolderFullName: FolderNameResolver.resolveTabToFolder(tab: .drafts, availableFolders: folders),
                    onDraftSaved: { refreshNonce += 1 },
                    onDismiss: { composeIntent = nil },
                    onSent: {
                        composeIntent = nil
                        refreshNonce += 1
                    },
                )
            }
        }
        .sheet(isPresented: $showRules) {
            if let acc = app.repo.loadActiveAccount() {
                RulesSheet(
                    account: acc,
                    mail: mail,
                    inboxFolder: FolderNameResolver.resolveTabToFolder(tab: .inbox, availableFolders: folders) ?? "INBOX",
                ) {
                    showRules = false
                    refreshNonce += 1
                }
            }
        }
        .sheet(isPresented: $showAutoReply) {
            if let acc = app.repo.loadActiveAccount() {
                AutoReplySheet(account: acc, mail: mail, inboxSummaries: messages) {
                    showAutoReply = false
                }
            }
        }
    }

    @ViewBuilder
    private func mainContent(account: PersistedAccountConfig) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $primary) {
                    Text("Mail").tag(PrimarySection.mail)
                    Text("Calendar").tag(PrimarySection.calendar)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                if primary == .calendar {
                    CalendarTabView(account: account)
                } else {
                    mailPanel(account: account)
                }
            }
            .navigationTitle(account.username)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(app.repo.listAccounts().sorted { $0.username.lowercased() < $1.username.lowercased() }) { acc in
                            Button {
                                _ = app.repo.setActiveAccountId(acc.id)
                                app.bump()
                            } label: {
                                HStack {
                                    Text(acc.username)
                                    if acc.id == account.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                        Divider()
                        Button("Add another account") { showAddAccount = true }
                        Button("Move rules…") { showRules = true }
                        Button("Automatic reply…") { showAutoReply = true }
                        Divider()
                        Button("Log out this account", role: .destructive) {
                            try? app.repo.removeActiveAccount()
                            app.bump()
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshNonce += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task(id: "\(account.id)-\(refreshNonce)") {
            await loadFolders(account: account)
        }
        .task(id: "\(account.id)-\(selectedTab)-\(customFolder ?? "")-\(refreshNonce)-\(folders.joined())") {
            await loadMessages(account: account)
        }
    }

    private func mailPanel(account: PersistedAccountConfig) -> some View {
        VStack(spacing: 0) {
            TextField("Search subject or sender", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.top, 8)
            tabBar
            if selectedTab == .folders {
                folderPicker(account: account)
            }
            if loadingMessages { ProgressView().padding() }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            List(filtered(messages)) { m in
                Button {
                    selectedMessage = SelectedMessage(folder: m.folderFullName, serverKey: m.serverKey)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.subject).font(.headline)
                        Text(m.from).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                composeIntent = .new
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .padding(16)
                    .background(Circle().fill(MTDETheme.gold))
                    .foregroundStyle(.white)
            }
            .padding()
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([MailFolderTab.inbox, .sent, .drafts, .trash, .folders], id: \.self) { tab in
                    Button(tab.label) {
                        selectedTab = tab
                        if tab != .folders { customFolder = nil }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(selectedTab == tab ? MTDETheme.gold.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func folderPicker(account: PersistedAccountConfig) -> some View {
        if account.incomingProtocol == .POP3 {
            Text("POP3 only supports Inbox. Use IMAP for other folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        } else {
            Picker("Folder", selection: Binding(
                get: { customFolder ?? "" },
                set: { customFolder = $0.isEmpty ? nil : $0 },
            )) {
                Text("Choose…").tag("")
                ForEach(folders, id: \.self) { f in
                    Text(f).tag(f)
                }
            }
            .padding(.horizontal)
        }
    }

    private func filtered(_ list: [MailMessageSummary]) -> [MailMessageSummary] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.subject.lowercased().contains(q) || $0.from.lowercased().contains(q) }
    }

    private func activeFolder(account: PersistedAccountConfig) -> String? {
        if account.incomingProtocol == .POP3 {
            return selectedTab == .inbox ? "INBOX" : nil
        }
        if selectedTab == .folders { return customFolder }
        return FolderNameResolver.resolveTabToFolder(tab: selectedTab, availableFolders: folders)
    }

    private func loadFolders(account: PersistedAccountConfig) async {
        do {
            let f = try await mail.listFolders(config: account)
            await MainActor.run { folders = f }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }

    private func loadMessages(account: PersistedAccountConfig) async {
        guard primary == .mail else { return }
        let folder = activeFolder(account: account)
        guard let folder else {
            await MainActor.run { messages = []; error = nil }
            return
        }
        await MainActor.run { loadingMessages = true; error = nil }
        let res = await mail.fetchMessageSummaries(config: account, folderFullName: folder)
        var list: [MailMessageSummary] = []
        switch res {
        case .success(let m): list = m
        case .failure(let e):
            await MainActor.run {
                loadingMessages = false
                error = e.localizedDescription
                messages = []
            }
            return
        }
        if account.incomingProtocol == .IMAP, selectedTab == .inbox {
            let rules = MailRulesStore(accountId: account.id)
            if rules.autoApplyAfterInboxLoad {
                _ = await mail.applySenderMoveRules(config: account, inboxFolderName: folder, rules: rules.loadRules())
                if case .success(let again) = await mail.fetchMessageSummaries(config: account, folderFullName: folder) {
                    list = again
                }
            }
            let ar = AutoReplyStore(accountId: account.id)
            if ar.sendVacationOnInboxRefresh, ar.isEnabled {
                _ = await mail.sendAutoRepliesForUnread(
                    config: account,
                    summaries: list,
                    replySubject: ar.subject,
                    replyBody: ar.body,
                    store: ar,
                )
            }
        }
        await MainActor.run {
            loadingMessages = false
            messages = list
        }
    }
}

private extension MailFolderTab {
    var label: String {
        switch self {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .trash: return "Trash"
        case .folders: return "Folders"
        }
    }
}

struct SelectedMessage: Identifiable, Hashable {
    let folder: String
    let serverKey: UInt32
    var id: String { "\(folder)|\(serverKey)" }
}

struct RulesSheet: View {
    let account: PersistedAccountConfig
    let mail: MailEngine
    let inboxFolder: String
    var onClose: () -> Void

    @State private var rules: [SenderMoveRule] = []
    @State private var pattern = ""
    @State private var target = ""
    @State private var autoApply = false
    @State private var status: String?

    private let store: MailRulesStore

    init(account: PersistedAccountConfig, mail: MailEngine, inboxFolder: String, onClose: @escaping () -> Void) {
        self.account = account
        self.mail = mail
        self.inboxFolder = inboxFolder
        self.onClose = onClose
        store = MailRulesStore(accountId: account.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rules") {
                    ForEach(rules) { r in
                        VStack(alignment: .leading) {
                            Text(r.senderPattern).font(.caption)
                            Text("→ \(r.targetFolder)").font(.caption2)
                        }
                    }
                    .onDelete { rules.remove(atOffsets: $0) }
                    TextField("Pattern", text: $pattern)
                    TextField("Target folder", text: $target)
                    Button("Add") {
                        let r = SenderMoveRule(senderPattern: pattern, targetFolder: target, matchKind: .addressEquals)
                        if !r.senderPattern.isEmpty, !r.targetFolder.isEmpty {
                            rules.append(r)
                            pattern = ""
                            target = ""
                        }
                    }
                    Toggle("Auto-apply after Inbox refresh", isOn: $autoApply)
                }
                if let status { Section { Text(status) } }
                Section {
                    Button("Apply rules now") {
                        Task {
                            let n = await mail.applySenderMoveRules(config: account, inboxFolderName: inboxFolder, rules: rules)
                            switch n {
                            case .success(let c): status = "Moved \(c) message(s)"
                            case .failure(let e): status = e.localizedDescription
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move rules")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { save(); onClose() } }
            }
            .onAppear {
                rules = store.loadRules()
                autoApply = store.autoApplyAfterInboxLoad
            }
        }
    }

    private func save() {
        store.saveRules(rules)
        store.autoApplyAfterInboxLoad = autoApply
    }
}

struct AutoReplySheet: View {
    let account: PersistedAccountConfig
    let mail: MailEngine
    let inboxSummaries: [MailMessageSummary]
    var onClose: () -> Void

    @State private var enabled = false
    @State private var subject = ""
    @State private var replyBodyText = ""
    @State private var onRefresh = false
    @State private var status: String?

    private let store: AutoReplyStore

    init(account: PersistedAccountConfig, mail: MailEngine, inboxSummaries: [MailMessageSummary], onClose: @escaping () -> Void) {
        self.account = account
        self.mail = mail
        self.inboxSummaries = inboxSummaries
        self.onClose = onClose
        store = AutoReplyStore(accountId: account.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Send automatic replies", isOn: $enabled)
                TextField("Subject", text: $subject)
                TextField("Body", text: $replyBodyText, axis: .vertical)
                    .lineLimit(4...10)
                Toggle("Offer replies on Inbox refresh", isOn: $onRefresh)
                if let status { Text(status) }
                Button("Send auto-replies now") {
                    Task {
                        let r = await mail.sendAutoRepliesForUnread(
                            config: account,
                            summaries: inboxSummaries,
                            replySubject: subject,
                            replyBody: replyBodyText,
                            store: store,
                        )
                        switch r {
                        case .success(let n): status = "Sent \(n)"
                        case .failure(let e): status = e.localizedDescription
                        }
                    }
                }
            }
            .navigationTitle("Automatic reply")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        store.isEnabled = enabled
                        store.subject = subject
                        store.body = replyBodyText
                        store.sendVacationOnInboxRefresh = onRefresh
                        onClose()
                    }
                }
            }
            .onAppear {
                enabled = store.isEnabled
                subject = store.subject
                replyBodyText = store.body
                onRefresh = store.sendVacationOnInboxRefresh
            }
        }
    }
}
