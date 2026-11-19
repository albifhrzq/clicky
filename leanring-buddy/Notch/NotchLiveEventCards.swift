//
//  NotchLiveEventCards.swift
//  leanring-buddy
//
//  Live event cards rendered inside the expanded Notch peek surface for:
//  - v1.1.3 browser upload approval (`ClickyUploadApprovalCard`)
//  - mac_step computer-use consent (`ClickyTakeOverConsentCard`)
//  - TCC Files & Folders recovery (`DocumentAccessNoticeCard`)
//  - Sparkle idle-install update prompt (`NotchAppUpdatedCard`)
//

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Upload Approval Card (v1.1.3)

public struct ClickyUploadApprovalCard: View {
    public let request: UploadApprovalRequest
    public let onDecision: (UploadApprovalDecision) -> Void

    public init(
        request: UploadApprovalRequest,
        onDecision: @escaping (UploadApprovalDecision) -> Void
    ) {
        self.request = request
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(
                    systemName: "arrow.up.doc.fill",
                    tint: DS.Colors.warning
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow file upload?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("\(request.jobTitle) wants to upload to \(request.site)")
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if !request.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(request.files.prefix(3).enumerated()), id: \.offset) { _, filePath in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.accentText)

                            Text(displayFileName(for: filePath))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)

                            Text(abbreviatedParentPath(for: filePath))
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }

                    if request.files.count > 3 {
                        Text("+ \(request.files.count - 3) more file(s)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.leading, 16)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.Colors.surface1.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.8)
                )
            }

            HStack(spacing: 6) {
                Button("Approve this time") {
                    onDecision(.approveOnce)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .primary))
                .pointerCursor()

                Button("Always approve") {
                    onDecision(.alwaysApprove)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))
                .pointerCursor()

                Spacer(minLength: 0)

                Button("Not now") {
                    onDecision(.decline)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .destructive))
                .pointerCursor()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DS.Colors.surface2.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private func displayFileName(for rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") else { return trimmed }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private func abbreviatedParentPath(for rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") else { return "" }
        let parent = URL(fileURLWithPath: trimmed).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if parent.hasPrefix(home) {
            return "~" + String(parent.dropFirst(home.count))
        }
        return parent
    }
}

// MARK: - Computer-Use TakeOver Consent Card

public struct ClickyTakeOverConsentCard: View {
    public let request: TakeOverConsentRequest
    public let onDecision: (Bool) -> Void

    public init(
        request: TakeOverConsentRequest,
        onDecision: @escaping (Bool) -> Void
    ) {
        self.request = request
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(
                    systemName: "cursorarrow.click.2",
                    tint: DS.Colors.accentText
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Let Clicky drive")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("I need a yes to use your Mac")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Clicky can do this step on your screen while you watch.")
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("One step on your Mac: \(request.step)")
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(3)
                        .padding(.top, 1)

                    if let reason = request.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(reason)
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Hands off the mouse while I drive. Esc stops me.")
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            HStack(spacing: 8) {
                Button("Allow Screen Control") {
                    onDecision(true)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .primary))

                Button("Not Now") {
                    onDecision(false)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DS.Colors.surface2.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DS.Colors.accent.opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Handoff Confirmation Card

struct ClickyHandoffConfirmCard: View {
    let request: ClickyHandoffRequest
    let onDecision: (Bool) -> Void

    init(request: ClickyHandoffRequest, onDecision: @escaping (Bool) -> Void) {
        self.request = request
        self.onDecision = onDecision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(systemName: "sparkles", tint: DS.Colors.accentText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a background job?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(request.task)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Start job") { onDecision(true) }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .primary))

                Button("Not now") { onDecision(false) }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DS.Colors.surface2.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DS.Colors.accent.opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Document Access Notice Card (TCC Recovery)

public struct DocumentAccessNoticeCard: View {
    public let notice: DocumentAccessNotice
    public let onOpenSettings: () -> Void
    public let onDismiss: () -> Void

    public init(
        notice: DocumentAccessNotice,
        onOpenSettings: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.notice = notice
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(
                    systemName: "folder.badge.questionmark",
                    tint: DS.Colors.warning
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(notice.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)

                    HStack(spacing: 6) {
                        Text(notice.folderName)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DS.Colors.warningText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.warning.opacity(0.14))
                            )

                        Text(URL(fileURLWithPath: notice.deniedFilePath).lastPathComponent)
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Open Privacy Settings") {
                    onOpenSettings()
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .primary))

                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))

                if notice.showsDontShowAgain {
                    Button("Don't ask again") {
                        ActiveDocumentReader.shared.dismissAccessNotice(dontShowAgain: true)
                        onDismiss()
                    }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .ghost))
                }

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DS.Colors.surface2.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - App Updated Card (IdleUpdateInstallPolicy / Sparkle)

public struct NotchAppUpdatedCard: View {
    public let version: String
    public let onRestart: () -> Void
    public let onDismiss: (() -> Void)?

    public init(
        version: String,
        onRestart: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.version = version
        self.onRestart = onRestart
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(
                    systemName: "arrow.triangle.2.circlepath.circle.fill",
                    tint: DS.Colors.success
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Clicky \(version) is ready")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    let idleMinutes = max(1, Int(IdleUpdateInstallPolicy.defaultRequiredIdleSeconds / 60))
                    Text("Auto-installs after \(idleMinutes)m idle, or restart now to update.")
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Install Update & Relaunch") {
                    onRestart()
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .primary))

                if let onDismiss {
                    Button("Later") {
                        onDismiss()
                    }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))
                }

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DS.Colors.surface2.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DS.Colors.success.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Morning Suggestions Card

struct NotchMorningSuggestionsContent: Equatable {
    let greeting: String
    let suggestions: [ClickySuggestion]
}

/// Pure countdown state for cards that dismiss themselves (kept free of timers so it is testable).
nonisolated struct NotchAutoDismissCountdown: Equatable {
    static let defaultDurationSeconds: TimeInterval = 20

    let totalSeconds: TimeInterval
    private(set) var remainingSeconds: TimeInterval

    init(totalSeconds: TimeInterval = NotchAutoDismissCountdown.defaultDurationSeconds) {
        self.totalSeconds = max(totalSeconds, 0.1)
        self.remainingSeconds = max(totalSeconds, 0.1)
    }

    var isExpired: Bool { remainingSeconds <= 0 }

    var fractionRemaining: Double { max(0, min(1, remainingSeconds / totalSeconds)) }

    /// Time only passes while the card is not paused (hover or the pause button).
    func advanced(by elapsedSeconds: TimeInterval, isPaused: Bool) -> NotchAutoDismissCountdown {
        guard !isPaused, !isExpired else { return self }
        var advancedCountdown = self
        advancedCountdown.remainingSeconds = max(0, remainingSeconds - elapsedSeconds)
        return advancedCountdown
    }
}

/// Wrap-around paging for the one-suggestion-at-a-time carousel.
nonisolated enum NotchSuggestionPaging {
    static func index(from currentIndex: Int, offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((currentIndex + offset) % count + count) % count
    }
}

struct NotchMorningSuggestionsCard: View {
    private static let countdownTickSeconds: TimeInterval = 0.1

