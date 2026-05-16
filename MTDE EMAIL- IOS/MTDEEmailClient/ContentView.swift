import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if app.repo.listAccounts().isEmpty {
                LoginView()
            } else {
                MailHomeView()
            }
        }
        .id(app.reloadKey)
    }
}
