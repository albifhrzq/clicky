//
//  NotchSurfaces.swift
//  leanring-buddy
//
//  SwiftUI surfaces hosted inside NotchWindowManager's multi-display NSPanels:
//  - NotchRootView: switches between collapsed pill, live activity pill, and expanded peek
//  - NotchRestingMarkSurface: compact notch pill with brand mark, pulsing indicator, unread gel badge
//  - NotchActivitySurface: live voice / dictation / realtime / agent progress pill
//  - NotchHeyClickyPeekSurface: tabbed peek (Home | Chat | Settings | Document) + live event cards
//  - NotchTextInputSurface & NotchTextResponseSurface: streaming markdown, copy, artifact chips, follow-up composer
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Expanded Size PreferenceKey

private struct NotchExpandedSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = CGSize(width: 440, height: 390)

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 {
            value = next
        }
    }
}

// MARK: - Root Surface

struct NotchRootView: View {
    let displayID: CGDirectDisplayID
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject var companionManager: CompanionManager

    @ObservedObject private var uploadApproval = ClickyUploadApproval.shared
    @ObservedObject private var takeOverController = ClickyTakeOverController.shared
    @ObservedObject private var documentReader = ActiveDocumentReader.shared
    @ObservedObject private var realtimeVoice = RealtimeVoiceController.shared
    @ObservedObject private var dictationManager: BuddyDictationManager
    @ObservedObject private var jobStore = ClickyJobStore.shared
    @ObservedObject private var roster = ClickyRoster.shared
    @ObservedObject private var config = ClickyConfiguration.shared
    @ObservedObject private var panelStyle = ClickyPanelStylePreference.shared
    @ObservedObject private var shortcutMonitor: GlobalPushToTalkShortcutMonitor

    /// Press-and-hold on the collapsed pill = hold-to-talk.
    @State private var holdStartTask: Task<Void, Never>?
    @State private var isHoldToTalkActive = false
    /// True once a press crossed the hold threshold; swallows the tap that mouse-up would otherwise fire.
    @State private var shouldSuppressNextTap = false
    @State private var holdAutoReleaseTask: Task<Void, Never>?

    init(
        displayID: CGDirectDisplayID,
        notchManager: NotchWindowManager = .shared,
        companionManager: CompanionManager
    ) {
        self.displayID = displayID
        self.notchManager = notchManager
        self.companionManager = companionManager
        self._dictationManager = ObservedObject(wrappedValue: companionManager.buddyDictationManager)
        self._shortcutMonitor = ObservedObject(wrappedValue: companionManager.globalPushToTalkShortcutMonitor)
    }

    private var holdToTalkHint: String {
        let shortcutLabel = ClickyNotchHoldToTalk.shortcutLabel(shortcutMonitor.binding(for: .voiceHold).displayText)
        return isHoldToTalkActive
            ? String(localized: "Hold \(shortcutLabel) to talk. Release to send.")
            : String(localized: "Hold \(shortcutLabel) to talk to Clicky")
    }

