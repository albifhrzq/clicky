//
//  AntigravityOAuthManager.swift
//  leanring-buddy
//

import Foundation
import AppKit
import CryptoKit

public final class AntigravityOAuthManager: ObservableObject {
    public static let shared = AntigravityOAuthManager()

    // Google Antigravity Client Credentials (configured via Settings or Keychain)
    private var clientID: String {
        ClickyKeychainStore.read(key: "antigravity_client_id") ??
        UserDefaults.standard.string(forKey: "antigravity_client_id") ?? ""
    }

    private var clientSecret: String {
        ClickyKeychainStore.read(key: "antigravity_client_secret") ??
        UserDefaults.standard.string(forKey: "antigravity_client_secret") ?? ""
    }
    private let redirectURI = "http://127.0.0.1:51121/callback"
    private let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs"
    ]

    private let tokenEndpoint = "https://oauth2.googleapis.com/token"

    @Published public var isAuthenticated: Bool = false
    @Published public var userEmail: String?
    @Published public var currentProjectNumber: String?

    public var currentAccessToken: String? {
        ClickyKeychainStore.read(key: "antigravity_access_token")
    }

    private var currentRefreshToken: String? {
        ClickyKeychainStore.read(key: "antigravity_refresh_token")
    }

    private init() {
        if let token = currentAccessToken, !token.isEmpty {
            self.isAuthenticated = true
            self.userEmail = UserDefaults.standard.string(forKey: "antigravity_user_email")
            self.currentProjectNumber = UserDefaults.standard.string(forKey: "antigravity_project_number")
        }
    }

    // MARK: - Token Refresh

    public func refreshAccessTokenIfNeeded() async throws -> String {
        guard let refreshToken = currentRefreshToken, !refreshToken.isEmpty else {
            throw NSError(domain: "AntigravityOAuth", code: 401, userInfo: [NSLocalizedDescriptionKey: "No refresh token found"])
        }

        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")

        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "AntigravityOAuth", code: 401, userInfo: [NSLocalizedDescriptionKey: "Failed to refresh Antigravity token"])
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let newAccessToken = json["access_token"] as? String {
            ClickyKeychainStore.save(key: "antigravity_access_token", value: newAccessToken)
            await MainActor.run {
                self.isAuthenticated = true
            }
            return newAccessToken
        }

        throw NSError(domain: "AntigravityOAuth", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid token response format"])
    }

    // MARK: - Sign Out

    public func signOut() {
        ClickyKeychainStore.delete(key: "antigravity_access_token")
        ClickyKeychainStore.delete(key: "antigravity_refresh_token")
        UserDefaults.standard.removeObject(forKey: "antigravity_user_email")
        UserDefaults.standard.removeObject(forKey: "antigravity_project_number")

        DispatchQueue.main.async {
            self.isAuthenticated = false
            self.userEmail = nil
            self.currentProjectNumber = nil
        }
    }

    // MARK: - PKCE Helper

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
