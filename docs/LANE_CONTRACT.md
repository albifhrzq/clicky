# Clicky v1.1.3 + OpenCodex/BYOK Implementation Brief & Interface Contract

Read this contract completely before writing any Swift or JS code.

## Global Build & Style Rules (from `AGENTS.md` & `project.pbxproj`)
1. **Explicit Module Imports Required (`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`):**
   - Always import every framework you use: `Foundation`, `Combine` (for `ObservableObject`/`@Published`/`AnyCancellable`), `SwiftUI`, `AppKit`, `Security`, `CryptoKit`, `Network`, `AVFoundation`, `AudioToolbox`, `CoreAudio`, `Speech`, `PDFKit`, `JavaScriptCore`, `CoreText`, `ScreenCaptureKit`, `ApplicationServices`, `IOKit`, `Sparkle`, `PostHog`.
2. **Swift Concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Swift 5 mode with approachable concurrency):**
   - All classes/structs are implicitly `@MainActor` unless marked `nonisolated`.
   - Never mutate `@MainActor` properties from `DispatchQueue` / CoreAudio callbacks / `NWListener` handlers / `URLSession` completion blocks directly. Mark pure background helpers `nonisolated`, or hop via `Task { @MainActor in ... }`.
   - When accessing shared singletons (`ClickyConfiguration.shared`, `OpenCodexService.shared`, etc.), do so on `@MainActor`.
3. **Code Conventions (`AGENTS.md`):**
   - Clear, descriptive variable and method names (no single-character variables).
   - Do NOT rename `leanring-buddy` target/scheme/directory.
   - Do NOT embed ANY OAuth Client Secret (`GOCSPX-...`), API key (`sk-...`), or token in source code.
   - All buttons must show pointer cursor on hover (`.onHover` / `NSCursor.pointingHand` or `DesignSystem` button styles).

## Shared Public Interfaces (Cross-Lane Contract)

### Lane A (`ClickyConnectionMode.swift`, `OpenCodexService.swift`, `AntigravityOAuthManager.swift`, `UnifiedLLMClient.swift`)
- `ClickyConnectionMode`: `.openCodex`, `.byok`, `.cloudflareWorker`, `.nativeAntigravity`
- `ClickyConfiguration.shared` (`ObservableObject`, `@MainActor`):
  - Existing: `mode`, `openCodexBaseURL`, `openCodexAPIKey`, `selectedModel`, `workerBaseURL`, `soundEffectsEnabled`, `anthropicAPIKey`, `openaiAPIKey`, `elevenLabsAPIKey`, `assemblyAIAPIKey`, `elevenLabsVoiceID`
  - New properties (persisted to `UserDefaults` / `ClickyKeychainStore`):
    - `geminiAPIKey: String` (Keychain: `clicky_gemini_api_key`)
    - `braveAPIKey: String` (Keychain: `clicky_brave_api_key`)
    - `antigravityClientID: String` (Keychain: `antigravity_client_id`)
    - `antigravityClientSecret: String` (Keychain: `antigravity_client_secret`)
    - `selectedAgentModel: String` (UserDefaults: `clicky_selected_agent_model`, defaults to `selectedModel`)
    - `voicePipelineMode: ClickyVoicePipelineMode` (`.auto`, `.realtimeDuplex`, `.turnBased`)
    - `selectedVoiceID: String` (default `"cedar"`)
    - `selectedVoiceLanguage: String` (default `"auto"`)
    - `dictationLanguageCode: String` (default `"auto"`)
    - `dictationAutoDetect: Bool` (default `true`)
    - `hideFloatingCursor: Bool` (default `false`)
    - `cursorColorName: String` (default `"blue"` — `"red" | "blue" | "yellow" | "green"`)
    - `alwaysApproveFileUploads: Bool` (default `false`)
    - `isLocalModeWithoutPaywall: Bool` (`mode != .cloudflareWorker || workerBaseURL.contains("127.0.0.1") || workerBaseURL.contains("localhost")`)
- `OpenCodexModel`: `id`, `object`, `ownedBy`, `supportsVision: Bool`, `inputModalities: [String]`, `apiTypes: [String]`, `reasoningEfforts: [String]`, `displayName`
- `OpenCodexService.shared`:
  - `@Published var isHealthy: Bool`, `@Published var availableModels: [OpenCodexModel]`, `@Published var visionModels: [OpenCodexModel]`, `@Published var lastError: String?`, `@Published var latencyMs: Int`
  - `func refresh() async`
