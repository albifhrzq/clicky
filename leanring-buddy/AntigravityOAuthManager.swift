//
//  AntigravityOAuthManager.swift
//  leanring-buddy
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

nonisolated public enum AntigravityOAuthError: LocalizedError, Sendable {
    case missingClientCredentials
    case listenerFailed(String)
    case timedOut
    case stateMismatch
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case missingRefreshToken
    case tokenRefreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientCredentials:
            return "Google Antigravity OAuth Client ID is missing. Add your Desktop OAuth Client ID and Secret in Settings."
        case .listenerFailed(let reason):
            return "Failed to start local OAuth callback listener on 127.0.0.1:51121: \(reason)"
        case .timedOut:
            return "Google Antigravity sign-in timed out before the browser callback completed."
        case .stateMismatch:
            return "OAuth state verification failed. Please try signing in again."
        case .authorizationDenied(let message):
            return "Google sign-in was denied or cancelled: \(message)"
        case .tokenExchangeFailed(let message):
            return "Failed to exchange authorization code for tokens: \(message)"
        case .missingRefreshToken:
            return "No Antigravity refresh token found. Please sign in again in Settings."
        case .tokenRefreshFailed(let message):
            return "Failed to refresh Antigravity access token: \(message)"
        }
    }
}

nonisolated private struct OAuthCallbackResult: Sendable {
    let authorizationCode: String
}