    /// Attached to the outer container (not the pill) because the pill is swapped for the activity
    /// surface as soon as listening starts, which would drop the gesture before release.
    private var holdToTalkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard holdStartTask == nil, !isHoldToTalkActive, !isThisScreenExpanded else { return }
                shouldSuppressNextTap = false
                // A hold must not also trigger the hover-expand.
                notchManager.cancelPendingHoverExpand()
                holdStartTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(ClickyNotchHoldToTalk.holdThresholdSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    shouldSuppressNextTap = true
                    // If keyboard dictation is already running the press is ignored, so we must not
                    // claim the hold (our release would cut the user's keyboard push-to-talk).
                    guard !dictationManager.isDictationInProgress else { return }
                    isHoldToTalkActive = true
                    companionManager.handleExternalVoiceHold(isPressed: true)
                    holdAutoReleaseTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(ClickyNotchHoldToTalk.maximumHoldSeconds * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        releaseHoldToTalkIfActive()
                    }
                }
            }
            .onEnded { _ in
                holdStartTask?.cancel()
                holdStartTask = nil
                releaseHoldToTalkIfActive()
            }
    }

    /// Safe to call repeatedly: only releases a hold this view actually started.
    private func releaseHoldToTalkIfActive() {
        holdAutoReleaseTask?.cancel()
        holdAutoReleaseTask = nil
        guard isHoldToTalkActive else { return }
        isHoldToTalkActive = false
        companionManager.handleExternalVoiceHold(isPressed: false)
    }

    private func handlePillTap() {
        if shouldSuppressNextTap {
            shouldSuppressNextTap = false
            return
        }
        notchManager.expandNotch(tab: notchManager.activeTab, on: displayID)
    }

    private var geometry: NotchScreenGeometry? {
        notchManager.geometry(for: displayID)
    }

    private var isThisScreenExpanded: Bool {
        notchManager.isExpanded && (notchManager.activeDisplayID == displayID || (notchManager.activeDisplayID == nil && displayID == notchManager.primaryDisplayID))
    }

    private var totalUnreadCount: Int {
        NotchUnreadCounter.totalUnreadCount(jobStore: jobStore, roster: roster)
    }

    // MARK: - Island Morph Layout

    /// One spring drives the whole pill -> panel morph (shape size, corner radii, shadow, fades).
    private static let morphSpring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// Expanded content fades in slightly after the black shape starts growing, so it never pokes out of it.
    private static let expandedContentRevealDelaySeconds: Double = 0.08
    private static let fallbackRestingHandleSize = CGSize(width: 60, height: 6)
    private static let fallbackRestingHandleHoveredSize = CGSize(width: 72, height: 8)
    private static let fallbackRestingHandleTopPadding: CGFloat = 4
    private static let hardwareRestingBottomCornerRadius: CGFloat = 12
    private static let hardwareActivityBottomCornerRadius: CGFloat = 14

    /// Everything the single persistent black shape needs, in canvas-local coordinates
    /// (SwiftUI y grows downward and the canvas top is the screen top, so the pill sits at y = 0).
    private struct NotchIslandLayout {
        let size: CGSize
        let canvasOrigin: CGPoint
        let cornerRadii: RectangleCornerRadii
        let shadowOpacity: Double
        let shadowRadius: CGFloat
        let shadowYOffset: CGFloat

        var shape: UnevenRoundedRectangle { UnevenRoundedRectangle(cornerRadii: cornerRadii) }

        /// Changes whenever the shape should animate to a new state.
        var animationKey: [CGFloat] {
            [size.width, size.height, canvasOrigin.x, canvasOrigin.y, cornerRadii.bottomLeading, cornerRadii.topLeading]
        }
    }

    private func canvasOrigin(of rect: CGRect, in geometry: NotchScreenGeometry) -> CGPoint {
        CGPoint(
            x: rect.minX - geometry.canvasRect.minX,
            y: geometry.screenFrame.maxY - rect.maxY
        )
    }

    private func bottomOnlyRadii(_ bottomRadius: CGFloat) -> RectangleCornerRadii {
        RectangleCornerRadii(topLeading: 0, bottomLeading: bottomRadius, bottomTrailing: bottomRadius, topTrailing: 0)
    }

    private func uniformRadii(_ radius: CGFloat) -> RectangleCornerRadii {
        RectangleCornerRadii(topLeading: radius, bottomLeading: radius, bottomTrailing: radius, topTrailing: radius)
    }

    private func islandLayout(for geometry: NotchScreenGeometry) -> NotchIslandLayout {
        if isThisScreenExpanded {
            let expandedRect = geometry.expandedPanelRect(for: notchManager.expandedContentSize)
            return NotchIslandLayout(
                size: expandedRect.size,
                canvasOrigin: canvasOrigin(of: expandedRect, in: geometry),
                cornerRadii: bottomOnlyRadii(NotchPanelMetrics.bottomCornerRadius),
                shadowOpacity: 0.45, shadowRadius: 22, shadowYOffset: 10
            )
        }

        if notchManager.isActivityPillVisible {
            let activityRect = geometry.activityPillRect
            return NotchIslandLayout(
                size: activityRect.size,
                canvasOrigin: canvasOrigin(of: activityRect, in: geometry),
                cornerRadii: geometry.hasHardwareNotch
                    ? bottomOnlyRadii(Self.hardwareActivityBottomCornerRadius)
                    : uniformRadii(activityRect.height / 2),
                shadowOpacity: geometry.hasHardwareNotch ? 0 : 0.4,
                shadowRadius: geometry.hasHardwareNotch ? 0 : 10,
                shadowYOffset: geometry.hasHardwareNotch ? 0 : 4
            )
        }

        let restingRect = geometry.restingPillRect
        if geometry.hasHardwareNotch {
            return NotchIslandLayout(
                size: restingRect.size,
                canvasOrigin: canvasOrigin(of: restingRect, in: geometry),
                cornerRadii: bottomOnlyRadii(Self.hardwareRestingBottomCornerRadius),
                shadowOpacity: 0, shadowRadius: 0, shadowYOffset: 0
            )
        }

        // Fallback display: the visible resting pill is only the small handle inside the (larger) hit area.
        let handleSize = notchManager.isPillHovered(on: displayID) ? Self.fallbackRestingHandleHoveredSize : Self.fallbackRestingHandleSize
        let handleTopLeft = CGPoint(
            x: restingRect.midX - (handleSize.width / 2) - geometry.canvasRect.minX,
            y: (geometry.screenFrame.maxY - restingRect.maxY) + Self.fallbackRestingHandleTopPadding
        )
        return NotchIslandLayout(
            size: handleSize,
            canvasOrigin: handleTopLeft,
            cornerRadii: uniformRadii(handleSize.height / 2),
            shadowOpacity: 0, shadowRadius: 0, shadowYOffset: 0
        )
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let geometry {
                islandCanvas(geometry: geometry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .simultaneousGesture(holdToTalkGesture)
        .onDisappear {
            holdStartTask?.cancel()
            holdStartTask = nil
            releaseHoldToTalkIfActive()
        }
        .help(isThisScreenExpanded ? "" : holdToTalkHint)
    }

    @ViewBuilder
    private func islandCanvas(geometry: NotchScreenGeometry) -> some View {
        let layout = islandLayout(for: geometry)

        // The ONE black shape: it is never swapped out, only resized/re-rounded, so the morph has no ghosting.
        layout.shape
            .fill(Color.black)
            .shadow(
                color: Color.black.opacity(layout.shadowOpacity),
                radius: layout.shadowRadius,
                x: 0,
                y: layout.shadowYOffset
            )
            .frame(width: layout.size.width, height: layout.size.height)
            .offset(x: layout.canvasOrigin.x, y: layout.canvasOrigin.y)
            .allowsHitTesting(false)
            .animation(Self.morphSpring, value: layout.animationKey)

        if isThisScreenExpanded {
            expandedLayer(geometry: geometry, layout: layout)
        } else {
            collapsedLayer(geometry: geometry)
        }
    }

    private func collapsedLayer(geometry: NotchScreenGeometry) -> some View {
        let pillRect = notchManager.isActivityPillVisible ? geometry.activityPillRect : geometry.restingPillRect
        let origin = canvasOrigin(of: pillRect, in: geometry)

        // Surfaces fill the whole hit rect (not just the visible handle) so hover/click keep working there.
        return Group {
            if notchManager.isActivityPillVisible {
                NotchActivitySurface(
                    geometry: geometry,
                    companionManager: companionManager,
                    realtimeVoice: realtimeVoice,
                    dictationManager: dictationManager,
                    jobStore: jobStore,
                    takeOverController: takeOverController,
                    unreadCount: totalUnreadCount,
                    onTap: { handlePillTap() }
                )
                .transition(.opacity)
            } else {
                NotchRestingMarkSurface(
                    geometry: geometry,
                    cursorColorName: config.cursorColorName,
                    hasWorkingAgent: !jobStore.activeJobs.isEmpty || takeOverController.phase == .driving,
                    unreadCount: totalUnreadCount,
                    isHovered: notchManager.isPillHovered(on: displayID),
                    onTap: { handlePillTap() }
                )
                .transition(.opacity)
            }
        }
        .frame(width: pillRect.width, height: pillRect.height)
        .offset(x: origin.x, y: origin.y)
        .onHover { hovering in
            notchManager.setHovered(hovering, on: displayID)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: notchManager.isActivityPillVisible)
    }

    private func expandedLayer(geometry: NotchScreenGeometry, layout: NotchIslandLayout) -> some View {
        let expandedRect = geometry.expandedPanelRect(for: notchManager.expandedContentSize)
        let revealTransition = AnyTransition.asymmetric(
            insertion: AnyTransition.opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
                .animation(.easeOut(duration: 0.2).delay(Self.expandedContentRevealDelaySeconds)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.1))
        )

        return expandedContent(contentWidth: expandedRect.width)
            // Content keeps its final size; the animated outer frame + clip reveal it as the shape grows.
            .frame(width: expandedRect.width, height: expandedRect.height, alignment: .top)
            .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
            .clipShape(layout.shape)
            .offset(x: layout.canvasOrigin.x, y: layout.canvasOrigin.y)
            .transition(revealTransition)
            .animation(Self.morphSpring, value: layout.animationKey)
    }

    private func expandedContent(contentWidth: CGFloat) -> some View {
        let topNotchGap: CGFloat = (geometry?.hasHardwareNotch == true) ? max(28, (geometry?.hardwareNotchRect.height ?? 32) - 2) : 8

        return VStack(spacing: 8) {
            if geometry?.hasHardwareNotch == true {
                Color.clear
                    .frame(height: topNotchGap)
            }

            // Live Event Cards stack (v1.1.3 upload approval, takeover consent, TCC notice, app update)
            if let uploadRequest = uploadApproval.pendingRequest {
                ClickyUploadApprovalCard(request: uploadRequest) { decision in
                    ClickyUploadApproval.shared.resolvePending(decision)
                }
            }

            if let consentRequest = takeOverController.pendingConsent {
                ClickyTakeOverConsentCard(request: consentRequest) { approved in
                    ClickyTakeOverController.shared.resolvePendingConsent(approved ? .approve : .decline)
                }
            }

            if let pendingHandoff = companionManager.pendingHandoffRequest {
                ClickyHandoffConfirmCard(request: pendingHandoff) { approved in
                    if approved {
                        companionManager.approvePendingHandoff()
                    } else {
                        companionManager.declinePendingHandoff()
                    }
                }
            }

            // New extra cards never show during the onboarding tour (it owns the user's attention).
            let isOnboardingTourRunning = companionManager.onboardingTourController.isActive

            if !isOnboardingTourRunning, let upcomingMeeting = notchManager.pendingUpcomingMeeting {
                NotchUpcomingMeetingCard(
                    content: upcomingMeeting,
                    onDismiss: { notchManager.dismissUpcomingMeetingCard() }
                )
            }

            if let docNotice = companionManager.activeDocumentNotice ?? documentReader.activeDocumentAccessNotice {
                DocumentAccessNoticeCard(
                    notice: docNotice,
                    onOpenSettings: {
                        documentReader.openFilesAndFoldersPrivacySettings()
                    },
                    onDismiss: {
                        documentReader.dismissAccessNotice()
                    }
                )
            }

            if let updatedVersion = notchManager.pendingAppUpdateVersion {
                NotchAppUpdatedCard(
                    version: updatedVersion,
                    onRestart: {
                        notchManager.triggerAppUpdateRestart()
                    },
                    onDismiss: {
                        notchManager.dismissAppUpdatedCard()
                    }
                )
            }

            // Morning suggestions win over the Spotify tip; at most one of the two is shown.
            if !isOnboardingTourRunning {
                if let morningSuggestions = notchManager.pendingMorningSuggestions {
                    NotchMorningSuggestionsCard(
                        content: morningSuggestions,
                        onSelectSuggestion: { suggestionPrompt in
                            companionManager.startBackgroundAgentTask(prompt: suggestionPrompt)
                            notchManager.dismissMorningSuggestionsCard()
                        },
                        onDismiss: { notchManager.dismissMorningSuggestionsCard() }
                    )
                } else if notchManager.pendingSpotifyTip {
                    NotchSpotifyTipCard(
                        onTryIt: {
                            companionManager.startBackgroundAgentTask(prompt: ClickySpotifyTipMonitor.tryItPrompt)
                            notchManager.dismissSpotifyTipCard()
                        },
                        onDismiss: { notchManager.dismissSpotifyTipCard() }
                    )
                }
            }

            NotchHeyClickyPeekSurface(
                notchManager: notchManager,
                companionManager: companionManager
            )
        }
        .padding(.top, geometry?.hasHardwareNotch == true ? 4 : 0)
        .frame(width: contentWidth)
        // Natural height, so the measurement below is the content's own height and not the proposed frame.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: NotchExpandedSizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(NotchExpandedSizePreferenceKey.self) { newSize in
            notchManager.updateExpandedContentSize(newSize, for: displayID)
        }
    }
}

