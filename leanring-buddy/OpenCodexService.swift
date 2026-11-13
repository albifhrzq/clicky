//
//  OpenCodexService.swift
//  leanring-buddy
//

import Combine
import Foundation

nonisolated private struct OpenCodexReasoningEffortEntry: Codable, Hashable, Sendable {
    let value: String
    let label: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case value
        case label
        case isDefault = "default"
    }
}

nonisolated public struct OpenCodexModelCapabilities: Codable, Hashable, Sendable {
    public let contextLength: Int?
    public let maxOutputTokens: Int?
    public let outputModalities: [String]?
    public let inputModalities: [String]?
    public let supportsToolUse: Bool?
    public let supportsStreaming: Bool?
    public let supportsReasoning: Bool?
    public let supportsReasoningEffort: Bool?
    public let supportsVision: Bool?
    public let reasoningEffort: [String]?

    enum CodingKeys: String, CodingKey {
        case contextLength = "context_length"
        case maxOutputTokens = "max_output_tokens"
        case outputModalities = "output_modalities"
        case inputModalities = "input_modalities"
        case supportsToolUse = "supports_tool_use"
        case supportsStreaming = "supports_streaming"
        case supportsReasoning = "supports_reasoning"
        case supportsReasoningEffort = "supports_reasoning_effort"
        case supportsVision = "supports_vision"
        case reasoningEffort = "reasoning_effort"
    }
}

nonisolated public struct OpenCodexModel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let object: String?
    public let ownedBy: String?
    public let supportsVision: Bool
    public let inputModalities: [String]
    public let apiTypes: [String]
    public let reasoningEfforts: [String]
    public let maxOutputTokens: Int?
    public let contextLength: Int?
    public let supportsToolUse: Bool
    public let capabilities: OpenCodexModelCapabilities?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case ownedBy = "owned_by"
        case apiTypes = "api_types"
        case reasoningEfforts = "reasoning_efforts"
        case capabilities
        case maxOutputTokens = "max_output_tokens"
        case contextLength = "context_length"
        case contextWindow = "context_window"
    }

    public init(
        id: String,
        object: String? = nil,
        ownedBy: String? = nil,
        supportsVision: Bool = false,
        inputModalities: [String] = ["text"],
        apiTypes: [String] = [],
        reasoningEfforts: [String] = [],
        maxOutputTokens: Int? = nil,
        contextLength: Int? = nil,
        supportsToolUse: Bool = true,
        capabilities: OpenCodexModelCapabilities? = nil
    ) {
        self.id = id
        self.object = object
        self.ownedBy = ownedBy
        self.supportsVision = supportsVision
        self.inputModalities = inputModalities
        self.apiTypes = apiTypes
        self.reasoningEfforts = reasoningEfforts
        self.maxOutputTokens = maxOutputTokens
        self.contextLength = contextLength
        self.supportsToolUse = supportsToolUse
        self.capabilities = capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        let decodedObject = try container.decodeIfPresent(String.self, forKey: .object)
        let decodedOwnedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
        let decodedAPITypes = try container.decodeIfPresent([String].self, forKey: .apiTypes) ?? []
        let decodedCapabilities = try container.decodeIfPresent(OpenCodexModelCapabilities.self, forKey: .capabilities)

        var decodedEfforts: [String] = []
        if let effortStrings = try? container.decodeIfPresent([String].self, forKey: .reasoningEfforts) {
            decodedEfforts = effortStrings
        } else if let effortEntries = try? container.decodeIfPresent([OpenCodexReasoningEffortEntry].self, forKey: .reasoningEfforts) {
            decodedEfforts = effortEntries.map(\.value)
        } else if let capabilityEfforts = decodedCapabilities?.reasoningEffort {
            decodedEfforts = capabilityEfforts
        }

        let decodedInputModalities = decodedCapabilities?.inputModalities ?? ["text"]
        let hasImageModality = decodedInputModalities.contains {
            $0.caseInsensitiveCompare("image") == .orderedSame
        }
        let decodedSupportsVision = (decodedCapabilities?.supportsVision == true) || hasImageModality

        let topLevelMaxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        let topLevelContextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
            ?? container.decodeIfPresent(Int.self, forKey: .contextWindow)

        self.id = decodedID
        self.object = decodedObject
        self.ownedBy = decodedOwnedBy
        self.supportsVision = decodedSupportsVision
        self.inputModalities = decodedInputModalities
        self.apiTypes = decodedAPITypes
        self.reasoningEfforts = decodedEfforts
        self.maxOutputTokens = decodedCapabilities?.maxOutputTokens ?? topLevelMaxOutputTokens
        self.contextLength = decodedCapabilities?.contextLength ?? topLevelContextLength
        self.supportsToolUse = decodedCapabilities?.supportsToolUse ?? true
        self.capabilities = decodedCapabilities
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(object, forKey: .object)
        try container.encodeIfPresent(ownedBy, forKey: .ownedBy)
        try container.encode(apiTypes, forKey: .apiTypes)
        try container.encode(reasoningEfforts, forKey: .reasoningEfforts)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
    }

    public var displayName: String {
        if id.contains("/") {
            let parts = id.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                return "\(parts[1]) (\(parts[0]))"
            }
        }
        return id
    }
}