- `AntigravityOAuthManager.shared`:
  - `@Published var isAuthenticated: Bool`, `@Published var isAuthenticating: Bool`, `@Published var authError: String?`, `@Published var userEmail: String?`, `@Published var currentProjectNumber: String?`
  - `func signIn() async throws` (PKCE + `127.0.0.1:51121/callback` + `loadCodeAssist`)
  - `func refreshAccessTokenIfNeeded() async throws -> String`
  - `func signOut()`
- `UnifiedLLMClient`:
  - `func analyzeImageStreaming(images: [(data: Data, label: String)], systemPrompt: String, conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String, modelOverride: String?, onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> (text: String, duration: TimeInterval)` (keep default `modelOverride: String? = nil` for backward compatibility!)
  - `func completeText(systemPrompt: String, userPrompt: String, modelOverride: String? = nil) async throws -> String`
  - `static func detectImageMediaType(for data: Data) -> String` (`"image/png"` or `"image/jpeg"`)

### Lane B (`AgentHarness/`)
- `ClickyLocalAgentShim.shared`:
  - `func ensureStarted() async throws -> URL` (returns `http://127.0.0.1:<port>`)
  - `@Published var port: UInt16?`, `var sessionToken: String`
- `AgentHarnessRunnerRuntime.shared`:
  - `func startTurn(threadID: String, clickySlug: String, prompt: String, workspaceURL: URL, model: String?, mcpServers: [String: Any], skillDirectories: [String], instructions: String, imagePaths: [String], onEvent: @MainActor @Sendable @escaping (AgentHarnessEvent) -> Void) async throws -> String`
  - `func steer(jobID: String, text: String) async throws`
  - `func cancel(jobID: String) async throws`

### Lane C (`Clickys/`, `Memory/`, `Documents/`, `Routines/`, `Updates/`)
- `ClickyRoster.shared`: `clickys: [ClickyProfile]`, `createClicky(...)`, `archiveClicky(...)`, `activeClicky(forSlug:)`
- `ClickyJobStore.shared`: `jobs: [ClickyJob]`, `activeJobs`, `createJob(...)`, `updateJob(...)`, `appendReply(...)`
- `UserMemoryStore.shared`: `markdown: String`, `save(_:)`, `appendPreference(_:)`
- `ActiveDocumentReader.shared`: `func captureActiveContext() async -> ActiveDocumentContext?`
- `ClickyRoutineScheduler.shared`: `routines: [ClickyRoutine]`, `addOrUpdate(...)`, `togglePause(...)`, `delete(...)`
- `IdleUpdateInstallPolicy`: evaluates 12 busy conditions + 300s idle threshold before Sparkle install

### Lane D (`Browser/`, `ComputerUse/`)
- `ClickyLoopbackMCPServer.shared`: `func start() throws`, registers tool handlers, writes `~/Library/Application Support/Clicky/BrowserBridge/connection.json`
- `ClickyBrowserBridge.shared`: `@Published var isConnected: Bool`, `@Published var connectedBrowsers: [String]`, `func installNativeMessagingHosts()`, `func dispatchBrowserCommand(...) async throws -> [String: Any]`
- `ClickyUploadApproval.shared`: `@Published var pendingRequest: UploadApprovalRequest?`, `func requestApproval(files: [String], site: String, jobTitle: String) async -> UploadApprovalDecision`, `func resolvePending(_ decision: UploadApprovalDecision)`
- `ClickyTakeOverController.shared`: `@Published var phase: TakeOverPhase`, `var pendingConsent: TakeOverConsentRequest?`, `func runMacStep(...) async throws -> String`

### Lane E (`Audio/`, `BuddyDictationManager`, `GlobalPushToTalkShortcutMonitor`)
- `ClickyAudioTopologyMonitor.shared`: `@Published var snapshot: ClickyAudioTopologySnapshot`
- `VoiceLanguageCatalog`: `openAIVoices`, `geminiVoices`, `supportedLanguages` (133 items)
- `RealtimeVoiceController.shared`: `state`, `startSession()`, `stopSession()`, `sendTextTurn(_:)`
- `GlobalPushToTalkShortcutMonitor`: 4 slots (`voiceHold`, `textTrigger`, `dictationHold`, `handsFreeDictation`) + Escape interrupt

### Lane F (`ScreenDrawing/`, `ClickyAnalytics.swift`)
- `ScreenDrawingNativeEngine`: `beginStream(...)`, `feed(code:done:)`, `finish()`, `clear()`
- `ScreenAnnotationManager.shared`: `executeDrawingProgram(_ script: String)`, `clearAll()`
- `ClickyAnalytics` & `ClickyAITracing`: product events + trace IDs (no-op or opt-in in local mode)