// MARK: - Unread Counter Helper

private enum NotchUnreadCounter {
    @MainActor
    static func totalUnreadCount(jobStore: ClickyJobStore, roster: ClickyRoster) -> Int {
        var unreadSlugs = Set<String>()
        var unreadJobCount = 0

        for job in jobStore.visibleJobs {
            if !job.isSeen && job.outcome != .working {
                unreadJobCount += 1
                unreadSlugs.insert(job.clickySlug)
            }
        }

        var extraUnreadClickys = 0
        for profile in roster.clickys {
            guard !unreadSlugs.contains(profile.slug) else { continue }
            let latestJobDate = jobStore.jobs(forClickySlug: profile.slug)
                .compactMap { $0.finishedAt ?? $0.createdAt }
                .max()
            if roster.isUnread(slug: profile.slug, latestActivityAt: latestJobDate) {
                extraUnreadClickys += 1
            }
        }

        return unreadJobCount + extraUnreadClickys
    }
}

// MARK: - Resting Mark Surface (Collapsed Pill)

public struct NotchRestingMarkSurface: View {
    public let geometry: NotchScreenGeometry?
    public let cursorColorName: String
    public let hasWorkingAgent: Bool
    public let unreadCount: Int
    public let isHovered: Bool
    public let onTap: () -> Void

    @State private var isPulsing = false

    public init(
        geometry: NotchScreenGeometry?,
        cursorColorName: String,
        hasWorkingAgent: Bool,
        unreadCount: Int,
        isHovered: Bool,
        onTap: @escaping () -> Void
    ) {
        self.geometry = geometry
        self.cursorColorName = cursorColorName
        self.hasWorkingAgent = hasWorkingAgent
        self.unreadCount = unreadCount
        self.isHovered = isHovered
        self.onTap = onTap
    }

    private var accentColor: Color {
        DS.Colors.cursorColor(named: cursorColorName)
    }

