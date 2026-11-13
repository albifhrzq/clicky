# HeyClicky v1.1.3 Upgrade + OpenCodex / BYOK / OAuth Implementation Plan

> Generated from reverse-engineering **HeyClicky Mac v1.1.3** (build 71, commit `bb70d07c3`, downloaded from `https://www.heyclicky.com/` -> `HeyClicky.dmg`) using REA (`mcp__rea__*`), Mach-O/Swift metadata extraction, Bun bundle extraction (`clicky-harness.js`), and `ClickyBrowserHost` decompilation, diffed against `/root/Developer/clicky` (`HEAD` `296b4b7`).

## Reference Artifacts Preserved on Disk
- Extracted v1.1.3 JS harness (`508,762` bytes): `/root/backups/clicky-v113-re/clicky-harness.js`
- Extracted v1.1.3 `Info.plist`: `/root/backups/clicky-v113-re/Info-v113.plist`
- Extracted v1.1.3 `ClickyBrowserHost`: `/root/backups/clicky-v113-re/ClickyBrowserHost-v113`
- Updated v1.1.3 resource files (`ClickyBuildInfo.plist`, `ClickyModelInstructions.md`, `clicky-browser/references/{confirmations,files,troubleshooting}.md`): `/root/backups/clicky-v113-re/resources-v113-diff/`
- Swift types, ObjC classes/methods, reflection strings, URLs: `/root/backups/clicky-v113-re/swift_metadata/`
- Official changelog mirror: `/root/backups/clicky-v113-re/heyclicky-changelog.md`

---

## Executive Gap Summary (`/root/Developer/clicky` vs HeyClicky v1.1.3)

Commit `296b4b7` copied static v1.1.2 `Resources/` (211 files: JS drawing engines, Three.js, fonts, sounds, voice previews, bundled/integration skills, `ClickyCodexModelCatalog.json`), added `Helpers/ClickyBrowserHost`, and created 6 new Swift files (`ClickyConnectionMode`, `ClickyKeychainStore`, `OpenCodexService`, `AntigravityOAuthManager`, `UnifiedLLMClient`, `ClickySoundEffectPlayer`) plus partial `CompanionPanelView` settings UI.

However:
1. **Build & Project Wiring Broken:** `project.pbxproj` (`objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup`) flattens `Resources/` causing **19 colliding filenames** (`SKILL.md` x13, `ATTRIBUTION.md` x2, `AGENTS.md` x2, `enter.mp3`, `eshop.mp3`, `codex-add-project.png`, `steve.jpg`), places `ClickyBrowserHost` in `Resources/` instead of `Contents/Helpers/`, lacks `clicky-harness`, and has 2 compile errors (`import Combine` missing in `AntigravityOAuthManager.swift`; `@MainActor` isolation error in `ClickySoundEffectPlayer.swift`) + 1 warning (`UnifiedLLMClient.swift:462`).
2. **Auth / OpenCodex / BYOK Bugs:**
   - `CompanionManager` (`selectedClaudeModel`) and `ClickyConfiguration` (`clicky_selected_model`) are desynced; legacy `claudeAPI` still warms up on launch.
   - `UnifiedLLMClient` sends all OpenCodex models to `/v1/messages` instead of routing OpenAI/Google/Ollama models to `/v1/chat/completions`, ignores `/v1/models` `capabilities.input_modalities`, hardcodes `image/jpeg`, and has 3 protocol bugs in `executeNativeAntigravity` (`/v1internal:streamGenerateCode` instead of `daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse`, missing CCA wrapper envelope, no `loadCodeAssist`/`onboardUser`).
   - `AntigravityOAuthManager` has no `signIn()` PKCE callback server (`127.0.0.1:51121/callback`) or token auto-refresh wiring.
   - `OpenAIAudioTranscriptionProvider` reads Keychain-less `Info.plist`; `AssemblyAIStreamingTranscriptionProvider` hits v2 token endpoint for v3 WebSocket and keeps placeholder URL; `ElementLocationDetector` hardcodes raw Anthropic API.
