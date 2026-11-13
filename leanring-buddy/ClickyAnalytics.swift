//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog analytics wrapper, AI trace ID correlation (ClickyAITracing),
//  in-memory RecentAppError ring buffer, and v1.1.3 structured product events.
//  Respects local/offline mode: PostHog is only initialized when PostHogAPIKey is
//  present in Info.plist or analyticsEnabled is explicitly true.
//

import Foundation
import PostHog

// MARK: - Recent App Error Ring Buffer

public struct RecentAppError: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let domain: String
    public let message: String
    public let traceID: String?
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: String,
        message: String,
        traceID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.message = message
        self.traceID = traceID
        self.metadata = metadata
    }
}

public final class ClickyRecentErrorBuffer: @unchecked Sendable {
    public nonisolated static let shared = ClickyRecentErrorBuffer()

    private nonisolated let lock = NSLock()
    private nonisolated let capacity = 50
    private nonisolated(unsafe) var entries: [RecentAppError] = []

    private nonisolated init() {}

    public nonisolated func record(
        domain: String,
        message: String,
        traceID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let entry = RecentAppError(
            domain: domain,
            message: message,
            traceID: traceID,
            metadata: metadata
        )
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    public nonisolated func snapshot() -> [RecentAppError] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public nonisolated func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    public nonisolated func formattedReport() -> String {
        let items = snapshot()
        if items.isEmpty { return "No recent app errors recorded." }
        let formatter = ISO8601DateFormatter()
        return items.reversed().map { item in
            let ts = formatter.string(from: item.timestamp)
            let tracePart = item.traceID.map { " [trace:\($0)]" } ?? ""
            return "[\(ts)] [\(item.domain)]\(tracePart) \(item.message)"
        }.joined(separator: "\n")
    }
}

// MARK: - AI Request & Session Tracing

public final class ClickyAITracing: @unchecked Sendable {
    public nonisolated static let shared = ClickyAITracing()

    private nonisolated let lock = NSLock()
    private nonisolated let maxTraceHistory = 100

    private nonisolated(unsafe) var _currentSessionID: String = UUID().uuidString.lowercased()
    private nonisolated(unsafe) var _currentTraceID: String?
    private nonisolated(unsafe) var _traceIDs: [String] = []

    private nonisolated init() {}

    public nonisolated var currentSessionID: String {
        lock.lock()
        defer { lock.unlock() }
        return _currentSessionID
    }

    public nonisolated var currentTraceID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _currentTraceID
    }

    public nonisolated var traceIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _traceIDs
    }

    @discardableResult
    public nonisolated func startNewSession() -> String {
        let next = UUID().uuidString.lowercased()
        lock.lock()
        _currentSessionID = next
        _currentTraceID = nil
        lock.unlock()
        return next
    }

    @discardableResult
    public nonisolated func beginTrace(prefix: String = "clk") -> String {
        let traceID = "\(prefix)_\(UUID().uuidString.lowercased())"
        lock.lock()
        _currentTraceID = traceID
        _traceIDs.append(traceID)
        if _traceIDs.count > maxTraceHistory {
            _traceIDs.removeFirst(_traceIDs.count - maxTraceHistory)
        }
        lock.unlock()
        return traceID
    }

    public nonisolated func endTrace(_ traceID: String) {
        lock.lock()
        if _currentTraceID == traceID {
            _currentTraceID = nil
        }
        lock.unlock()
    }

    public nonisolated func traceHeaders(traceID: String? = nil) -> [String: String] {
        lock.lock()
        let activeTrace = traceID ?? _currentTraceID ?? "\(UUID().uuidString.lowercased())"
        let session = _currentSessionID
        lock.unlock()
        return [
            "X-Clicky-Trace-Id": activeTrace,
            "X-Clicky-Session-Id": session
        ]
    }

    public nonisolated func applyTraceHeaders(to request: inout URLRequest, traceID: String? = nil) {
        for (header, value) in traceHeaders(traceID: traceID) {
            request.setValue(value, forHTTPHeaderField: header)
        }
    }
}