    let content: NotchMorningSuggestionsContent
    let onSelectSuggestion: (String) -> Void
    let onDismiss: () -> Void

    @State private var selectedSuggestionIndex = 0
    @State private var autoDismissCountdown = NotchAutoDismissCountdown()
    @State private var isCardHovered = false
    @State private var isPausedByUser = false
    @State private var hasDismissed = false
    @State private var suggestionPendingConfirmation: ClickySuggestion?

    private let countdownTicker = Timer.publish(
        every: NotchMorningSuggestionsCard.countdownTickSeconds,
        on: .main,
        in: .common
    ).autoconnect()

    private var suggestions: [ClickySuggestion] { content.suggestions }

    private var visibleSuggestion: ClickySuggestion? {
        guard !suggestions.isEmpty else { return nil }
        return suggestions[min(selectedSuggestionIndex, suggestions.count - 1)]
    }

    private var countLine: String {
        suggestions.count == 1
            ? String(localized: "I can do 1 thing for you today")
            : String(localized: "I can do \(suggestions.count) things for you today")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(systemName: "sun.max.fill", tint: DS.Colors.warning)

                Text(content.greeting)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                countdownControl
            }

            Text(countLine)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)

            if let visibleSuggestion {
                suggestionPager(for: visibleSuggestion)
            }

            if let pendingSuggestion = suggestionPendingConfirmation, pendingSuggestion.id == visibleSuggestion?.id {
                HStack(spacing: 8) {
                    Button("Yes, do it") {
                        suggestionPendingConfirmation = nil
                        onSelectSuggestion(pendingSuggestion.title)
                    }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .primary))
                    .pointerCursor()

                    Button("Back") { suggestionPendingConfirmation = nil }
                        .buttonStyle(NotchCardActionButtonStyle(variant: .ghost))
                        .pointerCursor()

