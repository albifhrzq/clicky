import SwiftUI

/// Shared composer used by the notch chat and the HeyClicky window:
/// hold-to-talk mic, a capsule text field with attach / background-job / read-aloud toggles, and send or stop.
struct ClickyChatComposerBar: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var clickyConfiguration = ClickyConfiguration.shared
    @Binding var draftText: String
    var placeholder: String = String(localized: "Ask HeyClicky…")
    @Binding var runAsBackgroundJob: Bool
    var showsBackgroundJobToggle: Bool = true
    var canSubmitWithoutText: Bool = false
    var isBusy: Bool = false
    var onAttach: (() -> Void)? = nil
    var onExpand: (() -> Void)? = nil
    let onStop: () -> Void
    let onSubmit: () -> Void
    var isInputFocused: FocusState<Bool>.Binding

    @State private var isMicPressed = false
    @State private var micHoldAutoReleaseTask: Task<Void, Never>?

    private var canSubmit: Bool {
        canSubmitWithoutText || !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isShowingStop: Bool {
        isBusy || companionManager.voiceState != .idle
    }

    private var isListening: Bool {
        companionManager.voiceState == .listening
    }

    /// Idle = nothing typed, field unfocused and not recording: the mic shows as a wide "Hold ⌃⌥ to talk" pill.
    private var isIdlePill: Bool {
        draftText.isEmpty && !isInputFocused.wrappedValue && !isListening && !isMicPressed
    }

    private var holdShortcutLabel: String {
        let displayText = companionManager.globalPushToTalkShortcutMonitor.binding(for: .voiceHold).displayText
        // Spelled out in words ("control + option") to match HeyClicky's pill copy.
        return ClickyComposerShortcutLabel.spelledOut(displayText)
    }

    var body: some View {
        HStack(spacing: 8) {
            holdToTalkMicButton
            fieldCapsule
            if let onExpand {
                ComposerExpandButton(help: String(localized: "Open in a window"), action: onExpand)
            }
        }
        .animation(.spring(duration: 0.25), value: isIdlePill)
    }

    // MARK: - Mic

    // One view for both states (pill and circle) so the hold gesture survives the collapse mid-press.
    private var holdToTalkMicButton: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
            if isIdlePill {
                Text("Hold \(holdShortcutLabel) to talk")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundColor(ComposerPalette.navy)
        // The idle pill hugs its text (padding instead of a fixed width) so longer shortcut
        // labels never clip; the collapsed state is a fixed circle.
        .padding(.horizontal, isIdlePill ? 18 : 0)
        .frame(width: isIdlePill ? nil : 42, height: isIdlePill ? 40 : 42)
        .background(ComposerGlossyShape())
        .scaleEffect(isListening ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: isListening)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    // Only the first change of a press starts the voice turn.
                    guard !isMicPressed else { return }
                    // Keyboard dictation already running ignores the press, so we must not claim
                    // the hold: our release would cut the user's keyboard push-to-talk.
                    guard !companionManager.buddyDictationManager.isDictationInProgress else { return }
                    isMicPressed = true
                    companionManager.handleExternalVoiceHold(isPressed: true)
                    micHoldAutoReleaseTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(ClickyNotchHoldToTalk.maximumHoldSeconds * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        releaseMicHoldIfActive()
                    }
                }
                .onEnded { _ in
                    releaseMicHoldIfActive()
                }
        )
        // The notch can collapse mid-press and tear this view down before onEnded fires.
        .onDisappear { releaseMicHoldIfActive() }
        .help(Text("Hold to talk"))
        .accessibilityLabel(Text("Hold to talk"))
        .pointerCursor()
    }

    /// Safe to call repeatedly: only releases a hold this view actually started.
    private func releaseMicHoldIfActive() {
        micHoldAutoReleaseTask?.cancel()
        micHoldAutoReleaseTask = nil
        guard isMicPressed else { return }
        isMicPressed = false
        companionManager.handleExternalVoiceHold(isPressed: false)
    }

    // MARK: - Field

    private var trailingButtonsVisibility: ClickyComposerTrailingButtons.Visibility {
        ClickyComposerTrailingButtons.visibility(
            isFocused: isInputFocused.wrappedValue,
            isDraftEmpty: draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isShowingStop: isShowingStop
        )
    }

    private var fieldCapsule: some View {
        let trailingButtonsVisibility = trailingButtonsVisibility
        return HStack(spacing: 6) {
            if let onAttach {
                ComposerIconButton(systemName: "plus", help: String(localized: "Attach files"), action: onAttach)
            }

            TextField(placeholder, text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .focused(isInputFocused)
                .onSubmit { if canSubmit && !isShowingStop { onSubmit() } }
                // Keeps the placeholder off the border when no trailing buttons are shown.
                .padding(.trailing, 9)

            if showsBackgroundJobToggle {
                ComposerIconButton(
                    systemName: runAsBackgroundJob ? "bolt.fill" : "bolt",
                    help: String(localized: "Run as a background job"),
                    isHighlighted: runAsBackgroundJob
                ) { runAsBackgroundJob.toggle() }
            }

            if trailingButtonsVisibility.showsReadAloudButton {
                ComposerIconButton(
                    systemName: clickyConfiguration.readsAnswersAloud ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    help: String(localized: "Read answers aloud"),
                    isHighlighted: clickyConfiguration.readsAnswersAloud
                ) { clickyConfiguration.readsAnswersAloud.toggle() }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if trailingButtonsVisibility.showsSendOrStopButton {
                sendOrStopButton
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.spring(duration: 0.25), value: trailingButtonsVisibility)
        .padding(.leading, 5)
        .padding(.trailing, 5)
        .frame(height: 40)
        .background(Capsule().fill(ComposerPalette.fieldFill))
        .overlay(Capsule().stroke(ComposerPalette.border, lineWidth: 1.2))
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [ComposerPalette.blueTop, ComposerPalette.blueBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
                .opacity(isInputFocused.wrappedValue ? 1 : 0)
        )
        .animation(.spring(duration: 0.25), value: isInputFocused.wrappedValue)
    }

    private var sendOrStopButton: some View {
        let isActive = isShowingStop || canSubmit
        return Button {
            if isShowingStop { onStop() } else { onSubmit() }
        } label: {
            Image(systemName: isShowingStop ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isActive ? ComposerPalette.navy : Color(hex: "#9aa0ad"))
                .frame(width: 30, height: 30)
                .background(
                    Group {
                        if isActive {
                            ComposerGlossyShape()
                        } else {
                            Circle().fill(Color(hex: "#4a4f5c"))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .pointerCursor(isEnabled: isActive)
    }
}

/// Colors taken from the official HeyClicky 1.1.5 composer.
private enum ComposerPalette {
    static let blueTop = Color(hex: "#b4ccff")
    static let blueBottom = Color(hex: "#7f9ff2")
    static let navy = Color(hex: "#0d1b3d")
    static let fieldFill = Color.white.opacity(0.03)
    static let rimTop = Color(hex: "#5b7be8")
    static let rimBottom = Color(hex: "#3f5fd0")
    static let border = Color(hex: "#3a3a3c")
    static let circleFill = Color(hex: "#333333")
}

/// Glossy light-blue fill with a white top highlight, as a capsule (pill) or circle.
private struct ComposerGlossyShape: View {
    var body: some View {
        ZStack(alignment: .top) {
            Capsule().fill(
                LinearGradient(
                    colors: [ComposerPalette.blueTop, ComposerPalette.blueBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            Capsule()
                .fill(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0)], startPoint: .top, endPoint: .bottom)
                )
                .frame(height: 16)
                .padding(.horizontal, 6)
                .padding(.top, 2)
        }
        // A capsule with equal sides is a circle, so one shape covers both states.
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(
                LinearGradient(colors: [ComposerPalette.rimTop, ComposerPalette.rimBottom], startPoint: .top, endPoint: .bottom),
                lineWidth: 1.2
            )
        )
    }
}

private struct ComposerExpandButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(hex: "#1c1c1c")))
                .overlay(Circle().stroke(ComposerPalette.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .pointerCursor()
    }
}

/// Small bottom-left tail for the last assistant bubble.
struct ChatBubbleTail: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 10, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: 9), control: CGPoint(x: 8, y: 7))
            path.addQuadCurve(to: CGPoint(x: 14, y: 4), control: CGPoint(x: 6, y: 10))
            path.closeSubpath()
        }
        .fill(Color(hex: "#3a3a3c"))
        .frame(width: 14, height: 10)
    }
}