    public var body: some View {
        Button(action: onTap) {
            Group {
                if let geometry, geometry.hasHardwareNotch {
                    hardwareNotchPill(notchWidth: geometry.hardwareNotchRect.width)
                } else {
                    fallbackRestingHandle
                }
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onAppear {
            if hasWorkingAgent || unreadCount > 0 {
                startPulse()
            }
        }
        .onChange(of: hasWorkingAgent || unreadCount > 0) { _, needsAttention in
            if needsAttention {
                startPulse()
            } else {
                isPulsing = false
            }
        }
    }

    private func hardwareNotchPill(notchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Left wing beside camera notch
            HStack(spacing: 5) {
                NotchClickyBrandMark(color: accentColor, size: 11)
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 6)

            // Center spacer matching physical camera notch
            Spacer()
                .frame(width: notchWidth)

            // Right wing beside camera notch
            HStack(spacing: 5) {
                if hasWorkingAgent {
                    pulsingWorkingIndicator
                } else {
                    Circle()
                        .fill(DS.Colors.textTertiary.opacity(0.65))
                        .frame(width: 5, height: 5)
                }

                if unreadCount > 0 {
                    NotchUnreadGelBadge(count: unreadCount)
                }
            }
            .frame(width: 48, alignment: .leading)
            .padding(.leading, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The black fill comes from NotchRootView's single morphing shape; only the hairline lives here.
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0
            )
            .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: 0.8)
        )
    }

    /// Thin top-edge handle for displays without a hardware notch. The whole resting rect stays
    /// hit-testable so hover, click and hold-to-talk keep working.
    private var fallbackRestingHandle: some View {
        let isAttentionNeeded = hasWorkingAgent || unreadCount > 0
        // Always black (fill comes from NotchRootView's morphing shape); never the cursor accent color.
        let baseStrokeOpacity = isHovered ? 0.45 : 0.28
        let strokeOpacity = isAttentionNeeded ? (isPulsing ? 0.35 : 0.6) : baseStrokeOpacity
        let handleSize = isHovered ? CGSize(width: 72, height: 8) : CGSize(width: 60, height: 6)
        return Capsule()
            .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.8)
            .frame(width: handleSize.width, height: handleSize.height)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isHovered)
            .accessibilityLabel(Text("Clicky"))
    }

    private var pulsingWorkingIndicator: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.success.opacity(0.35))
                .frame(width: 11, height: 11)
                .scaleEffect(isPulsing ? 1.45 : 0.85)
                .opacity(isPulsing ? 0.2 : 0.8)

            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
        }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}

// MARK: - Live Activity Pill Surface

struct NotchActivitySurface: View {
    let geometry: NotchScreenGeometry?
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var realtimeVoice: RealtimeVoiceController
    @ObservedObject var dictationManager: BuddyDictationManager
    @ObservedObject var jobStore: ClickyJobStore
    @ObservedObject var takeOverController: ClickyTakeOverController
    let unreadCount: Int
    let onTap: () -> Void

    init(
        geometry: NotchScreenGeometry?,
        companionManager: CompanionManager,
        realtimeVoice: RealtimeVoiceController,
        dictationManager: BuddyDictationManager,
        jobStore: ClickyJobStore,
        takeOverController: ClickyTakeOverController,
        unreadCount: Int,
        onTap: @escaping () -> Void
    ) {
        self.geometry = geometry
        self.companionManager = companionManager
        self.realtimeVoice = realtimeVoice
        self.dictationManager = dictationManager
        self.jobStore = jobStore
        self.takeOverController = takeOverController
        self.unreadCount = unreadCount
        self.onTap = onTap
    }

    private var activeStatusText: String {
        if takeOverController.phase == .driving {
            let status = takeOverController.overlayStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            return status.isEmpty ? String(localized: "Driving screen…") : status
        }
        if realtimeVoice.state.isActive {
            switch realtimeVoice.state {
            case .connecting: return String(localized: "Connecting voice…")
            case .listening: return String(localized: "Listening")
            case .thinking: return String(localized: "Thinking")
            case .speaking: return String(localized: "Speaking")
            case .idle, .error: break
            }
        }
        if dictationManager.isSystemWideDictationActive || dictationManager.isRecordingFromKeyboardShortcut {
            return dictationManager.isHandsFreeDictationActive ? String(localized: "Hands-free dictating") : String(localized: "Listening")
        }
        if dictationManager.isFinalizingTranscript {
            return String(localized: "Transcribing…")
        }
        switch companionManager.voiceState {
        case .listening: return String(localized: "Listening")
        case .processing: return String(localized: "Thinking")
        case .responding: return String(localized: "Speaking")
        case .idle: break
        }
        if let firstActiveJob = jobStore.activeJobs.first {
            return firstActiveJob.title
        }
        return String(localized: "Working…")
    }

    private var activeTint: Color {
        if takeOverController.phase == .driving {
            return DS.Colors.warning
        }
        if companionManager.voiceState == .listening
            || realtimeVoice.state == .listening
            || dictationManager.isActivelyRecordingAudio {
            return DS.Colors.accentText
        }
        if !jobStore.activeJobs.isEmpty {
            return DS.Colors.success
        }
        return DS.Colors.info
    }

    private var audioLevel: CGFloat {
        if realtimeVoice.state.isActive {
            return realtimeVoice.currentAudioPowerLevel
        }
        return max(companionManager.currentAudioPowerLevel, dictationManager.currentAudioPowerLevel)
    }

    public var body: some View {
        Button(action: onTap) {
            Group {
                if let geometry, geometry.hasHardwareNotch {
                    hardwareNotchActivityPill(notchWidth: geometry.hardwareNotchRect.width)
                } else {
                    fallbackActivityPill
                }
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func hardwareNotchActivityPill(notchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(activeStatusText)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
                .padding(.trailing, 8)

            Spacer()
                .frame(width: notchWidth)

            HStack(spacing: 5) {
                NotchWaveformBars(level: audioLevel, tint: activeTint, isAnimating: true)

                if unreadCount > 0 {
                    NotchUnreadGelBadge(count: unreadCount)
                }
            }
            .frame(width: 84, alignment: .leading)
            .padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 0
            )
            .stroke(activeTint.opacity(0.5), lineWidth: 0.9)
        )
    }

    private var fallbackActivityPill: some View {
        HStack(spacing: 8) {
            Text(activeStatusText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            NotchWaveformBars(level: audioLevel, tint: activeTint, isAnimating: true)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            Capsule()
                .stroke(activeTint.opacity(0.5), lineWidth: 0.9)
        )
    }
}

// MARK: - Panel Metrics & Top Bar Button

nonisolated enum NotchPanelMetrics {
    static let bottomCornerRadius: CGFloat = 16
    static let barFillColor = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1c / 255)
    static let selectedFillColor = Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255)
    static let inactiveIconColor = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)

    static func size(for tab: ClickyNotchTab) -> CGSize {
        tab == .settings ? CGSize(width: 800, height: 648) : CGSize(width: 516, height: 400)
    }

    /// Upper bound for the measured expanded panel (Home/Chat with stacked cards can outgrow Settings).
    /// The fixed notch canvas is sized from this so a tall panel is never clipped by the window.
    static let maximumExpandedSize = CGSize(width: 820, height: 760)
}

