# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity. The overlay does not auto-hide while the onboarding tour runs.

**Onboarding Tour**: First-run onboarding is an interactive tour (talk → point → text mode → dictation → drive → notch → done) driven by `ClickyOnboardingTourController` in `Onboarding/ClickyOnboardingTour.swift`. It replaces the old onboarding video. The tour is a pure step machine fed by shortcut slot events, voice state, and notch hover. Each step's line appears in the cursor prompt bubble and is spoken via TTS. Esc skips the tour (ignored during the drive step; if Clicky is busy answering, the first Esc only interrupts that work). The meeting, morning and Spotify notch cards are hidden while the tour runs.

**Companion Capabilities**: Every companion channel (typed chat, push-to-talk voice, realtime voice) learns its abilities from one place, `Companion/ClickyCompanionCapabilities.swift`, which joins `ClickyDrawingPromptReference` (the full JS drawing language; the drawing canvas uses the cursor screen's screenshot pixels, so model coordinates map 1:1) and `ClickyHandoffPromptReference`. Text and voice replies hand work off with `[AGENT:<slug|none>:<task>]` (background job) or `[DRIVE:<step>]` (Clicky drives the Mac); tags are stripped before display/TTS. Jobs start after a notch "Start a background job?" card unless Settings → Agents → "Ask before starting jobs" is off, and even then only when the user's own words asked for work (drawing buttons always ask). Drive always shows the consent card and runs `ComputerUse/ClickyDriveStepExecutor.swift` (screenshot → one JSON action → ClickyAppDriver; 25 actions / 3 min, stops if another app comes to the front, never types into password fields, blocks quit/delete/Spotlight combos). Realtime voice has no tags: it calls the tools `use_screen` (runs the push-to-talk screen pipeline) and `start_background_job`. The voice and text base prompts live in `Companion/ClickyCompanionSystemPrompts.swift` (short spoken sentences, `[POINT]` only when pointing helps); background jobs get `Companion/ClickyJobInstructions.swift` (approval/confirmation rules plus the `<SUMMARY>`/`<ANSWER>`/`<ARTIFACTS>`/`<NEXT_ACTIONS>`/`<LEARNED>` final-message tags read by `AgentCompletionXMLParser`; the chat shows the prose outside the tags). These are our own wording: the bundled `ClickyModelInstructions.md` is HeyClicky's file and is not loaded.

**Notch Island**: Each display gets one fixed, transparent notch panel sized by `NotchScreenGeometry.canvasRect` (largest panel `NotchPanelMetrics.maximumExpandedSize` + shadow margins); the window never resizes. `NotchRootView` draws ONE black shape that morphs (single spring) between resting pill, activity pill and expanded panel, and the pill is always black (never the cursor color). Mouse pass-through uses `NotchScreenGeometry.interactiveRect`, so the transparent canvas clicks through to the menu bar. After a collapse the pointer must leave the pill before hover reopens it.

**Settings Layout**: Settings mirrors HeyClicky 1.1.5: a grouped sidebar (General, Language · HEYCLICKY: Voice, Microphone, Dictation, Shortcuts, Cursor · WORK: Integrations, Agents · ADVANCED: Connection & AI, Browser & Security, Routines, Skills, Memory) with a version footer, then a page title + subtitle and uppercase section headers above rounded cards (`Settings/ClickySettingsChrome.swift`). `HomeSpaceSettingsSection.sidebarGroups` is the single source of the order. No Account, Billing, Upgrade or Invite pages. Like 1.1.5, Home, Chat and Settings open inside the notch panel (top bar: Home/Chat icon capsule + gear; Home/Chat 516×400, Settings 800×648 hosting `HomeSpaceSettingsPage`). Settings controls use `ClickySettingsPalette`, `ClickyGlossyToggleStyle` and `ClickyGlossyPillButtonStyle` from `ClickySettingsChrome.swift`.

**Job Announcements**: Settings → Agents → Announcements. `Clickys/ClickyJobAnnouncementPolicy.swift` turns `ClickyJobStore.jobs` snapshots into started / finished / needs-you events (failed and stopped stay silent; the first snapshot after launch is silent). `CompanionManager` speaks them unprompted (quiet during calls), queues them while Clicky is mid-conversation, and shows finished/needs-you summaries in the cursor bubble for 6 s. Defaults keys match HeyClicky: `ClickyAgentVoiceAnnouncementsEnabled`, `ClickyAgentCursorTextAnnouncementsEnabled`.

**Permissions & Entitlements**: Calendar access (`NSCalendarsFullAccessUsageDescription` in Info.plist + `com.apple.security.personal-information.calendars`) powers the meeting countdown. Apple Events (`NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events`) powers agent-driven app control such as Spotify.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~333 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`, plus the morning suggestion, upcoming meeting, and Spotify tip monitors. No main window — the app lives entirely in the status bar. |
| `Onboarding/ClickyOnboardingTour.swift` | ~321 | Interactive first-run tour (talk → point → text mode → dictation → drive → notch → done) replacing the old onboarding video. Pure step machine plus `ClickyOnboardingTourController`, driven by shortcut slot events, voice state, and notch hover. Step lines show in the cursor prompt bubble and are spoken via TTS. Esc skips. |
| `CompanionManager.swift` | ~2440 | Central state machine. Owns `onboardingTourController`, dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. No email capture and no onboarding video. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~847 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, a Start button right after permissions (no email), a "Replay Tour" footer button, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~849 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. No video player; the cursor bubble carries the onboarding tour step lines. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~480 | PostHog analytics integration for usage tracking. Includes onboarding tour step, completed, and skipped events. |
| `ScreenDrawing/ClickyDrawingVideoRecorder.swift` | ~220 | "Save as Video" for drawings. Records via `SCStream` and writes H.264 with `AVAssetWriter` into `~/Downloads`. |
| `Companion/ClickyCompanionCapabilities.swift` | ~32 | Shared "what you can do" prompt sections per channel (text / voice / realtime). |
| `Companion/ClickyCompanionSystemPrompts.swift` | ~56 | Voice (push-to-talk) and typed-text base system prompts plus the `[POINT]` pointing rules. |
| `Companion/ClickyJobInstructions.swift` | ~53 | Background job rules and the final-message tag contract prepended to every job's instructions. |
| `Clickys/ClickyJobAnnouncementPolicy.swift` | ~100 | Pure policy for job start/finish/needs-you announcements (spoken line and cursor bubble text). |
| `Notch/ClickyChatComposerBar.swift` | ~160 | Shared chat composer for the notch and the window: hold-to-talk mic, + attach, "Ask HeyClicky…" field, background-job bolt, read-aloud speaker toggle, send/stop, expand to window. |
| `Settings/ClickySettingsChrome.swift` | ~125 | Settings page header, section card (header above the card), toggle row, status badge, app name/version for the sidebar footer. |
| `Settings/ClickyAgentsSettingsView.swift` | ~90 | Settings → Agents: agent folder, autonomy toggles, announcements, what agents can reach. |
| `Settings/ClickyMacPermissionsCard.swift` | ~158 | macOS permission rows (shown on the Agents page as "What agents can reach"). |
| `Companion/ClickyDrawingPromptReference.swift` | ~74 | Teaches the model the drawing language (shapes, ring/point/highlight, cards, photos, 3D, graphs, buttons, guided clicks) in screenshot-pixel coordinates. |
| `Companion/ClickyCompanionHandoff.swift` | ~272 | `[AGENT]`/`[DRIVE]` tag parser, handoff policy (ask vs auto), confirmation flow and activity ledger lines. |
| `ComputerUse/ClickyDriveStepExecutor.swift` | ~418 | Drive mode vision loop with safety limits; installed as `ClickyTakeOverController.stepExecutor` at app start. |
| `ScreenDrawing/ScreenDrawingClearPolicy.swift` | ~20 | Pure rule for when an app/Space change may wipe a drawing (never while streaming, during a voice turn, or within 4 s of finishing). |
| `ScreenDrawing/ClickyRecentDrawings.swift` | ~136 | Home → Drawings library: every finished drawing's full JS program (JSON in Application Support, max 30) plus `ClickyDrawingPlayer` replay (full screen, window, white board). Chat messages link to it via `ClickyChatMessage.drawingID`. |
| `ScreenDrawing/ClickyDrawingWindowViewer.swift` | ~143 | Replays a stored drawing inside its own resizable window with a separate engine instance. Space pauses. |
| `ScreenDrawing/ClickyDrawingWhiteboardPanel.swift` | ~96 | Opaque white board panel behind a full-screen replay. Esc closes, Space pauses. |
| `ScreenDrawing/ClickyDrawingSaveOfferView.swift` | ~192 | Save-offer panel after a drawing finishes, with the recording indicator ("Recording m:ss / m:ss", "Saving the video…", "Show the video in Finder"). |
| `HomeSpace/HomeSuggestionsAndDrawingsSections.swift` | ~233 | Home sections: suggestions with paging, reason, Yes / No thanks (decline reasons feed the next generation), and the Drawings list. |
| `Skills/ClickySkillStore.swift` | ~455 | Local skills: one Markdown file per skill in Application Support, max 3 active, injected into voice/text/agent prompts (escaped, size-capped). Agent-created skills arrive as unreviewed drafts and must be opened before activation. |
| `Skills/ClickySkillsSettingsView.swift` | ~307 | Settings → Skills: create (background agent job), import .md, edit, remove, activate. |
| `ScreenCapture/ClickyRegionCapture.swift` | ~334 | Region capture: drag a box, then Send with text / Send with voice / Don't send yet. Queued regions (max 4, 10-min TTL) ride along with the next question. Triggered from the menu bar or the optional `regionCapture` shortcut. |
| `ScreenCapture/ClickyRegionOverlayWindow.swift` | ~230 | Per-screen drag overlay and action bar for region capture. |
| `HomeSpace/ClickyMorningSuggestions.swift` | ~113 | Once-a-day morning greeting plus 3 LLM-generated agent task suggestions, shown as a notch card. Gated by the "Suggest agent tasks" toggle. |
| `Notch/ClickyUpcomingMeetingMonitor.swift` | ~118 | EventKit monitor. Shows a notch countdown and Join button 5 minutes before a calendar event. Gated by the "Upcoming meetings" toggle (off by default). |
| `Notch/ClickySpotifyTipMonitor.swift` | ~45 | One-time notch tip when Spotify is first activated. "Try it" starts an agent job. |
| `Audio/ClickyMicrophoneSelection.swift` | ~230 | Settings → Microphone selection. Enumerates CoreAudio input devices and pins every capture engine (dictation, wake word, realtime, mic test) to the chosen mic via `kAudioOutputUnitProperty_CurrentDevice`. Default (never chosen) is the built-in mic so Bluetooth headsets stay out of the HFP call profile. Also `ClickyMicrophoneTestController`. |
| `Settings/ClickyMicrophoneSettingsView.swift` | ~125 | Settings → Microphone page: System Default + device radio list and Test microphone level bars. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

**Unit tests**: The test target is `leanring-buddyTests` (Swift Testing, `@testable import Clicky`). Run it with Cmd+U in Xcode, never `xcodebuild` from the terminal. The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` but the test target does not, so test structs that call app code must be `@MainActor` or call `nonisolated` helpers.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

### Localization

- New UI strings must be localizable: SwiftUI `Text("...")` literals are `LocalizedStringKey` automatically; for `String` values use `String(localized:)`.
- Add the `id` (Indonesian) translation for every new string in `leanring-buddy/Localizable.xcstrings`. Only `en` and `id` are supported.
- The user picks the language in Settings > General > Language (`ClickyConfiguration.appLanguage`); it applies via the `AppleLanguages` override after relaunch.

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