3. **Missing v1.0 -> v1.1.3 Core & UI Features:**
   - **Agent Harness (`clicky-harness`):** No `AgentHarnessRunnerRuntime`, no `ClickyLocalAgentShim` (to route `clicky-harness` `/agent/openai/v1/responses` and `/agent/anthropic/v1/messages` through OpenCodex `127.0.0.1:10100/v1` or BYOK without `api.heyclicky.com` or paywalls), no Clickys team (`ClickyRoster`, `ClickyAppStore`, `ClickyJobStore`), no `.clicky/memory.md` or standing instructions ledger, no `ClickyRoutine` scheduler (with offline `NWPathMonitor` & dark/full wake observers).
   - **Whole-Document Reading:** No `ActiveDocumentReader` (AX + `PDFKit` + multi-browser URLs + TCC `Files & Folders` recovery).
   - **Browser Extension Bridge & v1.1.3 Upload Approval:** No `ClickyLoopbackHTTPServer` / `ClickyLoopbackMCPServer` (`~/Library/Application Support/Clicky/BrowserBridge/connection.json`, `browser_poll`/`browser_reply`), no NativeMessagingHosts manifest registration, no `heyclicky://settings/browser` router, no `ClickyUploadApproval` card, no `ClickyAppDriver` (`mac_step` / `userTookOver`).
   - **Realtime Voice, 130+ Languages & Audio Resilience:** No `ClickyAudioTopologyMonitor`, Bluetooth pre-roll (`125ms`/`250ms`), `RealtimePlayer` IO-cycle wake-freeze recovery, duplex Realtime Voice (OpenAI Realtime WS + Gemini Live Bidi WS + 10-min fallback), or system-wide Dictation (`DictationFocusContext`, AX/paste insertion, `.jsonl` archive).
   - **UI Surfaces & 2D/3D Drawing Engine:** Still uses old dark-only `MenuBarPanelManager` + basic cursor `OverlayWindow`. Missing Notch UI, expandable `HeyClickyWindow` (sidebar + chat + document split + Light/Dark), Home Space / `ClickyArcCard` / `ClickyInk` live note viewer, 12-section Settings, and `ScreenDrawingNativeEngine` (`JSContext` -> `clicky-draw-*.js` -> CoreAnimation/CoreText/Metal + `ClickyThreeKernel`).

---

## Phased Implementation Plan