private struct NotchTopBarTabButton: View {
    let isSelected: Bool
    let systemImageName: String
    let label: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSelected || isHovered ? .white : NotchPanelMetrics.inactiveIconColor)
                .frame(width: 34, height: 24)
                .background(Capsule().fill(isSelected ? NotchPanelMetrics.selectedFillColor : Color.clear))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - HeyClicky Peek Surface (Tabbed)

struct NotchHeyClickyPeekSurface: View {
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject var companionManager: CompanionManager

    @ObservedObject private var jobStore = ClickyJobStore.shared
    @ObservedObject private var roster = ClickyRoster.shared
    @ObservedObject private var config = ClickyConfiguration.shared
    @ObservedObject private var realtimeVoice = RealtimeVoiceController.shared
    @ObservedObject private var documentReader = ActiveDocumentReader.shared
    @ObservedObject private var panelStyle = ClickyPanelStylePreference.shared

    @State private var selectedClickySlug: String?

    init(
        notchManager: NotchWindowManager,
        companionManager: CompanionManager
    ) {
        self.notchManager = notchManager
        self.companionManager = companionManager
    }

    private var activeDocumentFilePath: String? {
        let context = companionManager.activeDocumentContext ?? documentReader.lastCapturedContext
        if case .file(let path, _) = context?.reference {
            return path
        }
        return nil
    }

    private var totalUnreadCount: Int {
        NotchUnreadCounter.totalUnreadCount(jobStore: jobStore, roster: roster)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

            Group {
                switch notchManager.activeTab {
                case .home:
                    homeTabContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                case .chat:
                    chatTabContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                case .settings:
                    settingsTabContent
                case .document:
                    documentTabContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            width: NotchPanelMetrics.size(for: notchManager.activeTab).width,
            height: NotchPanelMetrics.size(for: notchManager.activeTab).height
        )
        .animation(.easeOut(duration: 0.2), value: notchManager.activeTab)
    }

    // MARK: - Top Bar

    private var isDocumentTabAvailable: Bool {
        (companionManager.activeDocumentContext ?? documentReader.lastCapturedContext) != nil
            || notchManager.activeTab == .document
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                topBarTabButton(tab: .home, systemImageName: "waveform.path", label: String(localized: "Home"))
                topBarTabButton(tab: .chat, systemImageName: "bubble.left.and.bubble.right.fill", label: String(localized: "Chat"))
                if isDocumentTabAvailable {
                    topBarTabButton(tab: .document, systemImageName: "doc.text", label: String(localized: "Document"))
                }
            }
            .padding(3)
            .background(Capsule().fill(NotchPanelMetrics.barFillColor))

            Spacer()

            let isSettingsSelected = notchManager.activeTab == .settings
            Button {
                notchManager.activeTab = isSettingsSelected ? .home : .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NotchPanelMetrics.inactiveIconColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(isSettingsSelected ? NotchPanelMetrics.selectedFillColor : NotchPanelMetrics.barFillColor))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(String(localized: "Settings"))
            .help(String(localized: "Settings"))
        }
    }

    private func topBarTabButton(tab: ClickyNotchTab, systemImageName: String, label: String) -> some View {
        NotchTopBarTabButton(
            isSelected: notchManager.activeTab == tab,
            systemImageName: systemImageName,
            label: label
        ) {
            notchManager.activeTab = tab
        }
    }

    private var greetingTitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        switch (hour, firstName.isEmpty) {
        case (5...11, false): return String(localized: "Morning, \(firstName).")
        case (5...11, true): return String(localized: "Good morning.")
        case (12...17, false): return String(localized: "Afternoon, \(firstName).")
        case (12...17, true): return String(localized: "Good afternoon.")
        case (_, false): return String(localized: "Evening, \(firstName).")
        default: return String(localized: "Good evening.")
        }
    }

    private var greetingSubtitle: String {
        let shortcutLabel = ClickyNotchHoldToTalk.shortcutLabel(
            companionManager.globalPushToTalkShortcutMonitor.binding(for: .voiceHold).displayText
        )
        return String(localized: "Hold \(shortcutLabel) and tell me what to take off your plate.")
    }

    // MARK: - Home Tab

    private var homeTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                Text(greetingTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text(greetingSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(NotchPanelMetrics.inactiveIconColor)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)

            voiceAndRealtimeStrip

            if !roster.clickys.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(roster.clickys) { profile in
                            let isSelected = selectedClickySlug == profile.slug
                            let latestJobDate = jobStore.jobs(forClickySlug: profile.slug)
                                .compactMap { $0.finishedAt ?? $0.createdAt }
                                .max()
                            let isUnread = roster.isUnread(slug: profile.slug, latestActivityAt: latestJobDate)

                            Button {
                                selectedClickySlug = isSelected ? nil : profile.slug
                            } label: {
                                HStack(spacing: 6) {
                                    ClickyAgentIconView(
                                        agentKey: profile.slug,
                                        title: profile.name,
                                        prop: profile.prop,
                                        baseHue: profile.baseHue,
                                        size: 20
                                    )
                                    Text(profile.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(DS.Colors.textPrimary)
                                        .lineLimit(1)

                                    if isUnread {
                                        Circle()
                                            .fill(DS.Colors.accentText)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 0.8)
                                )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                }
            }

            let visibleJobs = Array(jobStore.visibleJobs.prefix(3))
            if visibleJobs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No active tasks right now")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Type below or hold your shortcut to ask Clicky anything.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DS.Colors.surface1.opacity(0.7))
                )
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        ForEach(visibleJobs) { job in
                            ClickyArcCard(
                                job: job,
                                onStop: job.outcome == .working ? {
                                    companionManager.stopActiveAgentTask(jobID: job.id)
                                } : nil,
                                onOpen: {
                                    notchManager.collapseNotch()
                                    HeyClickyWindowController.shared.open(
                                        selectedSlug: job.clickySlug,
                                        initialTab: .home
                                    )
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            // Quick response preview if messages exist
            if let latestAssistantMessage = companionManager.chatMessages.last(where: { !isUserRole($0.role) }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Latest reply")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                        Button("View in Chat") {
                            notchManager.activeTab = .chat
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                        .pointerCursor()
                    }
                    Text(latestAssistantMessage.text)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.Colors.surface1.opacity(0.75))
                )
            }

            NotchTextInputSurface(
                notchManager: notchManager,
                companionManager: companionManager,
                selectedClickySlug: selectedClickySlug
            )
        }
    }

    private var voiceAndRealtimeStrip: some View {
        HStack(spacing: 8) {
            let isRealtimeActive = realtimeVoice.state.isActive
            Circle()
                .fill(isRealtimeActive || companionManager.voiceState != .idle ? DS.Colors.success : DS.Colors.textTertiary)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(voiceSummaryTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                if !realtimeVoice.activeProviderLabel.isEmpty && isRealtimeActive {
                    Text(realtimeVoice.activeProviderLabel)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Button {
                if isRealtimeActive {
                    realtimeVoice.stopSession()
                } else {
                    Task {
                        await realtimeVoice.startSession()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isRealtimeActive ? "stop.fill" : "waveform")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(isRealtimeActive ? "End Voice" : "Live Voice")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(isRealtimeActive ? DS.Colors.destructiveText : DS.Colors.accentText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isRealtimeActive ? DS.Colors.destructive.opacity(0.14) : DS.Colors.accentSubtle)
                )
                .overlay(
                    Capsule()
                        .stroke(isRealtimeActive ? DS.Colors.destructive.opacity(0.35) : DS.Colors.accent.opacity(0.35), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DS.Colors.surface1.opacity(0.85))
        )
    }

    private var voiceSummaryTitle: String {
        if realtimeVoice.state.isActive {
            switch realtimeVoice.state {
            case .connecting: return "Connecting realtime voice…"
            case .listening: return "Realtime voice listening"
            case .thinking: return "Realtime voice thinking…"
            case .speaking: return "Realtime voice speaking"
            case .idle, .error: break
            }
        }
        switch companionManager.voiceState {
        case .listening: return "Push-to-talk listening…"
        case .processing: return "Processing voice request…"
        case .responding: return "Speaking response…"
        case .idle: return "Voice ready (\(config.voicePipelineMode.displayName))"
        }
    }

    // MARK: - Chat Tab

    private var chatTabContent: some View {
        NotchTextResponseSurface(
            notchManager: notchManager,
            companionManager: companionManager,
            selectedClickySlug: selectedClickySlug
        )
    }

    // MARK: - Settings Tab

    private var settingsTabContent: some View {
        HomeSpaceSettingsPage(companionManager: companionManager)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0x1f / 255, green: 0x1f / 255, blue: 0x1f / 255))
    }

    // MARK: - Document Tab

    private var documentTabContent: some View {
        let context = companionManager.activeDocumentContext ?? documentReader.lastCapturedContext

        return VStack(alignment: .leading, spacing: 10) {
            if let context {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.accentText)

                        Text(context.reference.displayTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(context.kind.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.info)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DS.Colors.info.opacity(0.14)))
                    }

                    if let appName = context.applicationName, !appName.isEmpty {
                        Text("\(appName) · \(context.reference.rawLocation)")
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    let previewBody = (context.selectedText?.isEmpty == false ? context.selectedText! : context.extractedText)
                    if !previewBody.isEmpty {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(previewBody)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 130)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DS.Colors.surface1.opacity(0.8))
                        )
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DS.Colors.surface2.opacity(0.75))
                )

                HStack(spacing: 8) {
                    Button("Refresh") {
                        Task {
                            await companionManager.refreshActiveDocumentContext()
                        }
                    }
                    .dsSecondaryButtonStyle(isFullWidth: false)

                    Button("Ask About Document") {
                        if companionManager.textInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            companionManager.textInputDraft = "Summarize \(context.reference.displayTitle)"
                        }
                        notchManager.activeTab = .chat
                    }
                    .dsPrimaryButtonStyle(isFullWidth: false)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 22))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("No active document captured yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Capture the frontmost document, PDF, or browser tab to ask questions about it.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .multilineTextAlignment(.center)

                    Button("Scan Active Document") {
                        Task {
                            await companionManager.refreshActiveDocumentContext()
                        }
                    }
                    .dsPrimaryButtonStyle(isFullWidth: false)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DS.Colors.surface1.opacity(0.75))
                )
            }
        }
    }

    private func isUserRole<Role>(_ role: Role) -> Bool {
        String(describing: role).lowercased().contains("user")
    }
}