nonisolated private struct OpenCodexModelsResponse: Codable, Sendable {
    let data: [OpenCodexModel]
}

@MainActor
public final class OpenCodexService: ObservableObject {
    public static let shared = OpenCodexService()

    @Published public var isHealthy: Bool = false
    @Published public var availableModels: [OpenCodexModel] = []
    @Published public var visionModels: [OpenCodexModel] = []
    @Published public var agentModels: [OpenCodexModel] = []
    @Published public var lastCheckTime: Date?
    @Published public var lastError: String?
    @Published public var latencyMs: Int = 0

    private var cancellables = Set<AnyCancellable>()
    private let session: URLSession
    private var refreshGeneration: UInt64 = 0

    private init() {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 5.0
        sessionConfiguration.timeoutIntervalForResource = 5.0
        self.session = URLSession(configuration: sessionConfiguration)

        Task { [weak self] in
            await self?.refresh()
        }

        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in
                    guard ClickyConfiguration.shared.mode == .openCodex else { return }
                    await self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    /// Safely constructs the `/healthz` URL from the configured OpenCodex base URL using `URLComponents`.
    nonisolated public static func healthURL(fromBaseURL baseURLString: String) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.path = path + "/healthz"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Safely constructs an OpenCodex `/v1/...` endpoint URL from the configured base URL using `URLComponents`.
    nonisolated public static func apiEndpointURL(fromBaseURL baseURLString: String, suffix: String) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty {
            path = "/v1"
        }
        let normalizedSuffix = suffix.hasPrefix("/") ? suffix : "/\(suffix)"
        components.path = path + normalizedSuffix
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public func modelInfo(for modelID: String) -> OpenCodexModel? {
        availableModels.first { $0.id == modelID }
    }

    public func refresh() async {
        refreshGeneration &+= 1
        let activeGeneration = refreshGeneration

        let configuration = ClickyConfiguration.shared
        let baseURLString = configuration.openCodexBaseURL
        let apiKey = configuration.openCodexAPIKey

        var latestError: String?

        // 1. Health probe
        let probeStartTime = CFAbsoluteTimeGetCurrent()
        if let healthURL = Self.healthURL(fromBaseURL: baseURLString) {
            do {
                var healthRequest = URLRequest(url: healthURL)
                healthRequest.httpMethod = "GET"
                let (_, response) = try await session.data(for: healthRequest)
                guard activeGeneration == refreshGeneration else { return }

                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    self.isHealthy = true
                    self.latencyMs = Int((CFAbsoluteTimeGetCurrent() - probeStartTime) * 1000)
                } else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    self.isHealthy = false
                    latestError = "Health check returned HTTP \(statusCode)"
                }
            } catch {
                guard activeGeneration == refreshGeneration else { return }
                self.isHealthy = false
                latestError = error.localizedDescription
            }
        } else {
            self.isHealthy = false
            latestError = "Invalid OpenCodex URL"
        }

        // 2. Models fetch
        guard let modelsURL = Self.apiEndpointURL(fromBaseURL: baseURLString, suffix: "/models") else {
            self.lastError = latestError ?? "Invalid OpenCodex models URL"
            return
        }

        do {
            var modelsRequest = URLRequest(url: modelsURL)
            modelsRequest.httpMethod = "GET"
            if !apiKey.isEmpty {
                modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                modelsRequest.setValue(apiKey, forHTTPHeaderField: "x-opencodex-api-key")
            }

            let (data, response) = try await session.data(for: modelsRequest)
            guard activeGeneration == refreshGeneration else { return }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                self.lastError = latestError ?? "Models endpoint returned HTTP \(statusCode)"
                return
            }

            let decodedResponse = try JSONDecoder().decode(OpenCodexModelsResponse.self, from: data)
            let sortedModels = decodedResponse.data.sorted { $0.id < $1.id }

            self.availableModels = sortedModels
            self.visionModels = sortedModels.filter { $0.supportsVision }
            self.agentModels = sortedModels.filter { $0.supportsToolUse }
            self.lastCheckTime = Date()
            self.lastError = nil

            if configuration.mode == .openCodex {
                let visionPool = self.visionModels.isEmpty ? sortedModels : self.visionModels
                if !visionPool.contains(where: { $0.id == configuration.selectedModel }) {
                    if let preferredVisionModel = visionPool.first(where: {
                        $0.id.contains("antigravity") || $0.id.contains("gemini")
                    }) {
                        configuration.selectedModel = preferredVisionModel.id
                    } else if let firstVisionModel = visionPool.first {
                        configuration.selectedModel = firstVisionModel.id
                    }
                }

                let agentPool = self.agentModels.isEmpty ? sortedModels : self.agentModels
                if !agentPool.contains(where: { $0.id == configuration.selectedAgentModel }) {
                    if let preferredAgentModel = agentPool.first(where: {
                        $0.id == configuration.selectedModel || $0.id.contains("gpt") || $0.id.contains("claude")
                    }) {
                        configuration.selectedAgentModel = preferredAgentModel.id
                    } else if let firstAgentModel = agentPool.first {
                        configuration.selectedAgentModel = firstAgentModel.id
                    }
                }
            }
        } catch {
            guard activeGeneration == refreshGeneration else { return }
            self.lastError = latestError ?? error.localizedDescription
        }
    }
}
