import SwiftUI

struct CalendarTabView: View {
    let account: PersistedAccountConfig
    private let cal = RemoteCalendarSync()

    @State private var busy = false
    @State private var syncStatus: String?
    @State private var events: [RemoteCalendarSync.IcalEventPreview] = []
    @State private var err: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sync to load events. Add a CalDAV URL under Account & server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Sync") {
                    Task { await sync() }
                }
                .buttonStyle(.borderedProminent)
                .tint(MTDETheme.gold)
                .disabled(busy || account.caldavUrl == nil)
                if busy { ProgressView() }
                if let syncStatus { Text(syncStatus).font(.caption) }
                if let err { Text(err).font(.caption).foregroundStyle(.red) }
                Text("Events (\(events.count))").font(.headline)
                ForEach(events) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.title).font(.subheadline.weight(.semibold))
                        Text(e.startInfo).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
    }

    private func sync() async {
        busy = true
        err = nil
        let probe = await cal.probeCalDavCollection(config: account)
        let emb = await cal.fetchCalDavEmbeddedEvents(config: account)
        await MainActor.run {
            busy = false
            switch probe {
            case .success(let p):
                syncStatus = "CalDAV HTTP \(p.statusCode)"
            case .failure(let e):
                syncStatus = "CalDAV: \(e.localizedDescription)"
            }
            switch emb {
            case .success(let list):
                events = list
            case .failure(let e):
                err = e.localizedDescription
            }
        }
    }
}
