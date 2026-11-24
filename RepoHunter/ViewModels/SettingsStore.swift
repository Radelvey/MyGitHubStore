import Foundation
import SwiftUI

/// User settings. The GitHub token lives in the Keychain, everything else in UserDefaults (@AppStorage in views).
@MainActor
final class SettingsStore: ObservableObject {
    private static let tokenAccount = "github-token"

    @Published private(set) var hasToken: Bool = false
    @Published var tokenStatus: String?
    @Published var isVerifying = false

    init() {
        let t = KeychainStore.read(account: Self.tokenAccount)
        TokenBox.shared.value = t
        hasToken = !(t ?? "").isEmpty
    }

    var maskedToken: String {
        guard let t = KeychainStore.read(account: Self.tokenAccount), t.count > 8 else { return "" }
        return String(t.prefix(4)) + String(repeating: "•", count: 12) + String(t.suffix(4))
    }

    func saveToken(_ raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isVerifying = true
        tokenStatus = nil
        let previous = TokenBox.shared.value
        TokenBox.shared.value = token
        do {
            let login = try await GitHubAPI.shared.verifyToken()
            KeychainStore.save(token, account: Self.tokenAccount)
            hasToken = true
            tokenStatus = "✓ 已验证，当前用户：\(login)"
        } catch {
            TokenBox.shared.value = previous
            tokenStatus = "✗ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        isVerifying = false
    }

    func removeToken() {
        KeychainStore.delete(account: Self.tokenAccount)
        TokenBox.shared.value = nil
        hasToken = false
        tokenStatus = "已移除 Token"
    }
}