### Phase 0 — Project Hygiene, Build Fixes & v1.1.3 Resource Sync
1. **Sync v1.1.3 Resources & Helpers:**
   - Copy the 5 updated resource files from `/root/backups/clicky-v113-re/resources-v113-diff/` into `leanring-buddy/Resources/` (`ClickyBuildInfo.plist`, `ClickyModelInstructions.md`, `ClickyBundledSkills/clicky-browser/references/{confirmations,files,troubleshooting}.md`).
   - Copy `/root/backups/clicky-v113-re/clicky-harness.js` into `leanring-buddy/Resources/clicky-harness.js` (or `Helpers/clicky-harness-runner.js` — see Phase 2).
   - Update `leanring-buddy/Helpers/ClickyBrowserHost` with `/root/backups/clicky-v113-re/ClickyBrowserHost-v113` (if re-signing under user's Developer ID in Xcode, configure `release.sh` to sign `Contents/Helpers/ClickyBrowserHost` too).
   - Deduplicate `enter.mp3`, `eshop.mp3`, `codex-add-project.png`, `steve.jpg` (keep only in `Resources/`).
2. **Fix `leanring-buddy.xcodeproj/project.pbxproj`:**
   - Convert `Resources/ClickyBundledSkills` and `Resources/ClickyIntegrationSkills` (and nested dirs) to folder references or configure `PBXFileSystemSynchronizedBuildFileExceptionSet` / `PBXGroup` so subdirectory layout (`ClickyBundledSkills/clicky-browser/SKILL.md`, etc.) is preserved in `Contents/Resources/` without filename collisions.
   - Exclude `Helpers/` and `AGENTS.md` from `Copy Bundle Resources`, and add a `PBXCopyFilesBuildPhase` copying `Helpers/ClickyBrowserHost` to `Contents/Helpers` (`dstSubfolderSpec = 16` / `Wrapper` -> `Contents/Helpers`).
   - Clean up target settings (`DEVELOPMENT_TEAM` consistency, version `1.1.3` / build `71`, keep `leanring-buddy` scheme/dir name per `AGENTS.md`).
3. **Update `Info.plist` & `leanring-buddy.entitlements`:**
   - Add `heyclicky` alongside `clicky` in `CFBundleURLTypes`.
   - Add `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`.
   - Add `NSSupportsAutomaticTermination = false`, `NSSupportsSuddenTermination = false`.
   - Update permission descriptions from `"Clicky"` to `"HeyClicky"`.
   - Add `<key>com.apple.security.cs.allow-jit</key><true/>` to `leanring-buddy.entitlements` (needed by JavaScriptCore / Bun / Metal).
4. **Fix Existing Compile Errors from `296b4b7`:**
   - `AntigravityOAuthManager.swift`: add `import Combine`.
   - `ClickySoundEffectPlayer.swift`: properly isolate `audioPlayers` access with `@MainActor` / `Task { @MainActor in ... }` instead of mutating MainActor state from `DispatchQueue.global()`.
   - `UnifiedLLMClient.swift:462`: remove redundant `as? [String: Any]` cast.
   - Security check: verify initial git history warning (`aebc793`) and ensure NO OAuth client secrets (`GOCSPX-...`) or `sk-` keys are ever committed to source.

### Phase 1 — Unified Connection Layer: OpenCodex + Direct OAuth + BYOK + Local-First (No Paywall)
1. **Single Source of Truth (`ClickyConfiguration` & `CompanionManager`):**
   - Remove duplicate `"selectedClaudeModel"` / `CompanionManager.selectedModel` and dead `claudeAPI` warmup; bind all model selection to `ClickyConfiguration.shared.selectedModel` (key `clicky_selected_model`).
   - Add Keychain fields in `ClickyKeychainStore` + `ClickyConfiguration`: `geminiAPIKey`, `braveAPIKey`, `openCodexAPIKey` (optional for non-loopback OpenCodex), `antigravityClientID`, `antigravityClientSecret`.
   - Ensure local modes (`.openCodex`, `.byok`, `.nativeAntigravity`, self-hosted `.cloudflareWorker`) initialize directly as unlocked/unlimited with **zero HeyClicky Supabase login gate and zero paywall**.
2. **Fix `OpenCodexService.swift`:**
   - Build `/healthz` URL safely with `URLComponents` (don't blindly replace `"/v1"`).
   - Parse `/v1/models` `capabilities.supports_vision`, `capabilities.input_modalities`, `api_types`, and `reasoning_efforts` into `OpenCodexModelInfo`; expose filtered vision-capable models (`supportsVision == true`) and reasoning/agent models separately.
   - Trigger `refresh()` immediately when user switches to `.openCodex` mode or edits `openCodexBaseURL`.
3. **Fix `UnifiedLLMClient.swift` & `ElementLocationDetector.swift`:**
   - **OpenCodex routing:** Route `anthropic/*` (or models preferring `anthropic_messages` in `api_types`) to `POST /v1/messages` (`Authorization: Bearer` + `x-opencodex-api-key` + `anthropic-version: 2023-06-01`), and route `openai/*`, `gpt-*`, `google-antigravity/gemini-*`, `ollama-cloud/*` to `POST /v1/chat/completions` (`Authorization: Bearer`). Remove hardcoded `4096` `max_tokens` cap where model allows higher.
   - **Image MIME detection:** Replace hardcoded `"image/jpeg"` with magic-byte check (`0x89 0x50 0x4E 0x47` -> `image/png`, else `image/jpeg`).
   - **Native Antigravity OAuth & CCA API:**
     - Implement full PKCE sign-in in `AntigravityOAuthManager` (`127.0.0.1:51121/callback` local `NWListener` + `NSWorkspace.shared.open` + `oauth2.googleapis.com/token` exchange + `loadCodeAssist`/`onboardUser` project discovery) using user-supplied Desktop OAuth Client ID/Secret in Keychain.
     - Always call `try await AntigravityOAuthManager.shared.refreshAccessTokenIfNeeded()` before requests.
     - Fix `executeNativeAntigravity` URL to `https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse` and send the proper Cloud Code Assist envelope `{ model, userAgent: "antigravity", requestType: "agent", project, requestId: "agent-\(UUID())", request: { contents, systemInstruction, generationConfig } }`.
   - **Route `ElementLocationDetector` through `UnifiedLLMClient`** (no hardcoded `api.anthropic.com` + `x-api-key`).
   - **Fix Audio Provider BYOK Configs:**
     - `OpenAIAudioTranscriptionProvider`: read `ClickyConfiguration.shared.openaiAPIKey` from Keychain (not `Info.plist`).
     - `AssemblyAIStreamingTranscriptionProvider`: remove placeholder `your-worker-name...` URL; in BYOK mode call `GET https://streaming.assemblyai.com/v3/token?expires_in_seconds=480` (matching v3 WebSocket).
     - `ElevenLabsTTSClient`: read dynamic `ClickyConfiguration.shared.workerBaseURL` at request time; fall back cleanly to `AVSpeechSynthesizer` when unconfigured.

### Phase 2 — `clicky-harness` Runtime + `ClickyLocalAgentShim` (OpenCodex & BYOK Agent Backend)
1. **Local Agent Shim (`ClickyLocalAgentShim.swift`, `NWListener` on `127.0.0.1:0`):**
   - Serves the upstream routes expected by `clicky-harness` locally so zero requests ever leak to `api.heyclicky.com` in `.openCodex` / `.byok` / `.nativeAntigravity` modes:
     - `POST /agent/openai/v1/responses` & `/agent/openai/v1/responses/compact` -> proxies to OpenCodex `/v1/responses` (or OpenAI BYOK `/v1/responses`), translating/mapping model IDs (e.g., `gpt-6-luna` / `gpt-6.1-sol` -> user's selected OpenCodex agent model, or pass-through when already a valid OpenCodex ID) and injecting OpenCodex Bearer auth if configured.
     - `POST /agent/anthropic/v1/messages` -> proxies to OpenCodex `/v1/messages` (or Anthropic BYOK `/v1/messages` with `x-api-key`).
     - `GET /agent/web-search` & `POST /agent/web-search` -> returns `{ "available": true }` and proxies to OpenCodex `POST /v1/alpha/search` (or Brave Search API if `braveAPIKey` is set).
     - `POST /codex-thread-launch`, `/codex-thread-title`, `/agent-messages` -> generates thread titles locally via `UnifiedLLMClient` and returns local JSON acknowledgements.
     - `POST /agent/turn-lease/*`, `/agent/record-agent-launch`, `/me/plan` -> local unlimited no-op responses.
2. **Patched Runner (`clicky-harness-runner.js` derived from v1.1.3 `clicky-harness.js`):**
   - Bundle `clicky-harness-runner.js` in `Resources/` and launch via `AgentHarnessRunnerRuntime` (using local `bun` or `node` binary, or `ClickyAgentHarnessRunnerPath` / `ClickyAgentHarnessNodePath` overrides).
   - Patch the 4 hardcoded harness constraints in `clicky-harness.js`:
     - `w_(model, place)` (L522): allow any dynamic OpenCodex / BYOK model ID instead of forcing `gpt-6-luna` when outside `M_`/`c5`.
     - `Wp()` compaction (L334): use the active job's selected model instead of hardcoded `gpt-6-luna`.
     - `f_()` / `hI()` (L512, L207): accept `H1_ANTHROPIC_API_KEY` / `x-api-key` header when targeting direct Anthropic BYOK, and keep `Authorization: Bearer` for OpenCodex/Shim.
     - `Io.start()` / `g5()` (L512, L554): preserve `BRAVE_API_KEY` if supplied via harness config and allow disabling `remoteCompaction` when backend uses `/v1/chat/completions` or Anthropic.
3. **Swift Runner Process Manager (`AgentHarnessRunnerRuntime.swift`, `AgentHarnessRunnerProcess.swift`, `AgentHarnessEvent.swift`):**
   - Spawns `clicky-harness-runner.js` with `CLICKY_HARNESS_TOKEN` (random per-launch secret) & `CLICKY_HARNESS_STATE` (`~/Library/Application Support/Clicky/AgentHarness`).
   - Reads `{"ready":true,"port":...}` stdout line (`AgentHarnessReadyLineReader`).
   - Drives `POST /prewarm`, `POST /turn`, `POST /steer`, `POST /cancel`, and long-polls `GET /events?job=...&after=...&wait=20000`.
   - Parses structured XML completion tags (`<SUMMARY>`, `<ANSWER>`, `<ARTIFACTS>`, `<DONE_TITLE>`, `<NEXT_ACTIONS>`, `<ROUTINE>`, `<COMPUTER_USE_REQUEST>`, `<WAIT_FOR>`, `<LEARNED>`).

### Phase 3 — Core v1.1.3 Capabilities (Clickys, Memory, Whole-Doc, Routines, Idle Update)
1. **Clickys Multi-Agent System (`ClickyRoster.swift`, `ClickyAppStore.swift`, `ClickyJobStore.swift`, `ClickyWorkFolderFiles.swift`):**
   - Persist roster (`clicky.roster.v1`) and jobs (`clicky.jobs.v1`), works (`~/Library/Application Support/ClickyApps/works.json`), and per-Clicky workspace folders (`AGENTS.md`, `note.md`, `.clicky/previous-note.md`, `.clicky/memory.md`, `report.md`, `output/`, `tmp/`).
   - Track restart/interruption state (`clicky.clickys.runningTurns.v1`) and auto-title threads locally.
   - `ClickyJobStepWatcher`: resumes jobs waiting on `<WAIT_FOR>` URL transitions.
2. **Memory & Standing Instructions (`UserMemoryStore.swift`, `ClickyAgentStandingContextLedger.swift`, `ClickyLearnedHowTos.swift`):**
   - Local-first user memory markdown (`~/Library/Application Support/Clicky/user-memory.md` + `helper/about-the-user.md`), editable in Settings and auto-updated when user states preferences ("give shorter answers", "yes/no first", "simpler words") — matching v1.1.3's *"Answers the way you like them"* feature.
   - Per-thread `ClickyAgentStandingContextLedger` tracking section fingerprints (`userMemory`, `agentInstructions`, `activeSkills`, `learnedHowTos`) so instructions re-inject only on first turn or preference changes.
3. **Whole-Document Understanding (`ActiveDocumentReader.swift`, `ActiveBrowserSiteReader.swift`, `DocumentAccessNotice`):**
   - Inspect frontmost window via Accessibility API (`AXFocusedWindow`, `AXDocument`, `AXURL`, `AXTitle`, `AXStaticText`, `AXSelectedText`) + `PDFKit` (`PDFDocument`) full-text extraction for local PDFs/documents + URL bar inspection across 14 browsers (Safari, Chrome, Arc, Dia, Brave, Opera, Vivaldi, Comet, Atlas).
   - Detect macOS `Files & Folders` TCC denial and display an inline recovery prompt linking to `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`.
4. **Routines & Sleep/Network Resilience (`ClickyRoutineScheduler.swift`, `ClickyRoutineNetworkObserver.swift`, `ClickyRoutineFullWakeObserver.swift`, `ClickyRoutineKeepAwake.swift`):**
   - Interval & time-of-day/weekday schedules + `repeat_this_job` local MCP tool.
   - `NWPathMonitor` holds due routines while offline (`waitingForNetworkSince`) instead of failing/retrying every 5 min.
   - Full-wake observer distinguishes dark wake from screen wake before firing overdue routines; `IOPMAssertion` keeps Mac awake on AC while armed; auto-pauses after consecutive failures.
5. **Screen-Change Guard & Sparkle Idle Auto-Install:**
   - Before displaying a next walkthrough/follow-up step, re-check if mouse/scroll/frontmost window changed (`GuidedFollowUpRequestContext`); re-capture screen before continuing (v1.1.3 *"checks your screen before giving the next step"*).
   - Wire `SparkleUpdateDelegate` + `IdleUpdateInstallPolicy` (12 idle conditions; auto-installs downloaded Sparkle update after 5 min idle, configurable/optional for fork builds).

### Phase 4 — Browser Extension Bridge (`ClickyBrowserHost`), `upload_approval` (v1.1.3) & Computer-Use (`ClickyAppDriver`)
1. **Local Loopback HTTP & MCP Server (`ClickyLoopbackHTTPServer.swift`, `ClickyLoopbackMCPServer.swift`, `ClickyLocalRootToolExecutor.swift`):**
   - Bind `127.0.0.1:0` with random bearer token, write `~/Library/Application Support/Clicky/BrowserBridge/connection.json` (`{"port": ..., "token": "..."}`).
   - Serve `POST /mcp` (JSON-RPC `2025-03-26` `tools/call`) for `browser_poll`, `browser_reply`, `find_jobs`, `read_job`, `repeat_this_job`, `mac_step`, `note*`, `shell_exec`, `file_write`, `file_list`, `reveal_artifact`.
2. **Browser Bridge & Native Messaging Registration (`ClickyBrowserBridge.swift`, `ClickyChromeSetupFlow.swift`):**
   - Auto-install Native Messaging Host JSON manifests (`com.heyclicky.browser.json`) into Chrome, Brave, Edge, Arc, Vivaldi `NativeMessagingHosts/` pointing to `Bundle.main.bundlePath + "/Contents/Helpers/ClickyBrowserHost"` with `allowed_origins: ["chrome-extension://bphdnlcghkpiaoiplkhfofpfboddahce/"]`.
   - Route `heyclicky://settings/browser` deep-links in `CompanionAppDelegate`.
   - Track active browser sessions (`session`, `profile`, `browser`, `extension`, `selected`), dispatch commands via `browser_poll` waiters, and correlate `browser_reply`.
   - Support Chrome Web Store 1-click install/swap guidance (`ClickyBrowserSetup.html`).
3. **`upload_approval` Card & Security Guard (`ClickyUploadApproval.swift`):**
   - Implement `upload_approval` MCP/bridge handling: allow files inside job workspace without prompt; block private paths (`~/.ssh`, Keychains, `.env`, key files, browser profiles, app settings) unconditionally; prompt user once per turn via Notch card (`Approve this time` / `Always approve` / `Decline`) for files outside the job folder, caching `UploadApprovalAnswer` for the turn.
4. **Computer-Use / Take-Over (`ClickyAppDriver.swift`, `ClickyTakeOverController.swift`, `ClickyScreenActuator.swift`, `ClickyUserInputBlocker.swift`):**
   - Implement `mac_step` consent card (`ClickyTakeOverConsentCard`), animated cursor takeover (`ClickyTakeOverOverlay`), and `userTookOver` user-input monitor that immediately aborts driving and releases control when the user moves/clicks.

### Phase 5 — Realtime Voice, 130+ Languages, Dictation & Audio Resilience
1. **Audio Hardware & Freeze Fixes (`ClickyAudioTopologyMonitor.swift`, `ClickyChimeWarmer.swift`, `RealtimePlayer.swift`):**
   - Install CoreAudio HAL property listeners (`'dOut'`, `'dIn '`, `'dev#'`, `'ssrc'`) on a background serial queue (no main-thread beachballs on sleep/wake/BT connect).
   - Wire `ClickySoundEffectPlayer` with Bluetooth pre-roll (`0.125s` wired / `0.25s` Bluetooth) so UI chimes and finish cues don't clip.
   - Detect `AVAudioEngine` `runningWithoutIOCycle` freeze after sleep/wake and rebuild automatically (`0.25s`, `0.5s`, `1.0s` retries).
   - Call/DND quiet detector (`ClickyCallPresenceDetector`, `ClickyFocusModeDetector`) to silence spoken announcements during calls or Do Not Disturb.
2. **Capability-Based Voice Pipeline (OpenCodex + BYOK):**
   - **Path A (BYOK Duplex Realtime):** Direct `URLSessionWebSocketTask` to OpenAI Realtime (`wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`, 10 voices) or Gemini Live (`wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=...`, 30 voices, 133 languages `VoiceLanguageCatalog`) with `GeminiMouthProtocol` normalization + 10-minute cooldown fallback (`Gemini` -> `OpenAI`). Also support OpenCodex `/v1/realtime` when available.
   - **Path B (Hybrid OpenCodex / Antigravity / Turn-Based):**
     - *Ears (STT):* Gemini Live Ears (`geminiAPIKey`) -> AssemblyAI v3 streaming (`assemblyAIAPIKey`) -> OpenAI `gpt-4o-transcribe` (`openaiAPIKey` or OpenCodex `/v1/audio/transcriptions`, removing hardcoded `"en"`) -> Apple Speech (`SFSpeechRecognizer`, zero-key offline).
     - *Brain:* `UnifiedLLMClient` (`.openCodex` / `.nativeAntigravity` / `.byok` / `.cloudflareWorker`).
     - *Mouth (TTS):* ElevenLabs -> OpenAI `/v1/audio/speech` -> Gemini TTS -> `AVSpeechSynthesizer` offline fallback.
   - Add `RealtimeDuplexAudioEngine` (`VoiceProcessingIO` AEC with per-topology zombie fallback cache + held BT `AVCaptureSession` between turns).
3. **System-Wide Dictation & 4-Slot Shortcuts (`GlobalPushToTalkShortcutMonitor.swift`, `ClickyDictationController.swift`):**
   - Support 4 configurable shortcuts (`voiceHold`, `textTrigger`, `dictationHold`, `handsFreeDictation`) including double-tap modifier triggers + Escape interrupt.
   - Capture `DictationFocusContext` (AX focused element + Electron/Chromium AX activation) and inject via AX direct typing or `pidTargetedPasteAndReturn` (with clipboard restore + `NotchDictationClipboardSurface` fallback).
   - Run optional transcript cleanup via `UnifiedLLMClient`, archive every transcript locally to `~/Library/Application Support/Clicky/DictationTranscripts/yyyy-MM-dd.jsonl`, and salvage partial transcripts to clipboard on interruption/sleep.

### Phase 6 — UI Surfaces (Notch, Expandable Window, Home Space, Settings) & 2D/3D Drawing Engine
1. **Design System Light/Dark + Frosted Panes (`DesignSystem.swift`):**
   - Refactor `DS.Colors` to adapt to system Light/Dark (`NSAppearance`) and add `ClickyPanelBackground` (`NSVisualEffectView` translucent panes vs classic fill).
2. **Notch UI & Live Event Surfaces (`Notch/`):**
   - Replace `MenuBarPanelManager` popover as primary surface (keep optional menu-bar icon fallback) with multi-display `NotchWindowManager` (`NotchPanel`, `NotchRestingMarkSurface` with unread gel badge & corner glow, `NotchActivitySurface`, `NotchTextInputSurface`, `NotchTextResponseSurface`, `NotchHeyClickyPeekSurface` with `home`/`chat`/`settings`/`document` tabs, and toast surfaces including `ClickyUploadApproval`, `ClickyTakeOverConsentCard`, `NotchDocumentAccessSurface`).
3. **Expandable HeyClicky Window (`HeyClickyWindow/`):**
   - Implement `HeyClickyWindowController` (`NSWindow` expanding from notch, resizable, persisted frame & column width):
     - Toggleable Sidebar (`"Your chat"` + Clickys grouped into `working`, `recents`, `earlier` with unread dots).
     - Main conversation transcript + composer + stop button + follow-up pills.
     - Side-by-side Document Column (`HeyClickyWindowDocumentColumn`) rendering Markdown, PDF (`PDFView`), images, and CSV/XLSX tables (`SpreadsheetGridView`).
4. **Home Space, Arc Cards & ClickyInk (`HomeSpace/`, `Ink/`):**
   - Build `ClickyArcCard` / `ClickyArcPlan` / `ClickyArcProgressBar` (`ClickyArcGelTrack`) / `ClickyArcFileChip` / `ClickyResultCardFace` (numbers, lists, receipts, choices, next-step button).
   - Build `ClickyInkParser` + `ClickyInkSheetView` rendering live `note.md` directives (`::ask`, `:::sticky`, `:::ticket`, `:::receipt`, `:::chart`, `:::todo`, etc.).
   - Build `ClickyAgentIconView` + `ClickyAgentProp` (28 props + animated mood/expression faces).
5. **12-Section Settings (`HomeSpaceSettingsPage.swift`):**
   - **Connection & Models (Fork Superpower):** Mode switcher (`.openCodex`, `.byok`, `.nativeAntigravity`, `.cloudflareWorker`), OpenCodex live health + `/v1/models` vision/agent model pickers, Antigravity PKCE OAuth Sign-In + Client ID/Secret inputs, Keychain BYOK inputs (Anthropic, OpenAI, Gemini, ElevenLabs, AssemblyAI, Brave).
   - **General / Shortcuts / Voice / Cursor / Integrations / Routines:** 4-slot hotkey recorder, 133-language & voice preview picker, `"Hide floating cursor"` toggle + 4 cursor color swatches (`red`, `blue`, `yellow`, `green`), Chrome Extension bridge status & setup, Custom MCP Connectors (stdio + remote HTTP/OAuth), Routines manager, User Memory editor.
6. **2D/3D Drawing Engine (`ScreenDrawing/`):**
   - `ScreenDrawingNativeEngine`: `JSContext` loading `clicky-draw-native.js`, `clicky-draw-engine.js`, `clicky-draw-pieces.js`, exposing `__host` (`textBox`/`textWidth`/`pathBox`/`pathLength`/`pathPoint` via CoreText & `CGPath`, `inkFor`/`lumFor` screen sampling, timers, `shape3d`), running `__drainRender()` -> `ScreenDrawingNativePainter` (`CALayer`/`CAShapeLayer` + `ClickyDraw-PatrickHand.ttf` + `ScreenDrawingPenCursorController` + `ScreenDrawingActionButtons`).
   - `ClickyThreeKernel` + `ScreenDrawing3DStage`: background `JSContext` loading `clicky-three.js` + `clicky-three-parts.js` -> Metal `DaVinci3DRenderer` for `figure()` / `scene3d()`.
   - Wire `OneBrain` JS drawing blocks (`step()`, `say()`, `ring()`, `trace()`, `paper()`, `figure()`, `button()`) with `RealtimeWalkthroughSync` and `GuidedClickTarget` click-completion detection.

### Phase 7 — Optional Self-Hosted Worker (`worker/src/index.ts`) & Verification
1. Extend `worker/src/index.ts` optionally with `/v1/responses` and `/agent/*` passthrough for users deploying their own Cloudflare Worker.
2. **Verification (Linux VPS vs macOS Xcode):**
   - *On Linux VPS (automated during implementation):*
     - Validate `project.pbxproj` structure & zero duplicate resource filenames (`plutil`/python plist parser + file existence check).
     - Verify `Info.plist` & `entitlements` XML validity.
     - Run `node --check` & unit/integration smoke tests against patched `clicky-harness-runner.js` and mock OpenCodex/BYOK endpoints.
     - Audit every Swift file for `import Combine` / `@MainActor` / `Sendable` / naming conventions (`AGENTS.md`) and run `git diff` secret scan (zero `GOCSPX-`, `sk-`, or hardcoded keys).
   - *On macOS (user runs in Xcode):*
     - Open `leanring-buddy.xcodeproj` in Xcode (do NOT run `xcodebuild` from terminal per `AGENTS.md` TCC rule), resolve Swift Packages (Sparkle, etc.), `Cmd+R` build & launch.
     - Verify OpenCodex mode live `/v1/models` + vision chat + `clicky-harness` agent task + BYOK/OAuth + Chrome `ClickyBrowserHost` + `upload_approval` + Notch/Window/Drawing Engine.
