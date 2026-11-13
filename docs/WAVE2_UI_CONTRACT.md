# Wave 2 Shared UI & Wiring Contract

Always read `/root/Developer/clicky/AGENTS.md`, `/root/Developer/clicky/docs/LANE_CONTRACT.md`, and `/root/Developer/clicky/docs/WAVE1_PUBLIC_API.txt` first!

## Cross-Lane UI Signatures (Wave 2)
1. **DesignSystem.swift (Lane G):**
   - Keeps all existing `DS.Colors.*`, `DS.Spacing.*`, `DS.CornerRadius.*`, `DS.Animation.*`, `DS.StateLayer.*`, `DSPrimaryButtonStyle`, `DSSecondaryButtonStyle`, `DSTertiaryButtonStyle`, `DSTextButtonStyle`, `DSOutlinedButtonStyle`, `DSDestructiveButtonStyle`, `DSIconButtonStyle`, `BuddyComposerVisualStyle`, `Color(hex:)`, and `.pointerOnHover()` / `PointerCursorView`.
   - Adds `DS.Colors.cursorColor(named: String) -> Color` (`"red"`, `"blue"`, `"yellow"`, `"green"`).
   - Adds `ClickyPanelBackground: View` (`init(cornerRadius: CGFloat = 14, usesTranslucentMaterial: Bool = true)`).
   - Adds `ClickyPanelStylePreference` (`@MainActor ObservableObject`, `shared`, `@Published var usesTransparentPanes: Bool`).

2. **Notch UI (Lane H):**
   - `NotchWindowManager.shared` (`@MainActor ObservableObject`):
     - `func start(companionManager: CompanionManager)`
     - `func showNotchPeek(tab: ClickyNotchTab = .home)`
     - `func collapseNotch()`
     - `@Published var activeTab: ClickyNotchTab` (`case home, chat, settings, document`)
   - `ClickyUploadApprovalCard(request: UploadApprovalRequest, onDecision: @escaping (UploadApprovalDecision) -> Void): View`
   - `ClickyTakeOverConsentCard(request: TakeOverConsentRequest, onDecision: @escaping (Bool) -> Void): View`
   - `DocumentAccessNoticeCard(notice: DocumentAccessNotice, onOpenSettings: @escaping () -> Void, onDismiss: @escaping () -> Void): View`

3. **Expandable Window (Lane I):**
   - `HeyClickyWindowController.shared` (`@MainActor ObservableObject`):
     - `func configure(companionManager: CompanionManager)`
     - `func open(selectedSlug: String? = nil, documentPath: String? = nil, initialTab: ClickyNotchTab = .chat)`
     - `func close()`

4. **Home Space, Arc Cards & ClickyInk (Lane J):**
   - `ClickyAgentIconView(agentKey: String, title: String = "", mood: ClickyAgentMood = .idle, prop: ClickyAgentProp = .sparkle, baseHue: Double = 0.58, size: CGFloat = 36): View`
   - `ClickyArcCard(job: ClickyJob, onStop: (() -> Void)? = nil, onOpen: (() -> Void)? = nil): View`
   - `ClickyInkSheetView(markdown: String, title: String? = nil, onAction: ((String) -> Void)? = nil): View`
   - `HomeSpaceView(companionManager: CompanionManager): View`

5. **Unified Settings (Lane K):**
   - `HomeSpaceSettingsPage(companionManager: CompanionManager, initialSection: HomeSpaceSettingsSection = .connection): View`
   - `enum HomeSpaceSettingsSection: String, CaseIterable, Identifiable { case connection, general, voice, dictation, shortcuts, cursor, browser, routines, memory }`
   - `CompanionPanelView(companionManager: CompanionManager): View` (must keep working inside `MenuBarPanelManager` too!)

6. **App & Manager Wiring (Lane L):**
   - `CompanionManager`:
     - Keeps all existing `@Published` properties and methods used by `CompanionPanelView` / `OverlayWindow` / `MenuBarPanelManager`.
     - Adds:
       - `@Published var activeDocumentContext: ActiveDocumentContext?`
       - `@Published var activeDocumentNotice: DocumentAccessNotice?`
       - `@Published var textInputDraft: String = ""`
       - `@Published var chatMessages: [ClickyChatMessage] = []` (with `id`, `role`, `text`, `timestamp`, `clickySlug`, `artifactPaths`)
       - `func submitTextPrompt(_ prompt: String, clickySlug: String? = nil)`
       - `func startBackgroundAgentTask(prompt: String, clickySlug: String? = nil)`
       - `func stopActiveAgentTask(jobID: String)`
       - `func refreshActiveDocumentContext() async`
       - `func sendOpenCodexOrBYOKTestPrompt()` (or `submitTextPrompt`)