/// Subtle dot grid behind chat messages.
struct ChatDotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let dotSpacing: CGFloat = 16
            var originY: CGFloat = dotSpacing / 2
            while originY < size.height {
                var originX: CGFloat = dotSpacing / 2
                while originX < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: originX - 0.75, y: originY - 0.75, width: 1.5, height: 1.5)),
                        with: .color(.white.opacity(0.04))
                    )
                    originX += dotSpacing
                }
                originY += dotSpacing
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ComposerIconButton: View {
    let systemName: String
    let help: String
    var isHighlighted: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(
                    isHighlighted ? DS.Colors.accentText : (isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                )
                .frame(width: 30, height: 30)
                .background(Circle().fill(ComposerPalette.circleFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .pointerCursor()
    }
}

// MARK: - Pure Composer Helpers

/// Turns the push-to-talk shortcut ("⌃⌥", "ctrl + option") into words for the composer pill:
/// "Hold control + option to talk", as in HeyClicky.
nonisolated enum ClickyComposerShortcutLabel {
    static let defaultSpelledOutShortcut = "control + option"

    private static let modifierSymbolWords: [Character: String] = [
        "⌃": "control", "⌥": "option", "⌘": "command", "⇧": "shift"
    ]

    private static let modifierAliasWords: [String: String] = [
        "ctrl": "control", "control": "control",
        "opt": "option", "option": "option", "alt": "option",
        "cmd": "command", "command": "command",
        "shift": "shift", "fn": "fn"
    ]

    static func spelledOut(_ shortcutDisplayText: String) -> String {
        let trimmedShortcutText = shortcutDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShortcutText.isEmpty else { return defaultSpelledOutShortcut }

        var shortcutTokens: [String] = []
        var currentTokenText = ""

        func flushCurrentToken() {
            let trimmedToken = currentTokenText.trimmingCharacters(in: .whitespaces)
            if !trimmedToken.isEmpty {
                shortcutTokens.append(modifierAliasWords[trimmedToken.lowercased()] ?? trimmedToken)
            }
            currentTokenText = ""
        }

        for shortcutCharacter in trimmedShortcutText {
            if let modifierWord = modifierSymbolWords[shortcutCharacter] {
                flushCurrentToken()
                shortcutTokens.append(modifierWord)
            } else if shortcutCharacter == "+" {
                flushCurrentToken()
            } else {
                currentTokenText.append(shortcutCharacter)
            }
        }
        flushCurrentToken()

        return shortcutTokens.joined(separator: " + ")
    }
}

nonisolated enum ClickyComposerTrailingButtons {
    struct Visibility: Equatable {
        let showsSendOrStopButton: Bool
        let showsReadAloudButton: Bool
    }

    /// The idle field stays empty like HeyClicky; buttons appear only when they can be used.
    static func visibility(isFocused: Bool, isDraftEmpty: Bool, isShowingStop: Bool) -> Visibility {
        Visibility(
            showsSendOrStopButton: !isDraftEmpty || isShowingStop,
            showsReadAloudButton: isFocused || !isDraftEmpty
        )
    }
}
