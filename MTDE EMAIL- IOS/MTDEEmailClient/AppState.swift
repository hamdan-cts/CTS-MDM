import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    let repo = AccountRepository()
    @Published var reloadKey = 0

    func bump() {
        reloadKey += 1
    }
}