// MARK: - Centralized Analytics

enum ClickyAnalytics {

    private static let analyticsEnabledKey = "clicky_analytics_enabled"
    private static let defaultPostHogHost = "https://us.i.posthog.com"

    private static var isConfigured = false

    static var analyticsEnabled: Bool {
        get {
            if let stored = UserDefaults.standard.object(forKey: analyticsEnabledKey) as? Bool {
                return stored
            }
            return AppBundleConfiguration.stringValue(forKey: "PostHogAPIKey") != nil
        }
        set {
            UserDefaults.standard.set(newValue, forKey: analyticsEnabledKey)
            if newValue && !isConfigured {
                configure()
            }
        }
    }

    private static var isLocalOrOfflineMode: Bool {
        let config = ClickyConfiguration.shared
        if config.mode != .cloudflareWorker {
            return true
        }
        let host = config.workerBaseURL.lowercased()
        return host.contains("127.0.0.1") || host.contains("localhost")
    }

    // MARK: - Setup

    static func configure() {
        let plistAPIKey = AppBundleConfiguration.stringValue(forKey: "PostHogAPIKey")
        let explicitOptIn = (UserDefaults.standard.object(forKey: analyticsEnabledKey) as? Bool) == true

        // Respect local/offline mode: only initialize PostHog when PostHogAPIKey is in Info.plist or analyticsEnabled is true.
        guard plistAPIKey != nil || explicitOptIn else {
            isConfigured = false
            return
        }

        if isLocalOrOfflineMode && !explicitOptIn && plistAPIKey == nil {
            isConfigured = false
            return
        }

        guard let apiKey = plistAPIKey, !apiKey.isEmpty else {
            isConfigured = false
            return
        }

        let host = AppBundleConfiguration.stringValue(forKey: "PostHogHost") ?? defaultPostHogHost
        let config = PostHogConfig(apiKey: apiKey, host: host)
        PostHogSDK.shared.setup(config)
        isConfigured = true
    }

    // MARK: - Core Capture & Error Recording

    static func capture(_ event: String, properties: [String: Any] = [:]) {
        guard isConfigured, analyticsEnabled else { return }
        var enriched = properties
        enriched["session_id"] = ClickyAITracing.shared.currentSessionID
        if let traceID = ClickyAITracing.shared.currentTraceID, enriched["trace_id"] == nil {
            enriched["trace_id"] = traceID
        }
        enriched["connection_mode"] = ClickyConfiguration.shared.mode.rawValue
        PostHogSDK.shared.capture(event, properties: enriched)
    }

    static func identify(userID: String, properties: [String: Any] = [:]) {
        guard isConfigured, analyticsEnabled else { return }
        PostHogSDK.shared.identify(userID, userProperties: properties)
    }

    static func recordAppError(
        domain: String,
        message: String,
        traceID: String? = ClickyAITracing.shared.currentTraceID,
        metadata: [String: String] = [:]
    ) {
        ClickyRecentErrorBuffer.shared.record(
            domain: domain,
            message: message,
            traceID: traceID,
            metadata: metadata
        )
    }

    static var recentErrors: [RecentAppError] {
        ClickyRecentErrorBuffer.shared.snapshot()
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        capture("app_opened", properties: [
            "app_version": version,
            "connection_mode": ClickyConfiguration.shared.mode.rawValue
        ])
    }

    // MARK: - Onboarding

    static func trackOnboardingStarted() {
        capture("onboarding_started")
    }

    static func trackOnboardingReplayed() {
        capture("onboarding_replayed")
    }

    static func trackOnboardingVideoCompleted() {
        capture("onboarding_video_completed")
    }