                    Spacer(minLength: 0)
                }
            }

            HStack {
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .ghost))
                    .help("Closes this card. Today's ideas stay in Suggestions.")

                Button("Don't show again") {
                    ClickyConfiguration.shared.suggestAgentTasks = false
                    onDismiss()
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .ghost))

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface2.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.warning.opacity(0.35), lineWidth: 1))
        .onHover { isHovering in isCardHovered = isHovering }
        .onReceive(countdownTicker) { _ in
            advanceCountdown()
        }
    }

    private func advanceCountdown() {
        guard !hasDismissed else { return }
        autoDismissCountdown = autoDismissCountdown.advanced(
            by: Self.countdownTickSeconds,
            isPaused: isCardHovered || isPausedByUser
        )
        if autoDismissCountdown.isExpired {
            hasDismissed = true
            onDismiss()
        }
    }

    /// Ring that drains as the card nears auto-dismiss; clicking it pauses/resumes the countdown.
    private var countdownControl: some View {
        Button {
            isPausedByUser.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(DS.Colors.borderSubtle, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: autoDismissCountdown.fractionRemaining)
                    .stroke(DS.Colors.warning, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: isPausedByUser ? "play.fill" : "pause.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Pause auto-dismiss")
        .accessibilityLabel(Text("Pause auto-dismiss"))
        .accessibilityValue(Text("Auto-dismiss countdown"))
    }

    private func suggestionPager(for suggestion: ClickySuggestion) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if suggestions.count > 1 {
                pagerArrowButton(systemName: "chevron.left", offset: -1, label: "Previous suggestion")
            }

            Button {
                // Never start a job on the first tap; ask for an explicit confirmation first.
                suggestionPendingConfirmation = suggestion
                isPausedByUser = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let reason = suggestion.reason,
                       !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(reason)
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.surface1))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(Text("Choose suggestion: \(suggestion.title)"))

            if suggestions.count > 1 {
                pagerArrowButton(systemName: "chevron.right", offset: 1, label: "Next suggestion")
            }
        }
    }

    private func pagerArrowButton(systemName: String, offset: Int, label: LocalizedStringKey) -> some View {
        Button {
            selectedSuggestionIndex = NotchSuggestionPaging.index(
                from: selectedSuggestionIndex,
                offset: offset,
                count: suggestions.count
            )
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Upcoming Meeting Card

struct NotchUpcomingMeetingContent: Equatable {
    let title: String
    let startDate: Date
    let joinURL: URL?
}

struct NotchUpcomingMeetingCard: View {
    let content: NotchUpcomingMeetingContent
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(systemName: "calendar", tint: DS.Colors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting starting soon: \(content.title)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    // TimelineView re-renders every second so the countdown stays live without a timer.
                    TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
                        Text(Self.countdownText(until: content.startDate, now: timelineContext.date))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let joinURL = content.joinURL, joinURL.scheme?.lowercased() == "https" {
                    Button("Join") {
                        NSWorkspace.shared.open(joinURL)
                    }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .primary))
                }

                Button("Dismiss") { onDismiss() }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface2.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.accent.opacity(0.35), lineWidth: 1))
    }

    static func countdownText(until startDate: Date, now: Date) -> String {
        let remainingSeconds = Int(startDate.timeIntervalSince(now).rounded(.up))
        guard remainingSeconds > 0 else { return "started" }
        return String(format: "starts in %d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }
}

// MARK: - Spotify Tip Card

struct NotchSpotifyTipCard: View {
    let onTryIt: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotchCardIconBadge(systemName: "music.note", tint: DS.Colors.success)

                VStack(alignment: .leading, spacing: 2) {
                    Text("I can play songs on Spotify")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Try saying \"Play Good Morning by Kanye West on Spotify\"")
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Try it") { onTryIt() }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .primary))
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface2.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.success.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Clipboard Fallback Card (Mac sound is off)

struct NotchClipboardFallbackCard: View {
    let onDismiss: () -> Void

    /// Copies the reply to the pasteboard. Call site (CompanionManager) calls this when the output is muted.
    static func copyReplyToClipboard(_ replyText: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(replyText, forType: .string)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NotchCardIconBadge(systemName: "speaker.slash.fill", tint: DS.Colors.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your sound is off. The reply was copied to your clipboard")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The answer is on your clipboard. Press ⌘V to paste")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer(minLength: 0)

            Button("Dismiss") { onDismiss() }
                .buttonStyle(NotchCardActionButtonStyle(variant: .ghost))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.surface2.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.warning.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Shared Card Building Blocks

private struct NotchCardIconBadge: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.16))
                .frame(width: 28, height: 28)

            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
        }
    }
}

private struct NotchCardActionButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case destructive
        case ghost
    }

    let variant: Variant
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(foregroundColor(isPressed: configuration.isPressed))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 0.8)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return DS.Colors.textOnAccent
        case .secondary:
            return DS.Colors.textPrimary
        case .destructive:
            return (isHovered || isPressed) ? .white : DS.Colors.destructiveText
        case .ghost:
            return isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            if isPressed { return DS.Colors.accentHover.blendedWithWhite(fraction: 0.1) }
            return isHovered ? DS.Colors.accentHover : DS.Colors.accent
        case .secondary:
            if isPressed { return DS.Colors.surface4 }
            return isHovered ? DS.Colors.surface3 : DS.Colors.surface1
        case .destructive:
            if isPressed { return DS.Colors.destructive.opacity(0.42) }
            return isHovered ? DS.Colors.destructive.opacity(0.30) : DS.Colors.destructive.opacity(0.12)
        case .ghost:
            return isHovered ? DS.Colors.surface3.opacity(0.7) : Color.clear
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary:
            return Color.clear
        case .secondary:
            return isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle
        case .destructive:
            return DS.Colors.destructive.opacity(0.30)
        case .ghost:
            return Color.clear
        }
    }
}
