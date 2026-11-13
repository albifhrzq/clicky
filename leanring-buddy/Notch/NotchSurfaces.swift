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

    init(
        displayID: CGDirectDisplayID,
        notchManager: NotchWindowManager = .shared,
        companionManager: CompanionManager
    ) {
        self.displayID = displayID
        self.notchManager = notchManager
        self.companionManager = companionManager
        self._dictationManager = ObservedObject(wrappedValue: companionManager.buddyDictationManager)
    }

    private var geometry: NotchScreenGeometry? {
        notchManager.geometry(for: displayID)
    }

    private var isThisScreenExpanded: Bool {
        notchManager.isExpanded && (notchManager.activeDisplayID == displayID || (notchManager.activeDisplayID == nil && displayID == notchManager.primaryDisplayID))
    }

    private var hasLiveActivity: Bool {
        companionManager.voiceState != .idle
            || realtimeVoice.state.isActive
            || dictationManager.isDictationInProgress
            || !jobStore.activeJobs.isEmpty
            || takeOverController.phase == .driving
    }

    private var totalUnreadCount: Int {
        NotchUnreadCounter.totalUnreadCount(jobStore: jobStore, roster: roster)
    }

    public var body: some View {
        Group {
            if isThisScreenExpanded {
                expandedContainer
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if hasLiveActivity {
                NotchActivitySurface(
                    geometry: geometry,
                    companionManager: companionManager,
                    realtimeVoice: realtimeVoice,
                    dictationManager: dictationManager,
                    jobStore: jobStore,
                    takeOverController: takeOverController,
                    unreadCount: totalUnreadCount,
                    onTap: {
                        notchManager.expandNotch(tab: notchManager.activeTab, on: displayID)
                    }
                )
                .onHover { hovering in
                    notchManager.setHovered(hovering, on: displayID)
                }
            } else {
                NotchRestingMarkSurface(
                    geometry: geometry,
                    cursorColorName: config.cursorColorName,
                    hasWorkingAgent: !jobStore.activeJobs.isEmpty || takeOverController.phase == .driving,
                    unreadCount: totalUnreadCount,
                    isHovered: notchManager.isHovered,
                    onTap: {
                        notchManager.expandNotch(tab: notchManager.activeTab, on: displayID)
                    }
                )
                .onHover { hovering in
                    notchManager.setHovered(hovering, on: displayID)
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isThisScreenExpanded)
        .animation(.easeInOut(duration: 0.2), value: hasLiveActivity)
    }

    private var expandedContainer: some View {
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

            NotchHeyClickyPeekSurface(
                notchManager: notchManager,
                companionManager: companionManager
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, geometry?.hasHardwareNotch == true ? 4 : 10)
        .frame(width: 440)
        .background(
            ClickyPanelBackground(
                cornerRadius: 20,
                usesTranslucentMaterial: panelStyle.usesTransparentPanes
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(DS.Colors.borderSubtle.opacity(0.85), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 22, x: 0, y: 10)
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
                    fallbackFloatingPill
                }
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onAppear {
            if hasWorkingAgent {
                startPulse()
            }
        }
        .onChange(of: hasWorkingAgent) { _, working in
            if working {
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
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0
            )
            .fill(Color.black.opacity(isHovered ? 0.96 : 0.90))
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0
            )
            .stroke(isHovered ? accentColor.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }

    private var fallbackFloatingPill: some View {
        HStack(spacing: 8) {
            NotchClickyBrandMark(color: accentColor, size: 11)

            Text("Clicky")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer(minLength: 2)

            if hasWorkingAgent {
                pulsingWorkingIndicator
            }

            if unreadCount > 0 {
                NotchUnreadGelBadge(count: unreadCount)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(Color.black.opacity(isHovered ? 0.94 : 0.86))
        )
        .overlay(
            Capsule()
                .stroke(isHovered ? accentColor.opacity(0.55) : Color.white.opacity(0.14), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
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
            return status.isEmpty ? "Driving screen…" : status
        }
        if realtimeVoice.state.isActive {
            switch realtimeVoice.state {
            case .connecting: return "Connecting voice…"
            case .listening: return "Listening…"
            case .thinking: return "Thinking…"
            case .speaking: return "Speaking…"
            case .idle, .error: break
            }
        }
        if dictationManager.isSystemWideDictationActive || dictationManager.isRecordingFromKeyboardShortcut {
            return dictationManager.isHandsFreeDictationActive ? "Hands-free dictating" : "Listening…"
        }
        if dictationManager.isFinalizingTranscript {
            return "Transcribing…"
        }
        switch companionManager.voiceState {
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Responding…"
        case .idle: break
        }
        if let firstActiveJob = jobStore.activeJobs.first {
            return firstActiveJob.title
        }
        return "Working…"
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
            HStack(spacing: 5) {
                NotchWaveformBars(level: audioLevel, tint: activeTint, isAnimating: true)
                Text(activeStatusText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 84, alignment: .trailing)
            .padding(.trailing, 8)

            Spacer()
                .frame(width: notchWidth)

            HStack(spacing: 5) {
                if !jobStore.activeJobs.isEmpty {
                    Text("\(jobStore.activeJobs.count) active")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                } else if !realtimeVoice.activeProviderLabel.isEmpty && realtimeVoice.state.isActive {
                    Text(realtimeVoice.activeProviderLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Clicky")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                if unreadCount > 0 {
                    NotchUnreadGelBadge(count: unreadCount)
                }
            }
            .frame(width: 84, alignment: .leading)
            .padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 0
            )
            .fill(Color.black.opacity(0.95))
        )
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
            NotchWaveformBars(level: audioLevel, tint: activeTint, isAnimating: true)

            Text(activeStatusText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !jobStore.activeJobs.isEmpty {
                Text("\(jobStore.activeJobs.count)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(DS.Colors.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.success.opacity(0.18)))
            }

            if unreadCount > 0 {
                NotchUnreadGelBadge(count: unreadCount)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            Capsule()
                .stroke(activeTint.opacity(0.5), lineWidth: 0.9)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
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
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.65))

            switch notchManager.activeTab {
            case .home:
                homeTabContent
            case .chat:
                chatTabContent
            case .settings:
                settingsTabContent
            case .document:
                documentTabContent
            }
        }
    }

    // MARK: - Header & Tabs

    private var headerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    NotchClickyBrandMark(
                        color: DS.Colors.cursorColor(named: config.cursorColorName),
                        size: 13
                    )

                    Text("HeyClicky")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    if totalUnreadCount > 0 {
                        NotchUnreadGelBadge(count: totalUnreadCount)
                    }
                }

                Spacer()

                Button {
                    let tab = notchManager.activeTab
                    let docPath = activeDocumentFilePath
                    let slug = selectedClickySlug
                    notchManager.collapseNotch()
                    HeyClickyWindowController.shared.open(
                        selectedSlug: slug,
                        documentPath: docPath,
                        initialTab: tab
                    )
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Open in a window")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
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

                Button {
                    notchManager.collapseNotch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .dsIconButtonStyle(size: 24, tooltip: "Collapse (Esc)", tooltipAlignment: .trailing)
            }

            HStack(spacing: 4) {
                ForEach(ClickyNotchTab.allCases) { tab in
                    let isSelected = notchManager.activeTab == tab
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            notchManager.activeTab = tab
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.systemImageName)
                                .font(.system(size: 10.5, weight: .medium))
                            Text(tab.displayName)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? DS.Colors.surface3 : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? DS.Colors.borderStrong.opacity(0.6) : Color.clear, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DS.Colors.surface1.opacity(0.85))
            )
        }
    }

    // MARK: - Home Tab

    private var homeTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Connection Mode")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Picker("", selection: $config.mode) {
                        ForEach(ClickyConnectionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .pointerCursor()
                }

                HStack {
                    Text("Voice Pipeline")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Picker("", selection: $config.voicePipelineMode) {
                        ForEach(ClickyVoicePipelineMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .pointerCursor()
                }

                HStack {
                    Text("Active Model")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text(config.selectedModel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Toggle(isOn: Binding(
                    get: { companionManager.isClickyCursorEnabled },
                    set: { companionManager.setClickyCursorEnabled($0) }
                )) {
                    Text("Show Floating Clicky Cursor")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .toggleStyle(.switch)
                .pointerCursor()

                Toggle(isOn: $config.voiceWakeWordEnabled) {
                    Text("Voice Wake Call")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .toggleStyle(.switch)
                .pointerCursor()

                if config.voiceWakeWordEnabled {
                    HStack {
                        Text("Wake Phrase")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        TextField("hey clicky", text: $config.voiceWakePhrase)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 210)
                    }
                }

                Toggle(isOn: $panelStyle.usesTransparentPanes) {
                    Text("Translucent Notch & Panels")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .toggleStyle(.switch)
                .pointerCursor()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DS.Colors.surface1.opacity(0.85))
            )

            HStack(spacing: 8) {
                Button("Test Connection") {
                    companionManager.sendOpenCodexOrBYOKTestPrompt()
                    notchManager.activeTab = .chat
                }
                .dsSecondaryButtonStyle(isFullWidth: false)

                Spacer()

                Button("All Settings in Window") {
                    notchManager.collapseNotch()
                    HeyClickyWindowController.shared.open(initialTab: .settings)
                }
                .dsPrimaryButtonStyle(isFullWidth: false)
            }
        }
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
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(companionManager.chatMessages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: companionManager.chatMessages.count) { _, _ in
                        if let lastID = companionManager.chatMessages.last?.id {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
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
            Text("Ask Clicky anything")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Answers stream here with markdown, copyable code, and clickable artifacts.")
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
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DS.Colors.helpChatUserBubble)
                    )
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let slug = resolveOptionalSlug(message.clickySlug), !slug.isEmpty {
                        Text(slug)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.accentText)
                    } else {
                        Text("Clicky")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.accentText)
                    }

                    Spacer()

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
                    .pointerCursor()
                }

                NotchMarkdownTextView(markdown: message.text)

                if !artifacts.isEmpty {
                    NotchArtifactChipsRow(artifactPaths: artifacts)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DS.Colors.surface1.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
            )
        }
    }

    private func resolveOptionalSlug(_ slug: String) -> String? { slug }
    private func resolveOptionalSlug(_ slug: String?) -> String? { slug }

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
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    runAsBackgroundAgent ? "Assign a background agent task…" : "Ask a follow-up or run a task…",
                    text: $companionManager.textInputDraft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit {
                    submitDraft()
                }
                .overlay(IBeamCursorView())

                Button {
                    runAsBackgroundAgent.toggle()
                } label: {
                    Image(systemName: runAsBackgroundAgent ? "bolt.circle.fill" : "bolt.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(runAsBackgroundAgent ? DS.Colors.success : DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .nativeTooltip(runAsBackgroundAgent ? "Background Agent Task: On" : "Switch to Background Agent Task")
                .pointerCursor()

                Button {
                    submitDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(canSubmit ? .white : DS.Colors.disabledText)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(canSubmit ? DS.Colors.accent : DS.Colors.surface3)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .pointerCursor(isEnabled: canSubmit)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DS.Colors.surface2.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isInputFocused ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
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
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(content)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
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