// MARK: - Text Response Surface

struct NotchTextResponseSurface: View {
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject var companionManager: CompanionManager
    let selectedClickySlug: String?

    @State private var copiedMessageID: String?
    @State private var lastStreamingScrollDate: Date = .distantPast

    init(
        notchManager: NotchWindowManager,
        companionManager: CompanionManager,
        selectedClickySlug: String? = nil
    ) {
        self.notchManager = notchManager
        self.companionManager = companionManager
        self.selectedClickySlug = selectedClickySlug
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if companionManager.chatMessages.isEmpty {
                emptyChatView
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        // Plain VStack (see HeyClickyWindowView.transcriptScrollArea): avoids a lazy-layout freeze while streaming.
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(companionManager.chatMessages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // Fill the room the panel leaves above the composer instead of a fixed 240pt cap.
                    .frame(maxHeight: .infinity)
                    .background(ChatDotGridBackground())
                    .onChange(of: companionManager.chatMessages.count) { _, _ in
                        if let lastID = companionManager.chatMessages.last?.id {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    // Keep the newest line in view while the reply streams in (throttled).
                    .onChange(of: companionManager.chatMessages.last?.text) { _, _ in
                        let now = Date()
                        guard ClickyChatStreamingScroll.shouldScroll(
                            secondsSinceLastScroll: now.timeIntervalSince(lastStreamingScrollDate)
                        ), let lastID = companionManager.chatMessages.last?.id else { return }
                        lastStreamingScrollDate = now
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }

            NotchTextInputSurface(
                notchManager: notchManager,
                companionManager: companionManager,
                selectedClickySlug: selectedClickySlug
            )
        }
    }

    private var emptyChatView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say hi to Clicky")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Everything you ask, by voice or by typing, lives here.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: 6) {
                quickSuggestionButton("What's on my screen?")
                quickSuggestionButton("Summarize active doc")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DS.Colors.surface1.opacity(0.8))
        )
    }

    private func quickSuggestionButton(_ prompt: String) -> some View {
        Button(prompt) {
            companionManager.submitTextPrompt(prompt, clickySlug: selectedClickySlug)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(DS.Colors.accentText)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(DS.Colors.accentSubtle)
        )
        .overlay(
            Capsule()
                .stroke(DS.Colors.accent.opacity(0.35), lineWidth: 0.8)
        )
        .pointerCursor()
    }

