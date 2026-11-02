//
//  OpenCodexService.swift
//  leanring-buddy
//

import Foundation
import Combine

public struct OpenCodexModel: Identifiable, Codable, Hashable {
    public let id: String
    public let object: String?
    public let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case ownedBy = "owned_by"
    }

    public var displayName: String {
        if id.contains("/") {
            let parts = id.split(separator: "/")
            return "\(parts[1]) (\(parts[0]))"
        }
        return id
    }
}

private struct OpenCodexModelsResponse: Codable {
    let data: [OpenCodexModel]
}

public final class OpenCodexService: ObservableObject {
    public static let shared = OpenCodexService()

    @Published public var isHealthy: Bool = false
    @Published public var availableModels: [OpenCodexModel] = []
    @Published public var lastCheckTime: Date?
    @Published public var latencyMs: Int = 0

    private var cancellables = Set<AnyCancellable>()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 5.0
        self.session = URLSession(configuration: config)

        // Initial probe & periodic polling
        Task { [weak self] in
            await self?.refresh()
        }

        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    public func refresh() async {
        let config = ClickyConfiguration.shared
        guard config.mode == .openCodex else { return }

        // 1. Health probe
        let start = CFAbsoluteTimeGetCurrent()
        let healthURLString = config.openCodexBaseURL.replacingOccurrences(of: "/v1", with: "") + "/healthz"
        if let healthURL = URL(string: healthURLString) {
            do {
                var request = URLRequest(url: healthURL)
                request.httpMethod = "GET"
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    self.isHealthy = true
                    self.latencyMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                } else {
                    self.isHealthy = false
                }
            } catch {
                self.isHealthy = false
            }
        }

        // 2. Models fetch
        if let modelsURL = URL(string: "\(config.openCodexBaseURL)/models") {
            do {
                var request = URLRequest(url: modelsURL)
                request.httpMethod = "GET"
                if !config.openCodexAPIKey.isEmpty {
                    request.setValue("Bearer \(config.openCodexAPIKey)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return
                }

                let decoded = try JSONDecoder().decode(OpenCodexModelsResponse.self, from: data)
                self.availableModels = decoded.data.sorted(by: { $0.id < $1.id })
                self.lastCheckTime = Date()

                // If selected model isn't in available models, pick a sensible default
                if !self.availableModels.contains(where: { $0.id == config.selectedModel }) {
                    if let firstAntigravity = self.availableModels.first(where: { $0.id.contains("antigravity") || $0.id.contains("gemini") }) {
                        config.selectedModel = firstAntigravity.id
                    } else if let first = self.availableModels.first {
                        config.selectedModel = first.id
                    }
                }
            } catch {
                // Keep existing model list on transient network error
            }
        }
    }
}