    static func trackOnboardingDemoTriggered() {
        capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {
        capture("all_permissions_granted")
    }

    static func trackPermissionGranted(permission: String) {
        capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {
        capture("push_to_talk_started")
    }

    static func trackPushToTalkReleased() {
        capture("push_to_talk_released")
    }

    static func trackUserMessageSent(transcript: String) {
        capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    static func trackAIResponseReceived(response: String) {
        capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    static func trackElementPointed(elementLabel: String?) {
        capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
    }

    // MARK: - v1.1.3 Structured Product Events

    static func trackConnectionModeChanged(mode: ClickyConnectionMode) {
        capture("connection_mode_changed", properties: [
            "mode": mode.rawValue
        ])
    }

    static func trackDrawingStarted(streaming: Bool, has3D: Bool = false) {
        capture("screen_drawing_started", properties: [
            "streaming": streaming,
            "has_3d": has3D
        ])
    }

    static func trackDrawingCompleted(
        markCount: Int,
        inkedCount: Int,
        hasPicture: Bool,
        durationSeconds: Double,
        error: String? = nil
    ) {
        var props: [String: Any] = [
            "mark_count": markCount,
            "inked_count": inkedCount,
            "has_picture": hasPicture,
            "duration_seconds": durationSeconds
        ]
        if let error {
            props["error"] = error
            recordAppError(domain: "screen_drawing", message: error)
        }
        capture("screen_drawing_completed", properties: props)
    }

    static func trackDrawingActionTriggered(kind: String, label: String?) {
        capture("screen_drawing_action_triggered", properties: [
            "kind": kind,
            "label": label ?? ""
        ])
    }

    static func trackGuidedTargetCompleted(role: String, label: String?) {
        capture("guided_target_completed", properties: [
            "role": role,
            "label": label ?? ""
        ])
    }

    static func trackAgentTurnStarted(clickySlug: String, model: String, traceID: String? = nil) {
        var props: [String: Any] = [
            "clicky_slug": clickySlug,
            "model": model
        ]
        if let traceID { props["trace_id"] = traceID }
        capture("agent_turn_started", properties: props)
    }

    static func trackAgentTurnCompleted(
        clickySlug: String,
        durationSeconds: Double,
        succeeded: Bool,
        traceID: String? = nil,
        error: String? = nil
    ) {
        var props: [String: Any] = [
            "clicky_slug": clickySlug,
            "duration_seconds": durationSeconds,
            "succeeded": succeeded
        ]
        if let traceID { props["trace_id"] = traceID }
        if let error {
            props["error"] = error
            recordAppError(domain: "agent_harness", message: error, traceID: traceID)
        }
        capture("agent_turn_completed", properties: props)
    }

    static func trackVoicePipelineEvent(pipeline: String, event: String, language: String? = nil) {
        var props: [String: Any] = [
            "pipeline": pipeline,
            "event": event
        ]
        if let language { props["language"] = language }
        capture("voice_pipeline_event", properties: props)
    }

    static func trackBrowserBridgeAction(action: String, browser: String?, succeeded: Bool) {
        capture("browser_bridge_action", properties: [
            "action": action,
            "browser": browser ?? "unknown",
            "succeeded": succeeded
        ])
    }

    static func trackRoutineTriggered(routineName: String) {
        capture("routine_triggered", properties: [
            "routine_name": routineName
        ])
    }

    static func trackUploadApprovalDecision(decision: String, fileCount: Int) {
        capture("upload_approval_decision", properties: [
            "decision": decision,
            "file_count": fileCount
        ])
    }

    static func trackTakeOverStep(phase: String, stepDescription: String? = nil) {
        var props: [String: Any] = ["phase": phase]
        if let stepDescription { props["step"] = stepDescription }
        capture("takeover_step", properties: props)
    }

    // MARK: - Errors

    static func trackResponseError(error: String) {
        recordAppError(domain: "ai_response", message: error)
        capture("response_error", properties: [
            "error": error
        ])
    }

    static func trackTTSError(error: String) {
        recordAppError(domain: "tts", message: error)
        capture("tts_error", properties: [
            "error": error
        ])
    }
}