/// Ephemeral loopback HTTP server listening on `127.0.0.1:51121` for `/callback`.
nonisolated private final class OAuthLoopbackCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.clicky.antigravity.oauth.listener")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private var hasCompleted = false
    private var timeoutWorkItem: DispatchWorkItem?

    func startAndWaitForCallback(
        expectedState: String,
        timeoutSeconds: TimeInterval = 180,
        onListeningReady: @escaping @Sendable () -> Void
    ) async throws -> OAuthCallbackResult {
        try await withCheckedThrowingContinuation { continuation in
            self.stateLock.lock()
            self.continuation = continuation
            self.hasCompleted = false
            self.stateLock.unlock()

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                guard let loopbackAddress = IPv4Address("127.0.0.1"),
                      let callbackPort = NWEndpoint.Port(rawValue: 51121) else {
                    self.complete(with: .failure(AntigravityOAuthError.listenerFailed("Invalid loopback address or port")))
                    return
                }
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(loopbackAddress), port: callbackPort)

                let newListener = try NWListener(using: parameters)
                self.listener = newListener

                newListener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        onListeningReady()
                    case .failed(let error):
                        self.complete(with: .failure(AntigravityOAuthError.listenerFailed(error.localizedDescription)))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                newListener.newConnectionHandler = { [weak self] connection in
                    self?.handleIncomingConnection(connection, expectedState: expectedState)
                }

                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.complete(with: .failure(AntigravityOAuthError.timedOut))
                }
                self.timeoutWorkItem = timeoutItem
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

                newListener.start(queue: self.queue)
            } catch {
                self.complete(with: .failure(AntigravityOAuthError.listenerFailed(error.localizedDescription)))
            }
        }
    }

    func cancel() {
        complete(with: .failure(CancellationError()))
    }

    private func handleIncomingConnection(_ connection: NWConnection, expectedState: String) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.sendHTMLResponse(
                    on: connection,
                    statusCode: 500,
                    title: "Sign-In Error",
                    message: "Failed to read callback request: \(error.localizedDescription)"
                )
                return
            }

            guard let data,
                  let requestText = String(data: data, encoding: .utf8),
                  let requestLine = requestText.components(separatedBy: "\r\n").first else {
                self.sendHTMLResponse(
                    on: connection,
                    statusCode: 400,
                    title: "Invalid Request",
                    message: "Unable to parse OAuth callback."
                )
                return
            }

            let lineParts = requestLine.split(separator: " ")
            guard lineParts.count >= 2 else {
                self.sendHTMLResponse(
                    on: connection,
                    statusCode: 400,
                    title: "Invalid Request",
                    message: "Malformed HTTP request line."
                )
                return
            }

            let target = String(lineParts[1])
            guard let components = URLComponents(string: "http://127.0.0.1:51121" + target),
                  components.path == "/callback" else {
                self.sendHTMLResponse(
                    on: connection,
                    statusCode: 404,
                    title: "Not Found",
                    message: "Waiting for OAuth callback."
                )
                return
            }

            let queryItems = components.queryItems ?? []
            let queryDictionary = Dictionary(
                queryItems.compactMap { item -> (String, String)? in
                    guard let value = item.value else { return nil }
                    return (item.name, value)
                },
                uniquingKeysWith: { first, _ in first }
            )

            if let oauthError = queryDictionary["error"] {
                let errorDescription = queryDictionary["error_description"] ?? oauthError
                self.sendHTMLResponse(
                    on: connection,
                    statusCode: 400,
                    title: "Sign-In Cancelled",
                    message: "Google sign-in did not complete (\(errorDescription)). You may close this tab."
                )
                self.complete(with: .failure(AntigravityOAuthError.authorizationDenied(errorDescription)))
                return
            }

            guard queryDictionary["state"] == expectedState else {
                self.sendHTMLResponse(
                    on: connection,
                    statusCode: 400,
                    title: "State Mismatch",
                    message: "OAuth state mismatch. Please return to HeyClicky and try again."
                )
                self.complete(with: .failure(AntigravityOAuthError.stateMismatch))
                return
            }

            guard let authorizationCode = queryDictionary["code"], !authorizationCode.isEmpty else {
                self.sendHTMLResponse(
                    on: connection,
                    statusCode: 400,
                    title: "Missing Code",
                    message: "No authorization code was returned by Google."
                )
                self.complete(with: .failure(AntigravityOAuthError.authorizationDenied("Missing authorization code")))
                return
            }

            self.sendHTMLResponse(
                on: connection,
                statusCode: 200,
                title: "HeyClicky Connected",
                message: "Google Antigravity sign-in succeeded. You can close this tab and return to HeyClicky."
            )
            self.complete(with: .success(OAuthCallbackResult(authorizationCode: authorizationCode)))
        }
    }

    private func sendHTMLResponse(
        on connection: NWConnection,
        statusCode: Int,
        title: String,
        message: String
    ) {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let escapedMessage = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>\(escapedTitle)</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#111318;color:#f3f4f6;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;">
          <div style="max-width:440px;padding:28px;border-radius:14px;background:#1b1f28;border:1px solid #2d3444;text-align:center;">
            <h2 style="margin:0 0 10px 0;">\(escapedTitle)</h2>
            <p style="margin:0;color:#cbd5e1;line-height:1.5;">\(escapedMessage)</p>
          </div>
        </body>
        </html>
        """

        let bodyData = Data(html.utf8)
        let statusPhrase = statusCode == 200 ? "OK" : (statusCode == 404 ? "Not Found" : "Bad Request")
        let header = "HTTP/1.1 \(statusCode) \(statusPhrase)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func complete(with result: Result<OAuthCallbackResult, Error>) {
        stateLock.lock()
        guard !hasCompleted else {
            stateLock.unlock()
            return
        }
        hasCompleted = true
        let activeContinuation = continuation
        continuation = nil
        let activeListener = listener
        listener = nil
        let activeTimeout = timeoutWorkItem
        timeoutWorkItem = nil
        stateLock.unlock()

        activeTimeout?.cancel()
        activeListener?.cancel()
        activeContinuation?.resume(with: result)
    }
}

@MainActor
public final class AntigravityOAuthManager: ObservableObject {
    public static let shared = AntigravityOAuthManager()

    private let defaults = UserDefaults.standard
    private let accessTokenKeychainKey = "antigravity_access_token"
    private let refreshTokenKeychainKey = "antigravity_refresh_token"
    private let tokenExpiresAtDefaultsKey = "antigravity_token_expires_at"
    private let userEmailDefaultsKey = "antigravity_user_email"
    private let projectNumberDefaultsKey = "antigravity_project_number"

    private let redirectURI = "http://127.0.0.1:51121/callback"
    private let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private let userInfoEndpoint = "https://www.googleapis.com/oauth2/v2/userinfo"
    private let codeAssistHosts = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]

    private let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs"
    ]

    @Published public var isAuthenticated: Bool = false
    @Published public var isAuthenticating: Bool = false
    @Published public var authError: String?
    @Published public var userEmail: String?
    @Published public var currentProjectNumber: String?

    private var activeCallbackServer: OAuthLoopbackCallbackServer?
    private var activeRefreshTask: Task<String, Error>?

    private var resolvedClientID: String {
        let configured = ClickyConfiguration.shared.antigravityClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        if let keychainValue = ClickyKeychainStore.read(key: "antigravity_client_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainValue.isEmpty {
            return keychainValue
        }
        return AppBundleConfiguration.stringValue(forKey: "AntigravityClientID") ?? ""
    }

    private var resolvedClientSecret: String {
        let configured = ClickyConfiguration.shared.antigravityClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        if let keychainValue = ClickyKeychainStore.read(key: "antigravity_client_secret")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainValue.isEmpty {
            return keychainValue
        }
        return AppBundleConfiguration.stringValue(forKey: "AntigravityClientSecret") ?? ""
    }

    public var currentAccessToken: String? {
        ClickyKeychainStore.read(key: accessTokenKeychainKey)
    }

    private var currentRefreshToken: String? {
        ClickyKeychainStore.read(key: refreshTokenKeychainKey)
    }

    private var tokenExpiresAt: TimeInterval {
        get { defaults.double(forKey: tokenExpiresAtDefaultsKey) }
        set { defaults.set(newValue, forKey: tokenExpiresAtDefaultsKey) }
    }

    private init() {
        let hasAccessToken = !(currentAccessToken ?? "").isEmpty
        let hasRefreshToken = !(currentRefreshToken ?? "").isEmpty
        if hasAccessToken || hasRefreshToken {
            self.isAuthenticated = true
            self.userEmail = defaults.string(forKey: userEmailDefaultsKey)
            self.currentProjectNumber = defaults.string(forKey: projectNumberDefaultsKey)
        }
    }

    // MARK: - PKCE OAuth Sign-In

    public func signIn() async throws {
        let clientID = resolvedClientID
        let clientSecret = resolvedClientSecret

        guard !clientID.isEmpty else {
            let error = AntigravityOAuthError.missingClientCredentials
            self.authError = error.localizedDescription
            throw error
        }

        activeCallbackServer?.cancel()
        activeCallbackServer = nil

        isAuthenticating = true
        authError = nil
        defer {
            isAuthenticating = false
            activeCallbackServer = nil
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(for: codeVerifier)
        let state = generateCodeVerifier()

        guard var authComponents = URLComponents(string: authorizationEndpoint) else {
            throw URLError(.badURL)
        }
        authComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let authURL = authComponents.url else {
            throw URLError(.badURL)
        }

        do {
            let callbackServer = OAuthLoopbackCallbackServer()
            self.activeCallbackServer = callbackServer

            let callbackResult = try await callbackServer.startAndWaitForCallback(expectedState: state) {
                Task { @MainActor in
                    NSWorkspace.shared.open(authURL)
                }
            }

            let tokens = try await exchangeAuthorizationCode(
                code: callbackResult.authorizationCode,
                codeVerifier: codeVerifier,
                clientID: clientID,
                clientSecret: clientSecret
            )

            ClickyKeychainStore.save(key: accessTokenKeychainKey, value: tokens.accessToken)
            if let refreshToken = tokens.refreshToken, !refreshToken.isEmpty {
                ClickyKeychainStore.save(key: refreshTokenKeychainKey, value: refreshToken)
            }
            tokenExpiresAt = Date().timeIntervalSince1970 + TimeInterval(tokens.expiresIn)
            isAuthenticated = true

            if let email = await fetchUserEmail(accessToken: tokens.accessToken) {
                self.userEmail = email
                defaults.set(email, forKey: userEmailDefaultsKey)
            }

            if let projectNumber = await discoverOrOnboardProject(accessToken: tokens.accessToken) {
                self.currentProjectNumber = projectNumber
                defaults.set(projectNumber, forKey: projectNumberDefaultsKey)
            }
        } catch {
            self.authError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Token Refresh

    public func refreshAccessTokenIfNeeded() async throws -> String {
        if let existingTask = activeRefreshTask {
            return try await existingTask.value
        }

        // Return cached access token if it still has at least 60 seconds of validity.
        if let token = currentAccessToken,
           !token.isEmpty,
           tokenExpiresAt > Date().timeIntervalSince1970 + 60 {
            return token
        }

        guard let refreshToken = currentRefreshToken, !refreshToken.isEmpty else {
            if let token = currentAccessToken, !token.isEmpty, tokenExpiresAt == 0 {
                return token
            }
            let error = AntigravityOAuthError.missingRefreshToken
            self.isAuthenticated = false
            self.authError = error.localizedDescription
            throw error
        }

        let clientID = resolvedClientID
        let clientSecret = resolvedClientSecret
        guard !clientID.isEmpty else {
            let error = AntigravityOAuthError.missingClientCredentials
            self.authError = error.localizedDescription
            throw error
        }

        let refreshTask = Task<String, Error> {
            var parameters: [String: String] = [
                "client_id": clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ]
            if !clientSecret.isEmpty {
                parameters["client_secret"] = clientSecret
            }

            guard let url = URL(string: tokenEndpoint) else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formEncodedBody(parameters)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AntigravityOAuthError.tokenRefreshFailed("Invalid HTTP response")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                    ClickyKeychainStore.delete(key: accessTokenKeychainKey)
                    defaults.removeObject(forKey: tokenExpiresAtDefaultsKey)
                    self.isAuthenticated = false
                }
                let error = AntigravityOAuthError.tokenRefreshFailed(errorBody)
                self.authError = error.localizedDescription
                throw error
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String,
                  !newAccessToken.isEmpty else {
                throw AntigravityOAuthError.tokenRefreshFailed("Invalid token response format")
            }

            let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            ClickyKeychainStore.save(key: accessTokenKeychainKey, value: newAccessToken)
            if let rotatedRefreshToken = json["refresh_token"] as? String, !rotatedRefreshToken.isEmpty {
                ClickyKeychainStore.save(key: refreshTokenKeychainKey, value: rotatedRefreshToken)
            }
            tokenExpiresAt = Date().timeIntervalSince1970 + expiresIn
            self.isAuthenticated = true
            self.authError = nil

            if (self.currentProjectNumber ?? "").isEmpty,
               let discoveredProject = await discoverOrOnboardProject(accessToken: newAccessToken) {
                self.currentProjectNumber = discoveredProject
                defaults.set(discoveredProject, forKey: projectNumberDefaultsKey)
            }

            return newAccessToken
        }

        activeRefreshTask = refreshTask
        defer { activeRefreshTask = nil }
        return try await refreshTask.value
    }

    // MARK: - Sign Out

    public func signOut() {
        activeCallbackServer?.cancel()
        activeCallbackServer = nil
        activeRefreshTask?.cancel()
        activeRefreshTask = nil

        ClickyKeychainStore.delete(key: accessTokenKeychainKey)
        ClickyKeychainStore.delete(key: refreshTokenKeychainKey)
        defaults.removeObject(forKey: tokenExpiresAtDefaultsKey)
        defaults.removeObject(forKey: userEmailDefaultsKey)
        defaults.removeObject(forKey: projectNumberDefaultsKey)

        self.isAuthenticated = false
        self.isAuthenticating = false
        self.authError = nil
        self.userEmail = nil
        self.currentProjectNumber = nil
    }

    // MARK: - OAuth Token Exchange, UserInfo & Cloud Code Assist Onboarding

    private func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        clientID: String,
        clientSecret: String
    ) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        guard let url = URL(string: tokenEndpoint) else {
            throw URLError(.badURL)
        }

        var parameters: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        if !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody(parameters)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown token exchange error"
            throw AntigravityOAuthError.tokenExchangeFailed(bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw AntigravityOAuthError.tokenExchangeFailed("Missing access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.intValue ?? 3600
        return (accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }

    private func fetchUserEmail(accessToken: String) async -> String? {
        guard let url = URL(string: userInfoEndpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = json["email"] as? String,
                  !email.isEmpty else {
                return nil
            }
            return email
        } catch {
            return nil
        }
    }

    private func discoverOrOnboardProject(accessToken: String) async -> String? {
        let metadata: [String: Any] = [
            "ideType": "IDE_UNSPECIFIED",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI"
        ]

        for host in codeAssistHosts {
            guard let loadURL = URL(string: "\(host)/v1internal:loadCodeAssist") else { continue }
            var loadRequest = URLRequest(url: loadURL)
            loadRequest.httpMethod = "POST"
            loadRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            loadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            loadRequest.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            loadRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": metadata])

            do {
                let (data, response) = try await URLSession.shared.data(for: loadRequest)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let existingProject = extractProjectID(from: json["cloudaicompanionProject"]) {
                    return existingProject
                }

                // Determine tier ID for onboarding if no project exists yet.
                let defaultTierID = selectDefaultTierID(from: json) ?? "free-tier"
                if let onboardedProject = await onboardUser(
                    host: host,
                    accessToken: accessToken,
                    tierID: defaultTierID,
                    metadata: metadata
                ) {
                    return onboardedProject
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func onboardUser(
        host: String,
        accessToken: String,
        tierID: String,
        metadata: [String: Any]
    ) async -> String? {
        guard let onboardURL = URL(string: "\(host)/v1internal:onboardUser") else { return nil }

        var onboardRequest = URLRequest(url: onboardURL)
        onboardRequest.httpMethod = "POST"
        onboardRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        onboardRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        onboardRequest.setValue("antigravity", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "tierId": tierID,
            "metadata": metadata
        ]
        onboardRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: onboardRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Poll operation if onboarding is asynchronous.
            if (json["done"] as? Bool) != true, let operationName = json["name"] as? String {
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let pollURL = URL(string: "\(host)/v1internal/\(operationName)") else { break }
                    var pollRequest = URLRequest(url: pollURL)
                    pollRequest.httpMethod = "GET"
                    pollRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    pollRequest.setValue("antigravity", forHTTPHeaderField: "User-Agent")

                    if let (pollData, pollResp) = try? await URLSession.shared.data(for: pollRequest),
                       let pollHTTP = pollResp as? HTTPURLResponse,
                       (200...299).contains(pollHTTP.statusCode),
                       let pollJSON = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any] {
                        json = pollJSON
                        if (json["done"] as? Bool) == true {
                            break
                        }
                    }
                }
            }

            if let responseDict = json["response"] as? [String: Any],
               let project = extractProjectID(from: responseDict["cloudaicompanionProject"]) {
                return project
            }
            return extractProjectID(from: json["cloudaicompanionProject"])
        } catch {
            return nil
        }
    }

    private func selectDefaultTierID(from loadCodeAssistJSON: [String: Any]) -> String? {
        if let currentTier = loadCodeAssistJSON["currentTier"] as? [String: Any],
           let id = currentTier["id"] as? String,
           !id.isEmpty {
            return id
        }
        if let allowedTiers = loadCodeAssistJSON["allowedTiers"] as? [[String: Any]] {
            if let defaultTier = allowedTiers.first(where: { ($0["isDefault"] as? Bool) == true }),
               let id = defaultTier["id"] as? String,
               !id.isEmpty {
                return id
            }
            if let firstTier = allowedTiers.first,
               let id = firstTier["id"] as? String,
               !id.isEmpty {
                return id
            }
        }
        return nil
    }

    private func extractProjectID(from rawValue: Any?) -> String? {
        if let projectString = rawValue as? String {
            let trimmed = projectString.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("projects/") {
                let stripped = String(trimmed.dropFirst("projects/".count))
                return stripped.isEmpty ? nil : stripped
            }
            return trimmed.isEmpty ? nil : trimmed
        }
        if let projectDict = rawValue as? [String: Any],
           let id = projectDict["id"] as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - PKCE & Encoding Helpers

    private func formEncodedBody(_ parameters: [String: String]) -> Data? {
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-._~")
        let encoded = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }

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