    @ViewBuilder
    private func messageRow(_ message: ClickyChatMessage) -> some View {
        let isUser = String(describing: message.role).lowercased().contains("user")
        let messageIDString = String(describing: message.id)
        let artifacts = resolveArtifactPaths(message.artifactPaths)

        if isUser {
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: NotchChatBubbleMetrics.bodyFontSize))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(NotchChatBubbleMetrics.bubbleFillColor)
                    )
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // The 'Clicky' / agent name label is hidden in the notch (HeyClicky 1.1.5 shows bubbles only).
                HStack(spacing: 6) {
                    Spacer()

                    if ClickyChatActivityLedger.shouldShowTypingDots(role: message.role, text: message.text) {
                        Text("Answering…")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Button {
                        copyTextToPasteboard(message.text)
                        copiedMessageID = messageIDString
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedMessageID == messageIDString {
                                copiedMessageID = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedMessageID == messageIDString ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copiedMessageID == messageIDString ? "Copied" : "Copy")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(copiedMessageID == messageIDString ? DS.Colors.success : DS.Colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(DS.Colors.surface2)
                        )
                    }
                    .buttonStyle(.plain)
                    .nativeTooltip(String(localized: "Copy response"))
                    .disabled(message.text.isEmpty)
                    .pointerCursor()
                }

                NotchActivityLedgerView(activityLines: message.activity)

                // Typing dots morph into the reply: both live in the same animated container.
                Group {
                    if ClickyChatActivityLedger.shouldShowTypingDots(role: message.role, text: message.text) {
                        NotchTypingDotsView()
                            .transition(.opacity)
                    } else {
                        NotchMarkdownTextView(markdown: message.text)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16).fill(NotchChatBubbleMetrics.bubbleFillColor))
                .overlay(alignment: .bottomLeading) {
                    ChatBubbleTail().offset(x: -2, y: 4)
                }
                .animation(.easeOut(duration: 0.2), value: message.text.isEmpty)

                if let drawingID = message.drawingID {
                    NotchChatDrawingRow(drawingID: drawingID) {
                        companionManager.detachDrawingFromChat(messageID: message.id)
                    }
                }

                if !artifacts.isEmpty {
                    NotchArtifactChipsRow(artifactPaths: artifacts)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resolveArtifactPaths(_ paths: [String]) -> [String] { paths }
    private func resolveArtifactPaths(_ paths: [String]?) -> [String] { paths ?? [] }

    private func copyTextToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Text Input Surface (Inline Composer)

struct NotchTextInputSurface: View {
    @ObservedObject var notchManager: NotchWindowManager
    @ObservedObject var companionManager: CompanionManager
    let selectedClickySlug: String?

    @FocusState private var isInputFocused: Bool
    @State private var runAsBackgroundAgent: Bool = false

    init(
        notchManager: NotchWindowManager,
        companionManager: CompanionManager,
        selectedClickySlug: String? = nil
    ) {
        self.notchManager = notchManager
        self.companionManager = companionManager
        self.selectedClickySlug = selectedClickySlug
    }

    private var canSubmit: Bool {
        !companionManager.textInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        ClickyChatComposerBar(
            companionManager: companionManager,
            draftText: $companionManager.textInputDraft,
            placeholder: runAsBackgroundAgent
                ? String(localized: "Assign a background agent task…")
                : (companionManager.chatMessages.isEmpty ? String(localized: "Ask HeyClicky…") : String(localized: "Follow up…")),
            runAsBackgroundJob: $runAsBackgroundAgent,
            showsBackgroundJobToggle: false,
            onExpand: {
                HeyClickyWindowController.shared.open(selectedSlug: selectedClickySlug, initialTab: .chat)
                notchManager.collapseNotch()
            },
            onStop: { companionManager.stopCurrentTurnFromChat() },
            onSubmit: { submitDraft() },
            isInputFocused: $isInputFocused
        )
        .onChange(of: isInputFocused) { _, focused in
            notchManager.setTextInputFocused(focused)
        }
        .onTapGesture {
            notchManager.setTextInputFocused(true)
            isInputFocused = true
        }
    }

    private func submitDraft() {
        let trimmed = companionManager.textInputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        companionManager.textInputDraft = ""
        if runAsBackgroundAgent {
            companionManager.startBackgroundAgentTask(prompt: trimmed, clickySlug: selectedClickySlug)
            notchManager.activeTab = .home
        } else {
            companionManager.submitTextPrompt(trimmed, clickySlug: selectedClickySlug)
            notchManager.activeTab = .chat
        }
    }
}

// MARK: - Markdown & Artifact Helpers

private enum NotchChatBubbleMetrics {
    static let bodyFontSize: CGFloat = 15
    static let bubbleFillColor = Color(hex: "#3a3a3c")
}

private struct NotchMarkdownTextView: View {
    let markdown: String

    private enum MarkdownBlock: Identifiable {
        case text(id: Int, content: String)
        case code(id: Int, language: String?, content: String)

        var id: Int {
            switch self {
            case .text(let id, _), .code(let id, _, _):
                return id
            }
        }
    }

    private var blocks: [MarkdownBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var textBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCodeBlock = false
        var codeLanguage: String?
        var nextID = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    result.append(.code(id: nextID, language: codeLanguage, content: codeBuffer.joined(separator: "\n")))
                    nextID += 1
                    codeBuffer.removeAll()
                    codeLanguage = nil
                    inCodeBlock = false
                } else {
                    if !textBuffer.isEmpty {
                        result.append(.text(id: nextID, content: textBuffer.joined(separator: "\n")))
                        nextID += 1
                        textBuffer.removeAll()
                    }
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                codeBuffer.append(line)
            } else {
                textBuffer.append(line)
            }
        }

        if inCodeBlock && !codeBuffer.isEmpty {
            result.append(.code(id: nextID, language: codeLanguage, content: codeBuffer.joined(separator: "\n")))
        } else if !textBuffer.isEmpty {
            result.append(.text(id: nextID, content: textBuffer.joined(separator: "\n")))
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                switch block {
                case .text(_, let content):
                    if let attributed = try? AttributedString(
                        markdown: content,
                        options: AttributedString.MarkdownParsingOptions(
                            interpretedSyntax: .inlineOnlyPreservingWhitespace
                        )
                    ) {
                        Text(attributed)
                            .font(.system(size: NotchChatBubbleMetrics.bodyFontSize))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(content)
                            .font(.system(size: NotchChatBubbleMetrics.bodyFontSize))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .code(_, let language, let codeContent):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(language ?? "code")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(DS.Colors.textTertiary)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(codeContent, forType: .string)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                            .pointerCursor()
                        }

                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(codeContent)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DS.Colors.codeText)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DS.Colors.background.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.8)
                    )
                }
            }
        }
    }
}

