import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var app: AppState
    private let mail = MailEngine()
    var onFinished: (() -> Void)?

    @State private var username = DemoServerDefaults.username
    @State private var password = DemoServerDefaults.password
    @State private var showAdvanced = true
    @State private var incomingProtocol: IncomingProtocol = .IMAP
    @State private var incomingHost = DemoServerDefaults.mailHost
    @State private var incomingPort = DemoServerDefaults.incomingPortIMAP
    @State private var smtpHost = DemoServerDefaults.mailHost
    @State private var smtpPort = DemoServerDefaults.smtpPortSMTPS
    @State private var smtpSsl = true
    @State private var smtpStartTls = false
    @State private var trustPrivateCerts = true
    @State private var caldavUrl = DemoServerDefaults.defaultCalDavURL

    @State private var busy = false
    @State private var status: String?

    private var existingCount: Int { app.repo.listAccounts().count }

    var body: some View {
        ZStack {
            LinearGradient(colors: [MTDETheme.gold.opacity(0.35), MTDETheme.grayBackground], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    Text(existingCount > 0 ? "Add another account" : "Government Electronic Mail")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(MTDETheme.gold)
                        .multilineTextAlignment(.center)
                    Group {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                    }
                    protocolPicker
                    if showAdvanced {
                        advancedFields
                    }
                    Button(showAdvanced ? "Hide account & server" : "Account & server") {
                        showAdvanced.toggle()
                    }
                    .buttonStyle(.bordered)
                    if busy { ProgressView() }
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button(action: signIn) {
                        Text("LOGIN")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MTDETheme.gold)
                    .disabled(busy || username.isEmpty || password.isEmpty)
                    Text("Ministry of Telecom & IT © 2026 All rights reserved")
                        .font(.caption2)
                        .foregroundStyle(MTDETheme.gold)
                        .padding(.top, 8)
                }
                .padding(24)
            }
        }
    }

    private var protocolPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Receive mail").font(.subheadline.weight(.medium))
            HStack {
                chip("IMAP", selected: incomingProtocol == .IMAP) { incomingProtocol = .IMAP; syncPorts() }
                chip("POP3", selected: incomingProtocol == .POP3) { incomingProtocol = .POP3; syncPorts() }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? MTDETheme.gold : Color.white)
                .foregroundStyle(selected ? Color.white : .primary)
                .clipShape(Capsule())
        }
    }

    private var advancedFields: some View {
        VStack(spacing: 10) {
            field("Incoming host", text: $incomingHost)
            field("Incoming port", text: $incomingPort, keyboard: .numberPad)
            field("SMTP host", text: $smtpHost)
            field("SMTP port", text: $smtpPort, keyboard: .numberPad)
            Toggle("Use SMTPS (SSL)", isOn: $smtpSsl)
            Toggle("Use STARTTLS", isOn: $smtpStartTls)
            Toggle("Allow private / self-signed TLS (internal servers)", isOn: $trustPrivateCerts)
            Text("Calendar (CalDAV)").font(.subheadline.weight(.semibold))
            field("CalDAV URL", text: $caldavUrl)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.95)))
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)))
    }

    private func syncPorts() {
        switch incomingProtocol {
        case .IMAP: incomingPort = "993"
        case .POP3: incomingPort = "995"
        }
    }

    private func signIn() {
        status = nil
        busy = true
        let cfg = buildConfig()
        Task {
            let inOk = await mail.testIncoming(config: cfg)
            switch inOk {
            case .failure(let e):
                await MainActor.run {
                    busy = false
                    status = e.localizedDescription
                }
                return
            case .success:
                break
            }
            let smtpOk = await mail.testSmtp(config: cfg)
            await MainActor.run {
                busy = false
                switch smtpOk {
                case .failure(let e):
                    status = e.localizedDescription
                case .success:
                    do {
                        try app.repo.upsertAndSetActive(cfg)
                        app.bump()
                        onFinished?()
                    } catch {
                        status = error.localizedDescription
                    }
                }
            }
        }
    }

    private func buildConfig() -> PersistedAccountConfig {
        let inHost = incomingHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? guessIncomingHost(username, incomingProtocol) : incomingHost
        let smHost = smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? guessSmtpHost(username) : smtpHost
        let inPort = Int(incomingPort) ?? defaultIncomingPort(incomingProtocol)
        let outPort = Int(smtpPort) ?? defaultSmtpPort(smtpSsl)
        let cal = caldavUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return PersistedAccountConfig(
            id: "",
            username: username,
            password: password,
            incomingHost: inHost,
            incomingPort: inPort,
            incomingProtocol: incomingProtocol,
            smtpHost: smHost,
            smtpPort: outPort,
            smtpSsl: smtpSsl,
            smtpStartTls: smtpStartTls,
            trustPrivateCerts: trustPrivateCerts,
            caldavUrl: cal.isEmpty ? nil : cal,
        )
    }

    private func guessIncomingHost(_ address: String, _ proto: IncomingProtocol) -> String {
        let domain = address.split(separator: "@").dropFirst().first.map(String.init) ?? ""
        guard !domain.isEmpty else { return "" }
        switch proto {
        case .IMAP: return "imap.\(domain)"
        case .POP3: return "pop.\(domain)"
        }
    }

    private func guessSmtpHost(_ address: String) -> String {
        let domain = address.split(separator: "@").dropFirst().first.map(String.init) ?? ""
        return domain.isEmpty ? "" : "smtp.\(domain)"
    }

    private func defaultIncomingPort(_ proto: IncomingProtocol) -> Int {
        proto == .IMAP ? 993 : 995
    }

    private func defaultSmtpPort(_ ssl: Bool) -> Int { ssl ? 465 : 587 }
}