private struct NotchArtifactChipsRow: View {
    let artifactPaths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(artifactPaths, id: \.self) { path in
                    let isWebLink = path.hasPrefix("http://") || path.hasPrefix("https://")
                    let displayLabel = isWebLink
                        ? (URL(string: path)?.host ?? path)
                        : URL(fileURLWithPath: path).lastPathComponent

                    Button {
                        if isWebLink, let url = URL(string: path) {
                            NSWorkspace.shared.open(url)
                        } else {
                            let fileURL = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: fileURL.path) {
                                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isWebLink ? "link" : "doc.fill")
                                .font(.system(size: 9.5))
                                .foregroundColor(DS.Colors.accentText)
                            Text(displayLabel)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.surface2)
                        )
                        .overlay(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }
}

// MARK: - Visual Atoms

private struct NotchClickyBrandMark: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Triangle()
            .fill(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(-35))
            .shadow(color: color.opacity(0.5), radius: 4, x: 0, y: 0)
    }
}

private struct NotchUnreadGelBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [DS.Colors.blue500, DS.Colors.blue600],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
            )
            .shadow(color: DS.Colors.blue500.opacity(0.45), radius: 3, x: 0, y: 1)
    }
}

private struct NotchWaveformBars: View {
    let level: CGFloat
    let tint: Color
    let isAnimating: Bool

    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                let normalizedLevel = max(0.18, min(1.0, level * 1.4 + 0.25))
                let barScale = isAnimating
                    ? normalizedLevel * (0.6 + 0.4 * abs(sin(phase + CGFloat(index) * 0.9)))
                    : 0.3
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 2.5, height: max(4, 14 * barScale))
            }
        }
        .frame(height: 14)
        .onAppear {
            if isAnimating {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    phase = .pi * 2
                }
            }
        }
    }
}

// MARK: - Chat Pure Helpers (unit tested)

/// Press-and-hold on the notch pill = hold-to-talk. A shorter press stays a plain click.
nonisolated enum ClickyNotchHoldToTalk {
    static let holdThresholdSeconds: Double = 0.45
    /// Safety cap so a lost mouse-up can never leave the mic open.
    static let maximumHoldSeconds: Double = 60

    static func isHold(pressDurationSeconds: Double) -> Bool {
        pressDurationSeconds >= holdThresholdSeconds
    }

    /// `shortcutDisplayText` is empty when the binding has no label yet.
    static func shortcutLabel(_ shortcutDisplayText: String) -> String {
        shortcutDisplayText.isEmpty ? "Control+Option" : shortcutDisplayText
    }
}

/// Throttle for "scroll to bottom while the reply streams in".
nonisolated enum ClickyChatStreamingScroll {
    static let minimumIntervalSeconds: Double = 0.1

    static func shouldScroll(secondsSinceLastScroll: Double) -> Bool {
        secondsSinceLastScroll >= minimumIntervalSeconds
    }
}

/// Past-tense lines shown above a reply ("Looked at your screen").
nonisolated enum ClickyChatActivityLedger {
    static let lookedAtScreen = "Looked at your screen"
    static let lookedAtImage = "Looked at an image"
    static let readFile = "Read a file"
    static let savedDrawing = "Saved the drawing"

    static func eventsForTurn(tookScreenshot: Bool, attachedRegionImageCount: Int, readDocumentText: Bool) -> [String] {
        var events: [String] = []
        if tookScreenshot { events.append(lookedAtScreen) }
        if attachedRegionImageCount > 0 { events.append(lookedAtImage) }
        if readDocumentText { events.append(readFile) }
        return events
    }

    /// Appends `newEvents` that are not already present, keeping order.
    static func merged(_ existing: [String], with newEvents: [String]) -> [String] {
        existing + newEvents.filter { !existing.contains($0) }
    }

    /// Text shown for a voice reply. Drawing-only replies get a short placeholder so the row is not blank.
    static func displayReply(spokenText: String, hasDrawing: Bool) -> String {
        let trimmed = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && hasDrawing { return "Drawn on your screen." }
        return trimmed
    }

    /// Typing dots are shown while the assistant row has no text yet.
    static func shouldShowTypingDots(role: String, text: String) -> Bool {
        role == "assistant" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Shared Chat Row Pieces

/// Three bouncing dots; the reply text replaces them with a short fade.
struct NotchTypingDotsView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { dotIndex in
                Circle()
                    .fill(DS.Colors.textTertiary)
                    .frame(width: 5, height: 5)
                    .offset(y: isAnimating ? -3 : 2)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(dotIndex) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .padding(.vertical, 4)
        .onAppear { isAnimating = true }
    }
}

/// Small dim past-tense lines above the reply.
struct NotchActivityLedgerView: View {
    let activityLines: [String]

    var body: some View {
        if !activityLines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(activityLines, id: \.self) { activityLine in
                    Text(LocalizedStringKey(activityLine))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }
}

/// Compact row for a drawing that stays in the chat. Hidden when the drawing was deleted from the library.
struct NotchChatDrawingRow: View {
    let drawingID: UUID
    let onRemoveFromChat: () -> Void
    @ObservedObject private var recentDrawings = ClickyRecentDrawings.shared

    var body: some View {
        if let storedDrawing = recentDrawings.drawing(id: drawingID) {
            HStack(spacing: 8) {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accentText)

                Text(storedDrawing.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Menu {
                    Button("Play it in a window") {
                        ClickyDrawingPlayer.play(drawingID: drawingID, mode: .window)
                    }
                    Button("Play it full screen over your screen") {
                        ClickyDrawingPlayer.play(drawingID: drawingID, mode: .fullScreen)
                    }
                    Button("Play on a white board") {
                        ClickyDrawingPlayer.play(drawingID: drawingID, mode: .whiteboard)
                    }
                } label: {
                    Text("Play again")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()

                Button(action: onRemoveFromChat) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .nativeTooltip(String(localized: "Remove from the chat (it stays in Drawings)"))
                .pointerCursor()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(DS.Colors.surface2)
            )
        }
    }
}
