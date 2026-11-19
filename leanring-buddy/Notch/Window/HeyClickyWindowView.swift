//
//  HeyClickyWindowView.swift
//  leanring-buddy
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct HeyClickyWindowView: View {
    @ObservedObject var windowController: HeyClickyWindowController
    @ObservedObject var companionManager: CompanionManager

    @ObservedObject private var config = ClickyConfiguration.shared
    @ObservedObject private var openCodex = OpenCodexService.shared
    @ObservedObject private var antigravityOAuth = AntigravityOAuthManager.shared
    @ObservedObject private var roster = ClickyRoster.shared
    @ObservedObject private var jobStore = ClickyJobStore.shared
    @ObservedObject private var uploadApproval = ClickyUploadApproval.shared
    @ObservedObject private var takeOverController = ClickyTakeOverController.shared
    @ObservedObject private var harnessRuntime = AgentHarnessRunnerRuntime.shared

    @State private var attachedFileURLs: [URL] = []
    @State private var isDropTargeted: Bool = false
    @State private var isShowingNewClickySheet: Bool = false
    @State private var sidebarNoticeText: String?
    @ObservedObject private var liveNoteWatcher = ClickyLiveNoteWatcher.shared
    @State private var dragStartDocumentWidth: CGFloat? = nil
    @State private var lastStreamingScrollDate: Date = .distantPast
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Divider()
                .background(DS.Colors.borderSubtle)

            mainTabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            ClickyPanelBackground(cornerRadius: 16, usesTranslucentMaterial: true)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { ClickyLiveNoteWatcher.shared.beginObserving() }
        .onDisappear { ClickyLiveNoteWatcher.shared.endObserving() }
        .sheet(isPresented: $isShowingNewClickySheet) {
            NewClickySheet { createdProfile in
                windowController.selectThread(slug: createdProfile.slug)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Reserve space for native macOS traffic lights when fullSizeContentView is active
            Spacer()
                .frame(width: 68)

            if windowController.activeTab == .chat || windowController.activeTab == .document {
                Button {
                    windowController.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(windowController.isSidebarShown ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .frame(width: 28, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(windowController.isSidebarShown ? DS.Colors.surface2 : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip(windowController.isSidebarShown ? "Hide Sidebar" : "Show Sidebar")
            }

            Spacer(minLength: 8)

            tabSwitcher

            Spacer(minLength: 8)

            connectionStatusPill

            if windowController.activeTab == .chat || windowController.activeTab == .document {
                Button {
                    if windowController.isDocumentColumnVisible {
                        windowController.closeDocumentColumn()
                    } else {
                        windowController.openActiveDocumentContext()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(windowController.isDocumentColumnVisible ? DS.Colors.accentText : DS.Colors.textTertiary)
                        .frame(width: 28, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(windowController.isDocumentColumnVisible ? DS.Colors.accentSubtle : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip(windowController.isDocumentColumnVisible ? "Hide Document Pane" : "Show Document Pane")
            }

            Button {
                windowController.collapseToNotch()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 11, weight: .medium))
                    Text("Notch")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Collapse to Notch")

            Button {
                windowController.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .dsIconButtonStyle(size: 26, tooltip: "Close Window", tooltipAlignment: .trailing)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1.opacity(0.65))
    }

    private var tabSwitcher: some View {
        HStack(spacing: 3) {
            topTabButton(title: "Home Space", icon: "square.grid.2x2", tab: .home)
            topTabButton(title: "Chat", icon: "bubble.left.and.bubble.right", tab: .chat)
            topTabButton(title: "Settings", icon: "gearshape", tab: .settings)
        }
        .padding(3)
        .background(
            Capsule()
                .fill(DS.Colors.surface2)
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        )
    }

    private func topTabButton(title: String, icon: String, tab: ClickyNotchTab) -> some View {
        let isSelected: Bool = {
            if tab == .chat {
                return windowController.activeTab == .chat || windowController.activeTab == .document
            }
            return windowController.activeTab == tab
        }()

        return Button {
            withAnimation(.easeInOut(duration: DS.Animation.fast)) {
                windowController.activeTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? DS.Colors.surface3 : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var connectionStatusPill: some View {
        let status = resolvedConnectionStatus()

        return Button {
            windowController.openSettings(section: .connection)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 7, height: 7)

                Text(status.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip("Connection & Model Settings")
    }

    private func resolvedConnectionStatus() -> (label: String, dotColor: Color) {
        switch config.mode {
        case .openCodex:
            if openCodex.isHealthy {
                let latencySuffix = openCodex.latencyMs > 0 ? " · \(openCodex.latencyMs)ms" : ""
                return ("OpenCodex\(latencySuffix)", DS.Colors.success)
            }
            return ("OpenCodex · Offline", DS.Colors.warning)

        case .nativeAntigravity:
            if antigravityOAuth.isAuthenticated {
                let accountLabel = antigravityOAuth.userEmail ?? "Signed in"
                return ("OAuth · \(accountLabel)", DS.Colors.success)
            }
            return ("OAuth · Sign in", DS.Colors.warning)

        case .byok:
            let hasAnyKey = !config.anthropicAPIKey.isEmpty
                || !config.openaiAPIKey.isEmpty
                || !config.geminiAPIKey.isEmpty
            let shortModel = config.selectedModel.split(separator: "/").last.map(String.init) ?? config.selectedModel
            if hasAnyKey {
                return ("BYOK · \(shortModel)", DS.Colors.success)
            }
            return ("BYOK · Add Key", DS.Colors.warning)

        case .cloudflareWorker:
            let isLocalWorker = config.isLocalModeWithoutPaywall
            return (isLocalWorker ? "Worker · Local" : "Worker · Cloud", DS.Colors.info)
        }
    }

    // MARK: - Main Tab Body

    @ViewBuilder
    private var mainTabBody: some View {
        switch windowController.activeTab {
        case .home:
            HomeSpaceView(companionManager: companionManager) {
                windowController.openSettings(section: .connection)
            }

        case .settings:
            HomeSpaceSettingsPage(
                companionManager: companionManager,
                initialSection: windowController.activeSettingsSection
            )

        case .chat, .document:
            chatWorkspaceBody
        }
    }

    private var chatWorkspaceBody: some View {
        HStack(spacing: 0) {
            if windowController.isSidebarShown {
                sidebarColumn
                    .frame(width: 236)

                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            conversationColumn
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            if windowController.isDocumentColumnVisible {
                documentSplitResizeHandle

                HeyClickyDocumentColumn(
                    documentURL: windowController.selectedDocumentURL,
                    activeDocumentContext: companionManager.activeDocumentContext,
                    onClose: {
                        windowController.closeDocumentColumn()
                    },
                    onInkAction: { actionPrompt in
                        dispatchPromptFromInkOrPill(actionPrompt)
                    }
                )
                .frame(width: windowController.documentColumnWidth)
            }
        }
    }

    private var documentSplitResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(width: 1)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(DS.Colors.borderStrong)
                .frame(width: 3, height: 32)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(SplitHorizontalResizeCursorView())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { gestureValue in
                    if dragStartDocumentWidth == nil {
                        dragStartDocumentWidth = windowController.documentColumnWidth
                    }
                    let baseWidth = dragStartDocumentWidth ?? windowController.documentColumnWidth
                    windowController.updateDocumentColumnWidth(baseWidth - gestureValue.translation.width)
                }
                .onEnded { _ in
                    dragStartDocumentWidth = nil
                }
        )
    }

    // MARK: - Sidebar

    private var sidebarColumn: some View {
        let grouped = groupedSidebarProfiles()

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    sidebarSummaryLine

                    // Main HeyClicky Thread
                    yourChatSidebarRow

                    if !grouped.working.isEmpty {
                        sidebarSection(title: "Working", profiles: grouped.working, isWorkingSection: true)
                    }

                    if !grouped.recents.isEmpty {
                        sidebarSection(title: "Recents", profiles: grouped.recents, isWorkingSection: false)
                    }

                    if !grouped.earlier.isEmpty {
                        sidebarSection(title: "Earlier", profiles: grouped.earlier, isWorkingSection: false)
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.md)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            Button {
                isShowingNewClickySheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.accentText)
                    Text("New Clicky")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .background(DS.Colors.surface1.opacity(0.55))
    }

    private var yourChatSidebarRow: some View {
        let isSelected = windowController.selectedSlug == nil
        let isMainBusy = companionManager.voiceState == .processing || companionManager.voiceState == .responding

        return Button {
            windowController.selectThread(slug: nil)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                ClickyAgentIconView(
                    agentKey: "heyclicky-main",
                    title: "Your chat",
                    mood: isMainBusy ? .working : .idle,
                    prop: .sparkle,
                    baseHue: 0.58,
                    size: 28
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Your chat")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)

                        if isMainBusy {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }

                    Text("Screen, voice & quick answers")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func sidebarSection(title: String, profiles: [ClickyProfile], isWorkingSection: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .tracking(0.5)
                .padding(.horizontal, 8)

            ForEach(profiles) { profile in
                clickySidebarRow(profile: profile, isWorkingSection: isWorkingSection)
            }
        }
    }

    private func clickySidebarRow(profile: ClickyProfile, isWorkingSection: Bool) -> some View {
        let isSelected = windowController.selectedSlug == profile.slug
        let slugJobs = jobStore.jobs(forClickySlug: profile.slug)
        let latestJob = slugJobs.first
        let latestActivity = latestJob.map { $0.finishedAt ?? $0.createdAt }
        let hasUnreadJob = slugJobs.contains { job in !job.isSeen && job.outcome != .working }
        let isUnread = !isSelected && (roster.isUnread(slug: profile.slug, latestActivityAt: latestActivity) || hasUnreadJob)
        let isWorking = isWorkingSection || slugJobs.contains { job in job.outcome == .working || job.isWaitingStepFlagged() }

        return Button {
            windowController.selectThread(slug: profile.slug)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                ClickyAgentIconView(
                    agentKey: profile.slug,
                    title: profile.name,
                    mood: isWorking ? .working : .idle,
                    prop: profile.prop,
                    baseHue: profile.baseHue,
                    size: 28
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 12.5, weight: isUnread ? .bold : .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)

                    Text(latestJob?.title ?? profile.roleText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                } else if isUnread {
                    Circle()
                        .fill(DS.Colors.accent)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .contextMenu {
            if let latestJob {
                sidebarJobContextMenu(for: latestJob)
            }
        }
    }

    /// Archive is refused while the agent is working; "Stop and remove" stops it first.
    @ViewBuilder
    private func sidebarJobContextMenu(for job: ClickyJob) -> some View {
        Button("Archive") {
            if !jobStore.archiveJob(jobID: job.id) {
                showSidebarNotice(String(localized: "Stop the agent before archiving it."))
            }
        }
        if job.outcome == .working {
            Button("Stop and remove from the dock") {
                companionManager.stopActiveAgentTask(jobID: job.id)
                jobStore.dismissJob(jobID: job.id)
            }
        } else {
            Button("Remove from the dock") {
                jobStore.dismissJob(jobID: job.id)
            }
        }
    }

    private func showSidebarNotice(_ message: String) {
        sidebarNoticeText = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if sidebarNoticeText == message { sidebarNoticeText = nil }
        }
    }

    /// "2 need you" / "1 job working" summary shown above the sidebar rows.
    @ViewBuilder
    private var sidebarSummaryLine: some View {
        let needsYouCount = jobStore.visibleJobs.filter { $0.railPhase == .needsYou }.count
        let workingCount = jobStore.visibleJobs.filter { $0.outcome == .working && $0.railPhase != .needsYou }.count
        if needsYouCount > 0 || workingCount > 0 || sidebarNoticeText != nil {
            VStack(alignment: .leading, spacing: 2) {
                if needsYouCount > 0 {
                    Text("\(needsYouCount) need you")
                        .foregroundColor(DS.Colors.warningText)
                }
                if workingCount > 0 {
                    Text("\(workingCount) jobs working")
                        .foregroundColor(DS.Colors.textSecondary)
                }
                if let sidebarNoticeText {
                    Text(sidebarNoticeText)
                        .foregroundColor(DS.Colors.warningText)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
        }
    }

    private func groupedSidebarProfiles() -> (working: [ClickyProfile], recents: [ClickyProfile], earlier: [ClickyProfile]) {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var working: [ClickyProfile] = []
        var recents: [ClickyProfile] = []
        var earlier: [ClickyProfile] = []

        func latestActivityDate(for profile: ClickyProfile) -> Date {
            let slugJobs = jobStore.jobs(forClickySlug: profile.slug)
            if let newestJobDate = slugJobs.map({ $0.finishedAt ?? $0.createdAt }).max() {
                return max(newestJobDate, profile.createdAt)
            }
            return profile.createdAt
        }

        for profile in roster.clickys {
            let slugJobs = jobStore.jobs(forClickySlug: profile.slug)
            let isWorking = slugJobs.contains { job in
                !job.isArchived && !job.isDismissed && (job.outcome == .working || job.isWaitingStepFlagged())
            }
            if isWorking {
                working.append(profile)
            } else if latestActivityDate(for: profile) >= sevenDaysAgo {
                recents.append(profile)
            } else {
                earlier.append(profile)
            }
        }

        recents.sort { latestActivityDate(for: $0) > latestActivityDate(for: $1) }
        earlier.sort { latestActivityDate(for: $0) > latestActivityDate(for: $1) }

        return (working, recents, earlier)
    }

    // MARK: - Main Conversation Column

    private var selectedProfile: ClickyProfile? {
        guard let slug = windowController.selectedSlug else { return nil }
        return roster.activeClicky(forSlug: slug) ?? roster.clicky(forSlug: slug)
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            threadHeaderBar

            Divider()
                .background(DS.Colors.borderSubtle)

            inlineConsentAndNoticeStack

            transcriptScrollArea

            followUpPillsStrip

            runningTaskStopBar

            Divider()
                .background(DS.Colors.borderSubtle)

            composerArea
        }
    }

    private var threadHeaderBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            if let profile = selectedProfile {
                ClickyAgentIconView(
                    agentKey: profile.slug,
                    title: profile.name,
                    prop: profile.prop,
                    baseHue: profile.baseHue,
                    size: 26
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(profile.roleText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                let noteURL = ClickyWorkFolderFiles.shared.noteMarkdownURL(forSlug: profile.slug)
                if FileManager.default.fileExists(atPath: noteURL.path) {
                    Button {
                        windowController.openDocument(url: noteURL)
                    } label: {
                        Label("Live Note", systemImage: "doc.richtext")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DS.Colors.surface2))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Button {
                    let workspaceURL = ClickyWorkFolderFiles.shared.ensureClickyWorkspace(profile: profile)
                    NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                } label: {
                    Label("Workspace", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.surface2))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your chat")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Model: \(config.selectedModel)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                if let activeDocument = companionManager.activeDocumentContext {
                    Button {
                        windowController.openActiveDocumentContext()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                            Text(activeDocument.reference.displayTitle)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.accentSubtle))
                        .frame(maxWidth: 210)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .nativeTooltip("Open Active Document in Split Column")
                }

                Button {
                    Task {
                        await companionManager.refreshActiveDocumentContext()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .dsIconButtonStyle(size: 26, tooltip: "Refresh Active Document Context", tooltipAlignment: .trailing)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 9)
        .background(DS.Colors.surface1.opacity(0.45))
    }

    @ViewBuilder
    private var inlineConsentAndNoticeStack: some View {
        VStack(spacing: DS.Spacing.sm) {
            if let pendingUpload = uploadApproval.pendingRequest {
                ClickyUploadApprovalCard(request: pendingUpload) { decision in
                    uploadApproval.resolvePending(decision)
                }
            }

            if let pendingTakeOver = takeOverController.pendingConsent {
                ClickyTakeOverConsentCard(request: pendingTakeOver) { approved in
                    takeOverController.resolvePendingConsent(approved ? .approve : .decline)
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

            if let docNotice = companionManager.activeDocumentNotice {
                DocumentAccessNoticeCard(
                    notice: docNotice,
                    onOpenSettings: {
                        ActiveDocumentReader.shared.openFilesAndFoldersPrivacySettings()
                    },
                    onDismiss: {
                        ActiveDocumentReader.shared.dismissAccessNotice(dontShowAgain: false)
                    }
                )
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, hasInlineBanners ? DS.Spacing.sm : 0)
    }

    private var hasInlineBanners: Bool {
        uploadApproval.pendingRequest != nil
            || takeOverController.pendingConsent != nil
            || companionManager.pendingHandoffRequest != nil
            || companionManager.activeDocumentNotice != nil
    }

    // MARK: - Scrollable Transcript

    private var filteredChatMessages: [ClickyChatMessage] {
        let activeSlug = windowController.selectedSlug
        return companionManager.chatMessages.filter { message in
            let messageSlug: String? = message.clickySlug
            if let activeSlug, !activeSlug.isEmpty {
                return messageSlug == activeSlug
            }
            return messageSlug == nil || messageSlug?.isEmpty == true
        }
    }

    private var transcriptScrollArea: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                // Plain VStack: a LazyVStack re-estimating rows whose height changes while streaming
                // (typing dots, growing text) can spin SwiftUI layout forever and freeze the app.
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if let profile = selectedProfile {
                        clickyTranscriptContent(profile: profile)
                    } else {
                        mainChatTranscriptContent
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom-anchor")
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
            }
            .onChange(of: companionManager.chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo("transcript-bottom-anchor", anchor: .bottom)
                }
            }
            // Keep the newest line in view while the reply streams in (throttled).
            .onChange(of: companionManager.chatMessages.last?.text) { _, _ in
                let now = Date()
                guard ClickyChatStreamingScroll.shouldScroll(
                    secondsSinceLastScroll: now.timeIntervalSince(lastStreamingScrollDate)
                ) else { return }
                lastStreamingScrollDate = now
                // No animation: animated scrolls stacking with streaming layout changes can loop layout.
                scrollProxy.scrollTo("transcript-bottom-anchor", anchor: .bottom)
            }
            .onChange(of: jobStore.jobs) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo("transcript-bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: windowController.selectedSlug) { _, _ in
                scrollProxy.scrollTo("transcript-bottom-anchor", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var mainChatTranscriptContent: some View {
        let messages = filteredChatMessages
        if messages.isEmpty {
            VStack(spacing: DS.Spacing.md) {
                ClickyAgentIconView(
                    agentKey: "heyclicky-main",
                    title: "HeyClicky",
                    prop: .sparkle,
                    baseHue: 0.58,
                    size: 52
                )

                Text("Ask HeyClicky anything")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Type a question, drop a file, or hold your push-to-talk shortcut to speak with screen context.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            ForEach(messages, id: \.id) { message in
                chatMessageBubble(message: message)
            }
        }

        if companionManager.voiceState == .processing || companionManager.voiceState == .responding {
            streamingStatusIndicator(
                label: companionManager.voiceState == .processing ? "Thinking..." : "Responding..."
            )
        }
    }

    @ViewBuilder
    private func clickyTranscriptContent(profile: ClickyProfile) -> some View {
        let jobs = jobStore.jobs(forClickySlug: profile.slug).reversed()
        let liveNoteMarkdown = ClickyWorkFolderFiles.shared.readLiveNote(forSlug: profile.slug)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let messages = filteredChatMessages

        // Intro greeting bubble
        assistantBubbleView(
            text: profile.greeting,
            timestamp: nil,
            artifactPaths: []
        )

        if !liveNoteMarkdown.isEmpty {
            ClickyInkSheetView(
                markdown: liveNoteMarkdown,
                title: "\(profile.name) · Live Note",
                onAction: { actionPrompt in
                    dispatchPromptFromInkOrPill(actionPrompt)
                }
            )
        }

        ForEach(Array(jobs)) { job in
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                userBubbleView(text: job.prompt, timestamp: job.createdAt)

                ClickyArcCard(
                    job: job,
                    onStop: job.outcome == .working ? {
                        companionManager.stopActiveAgentTask(jobID: job.id)
                    } : nil,
                    onOpen: {
                        openPreferredArtifact(for: job)
                    },
                    onFollowUp: { followUpPrompt in
                        dispatchPromptFromInkOrPill(followUpPrompt)
                    },
                    onOpenArtifact: { artifact in
                        windowController.openDocument(atPath: artifact.path)
                    }
                )

                if let replyText = job.replyText, !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantBubbleView(
                        text: replyText,
                        timestamp: job.finishedAt,
                        artifactPaths: job.artifactEntries.map(\.path)
                    )
                } else if let summary = job.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantBubbleView(
                        text: summary,
                        timestamp: job.finishedAt,
                        artifactPaths: job.artifactEntries.map(\.path)
                    )
                } else if !job.artifactEntries.isEmpty {
                    artifactChipsRow(paths: job.artifactEntries.map(\.path))
                }
            }
        }

        ForEach(messages, id: \.id) { message in
            chatMessageBubble(message: message)
        }
    }

    private func chatMessageBubble(message: ClickyChatMessage) -> some View {
        let roleName = String(describing: message.role).lowercased()
        if roleName == "user" {
            return AnyView(
                userBubbleView(text: message.text, timestamp: message.timestamp)
            )
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                NotchActivityLedgerView(activityLines: message.activity)

                if ClickyChatActivityLedger.shouldShowTypingDots(role: message.role, text: message.text) {
                    NotchTypingDotsView()
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .transition(.opacity)
                } else {
                    assistantBubbleView(
                        text: message.text,
                        timestamp: message.timestamp,
                        artifactPaths: message.artifactPaths
                    )
                    .transition(.opacity)
                }

                if let drawingID = message.drawingID {
                    NotchChatDrawingRow(drawingID: drawingID) {
                        companionManager.detachDrawingFromChat(messageID: message.id)
                    }
                    .frame(maxWidth: 580, alignment: .leading)
                }
            }
            .animation(.easeOut(duration: 0.2), value: message.text.isEmpty)
        )
    }

    private func userBubbleView(text: String, timestamp: Date?) -> some View {
        HStack {
            Spacer(minLength: 56)

            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surface3)
                    )

                if let timestamp {
                    Text(Self.shortTimeFormatter.string(from: timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func assistantBubbleView(
        text: String,
        timestamp: Date?,
        artifactPaths: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .frame(maxWidth: 580, alignment: .leading)

            if !artifactPaths.isEmpty {
                artifactChipsRow(paths: artifactPaths)
            }

            if let timestamp {
                Text(Self.shortTimeFormatter.string(from: timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func artifactChipsRow(paths: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(paths, id: \.self) { artifactPath in
                    let fileURL = URL(fileURLWithPath: artifactPath)
                    let isSelectedDoc = windowController.isDocumentColumnVisible
                        && windowController.selectedDocumentURL?.path == fileURL.path

                    Button {
                        windowController.openDocument(atPath: artifactPath)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: iconNameForFileExtension(fileURL.pathExtension))
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.accentText)

                            Text(fileURL.lastPathComponent)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isSelectedDoc ? DS.Colors.accentSubtle : DS.Colors.surface2)
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelectedDoc ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .contextMenu {
                        Button("Open in Document Pane") {
                            windowController.openDocument(atPath: artifactPath)
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                        Button("Open in Default App") {
                            NSWorkspace.shared.open(fileURL)
                        }
                    }
                }
            }
        }
    }

    private func streamingStatusIndicator(label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(DS.Colors.surface2)
        )
    }

    // MARK: - Follow-up Pills & Stop Bar

    private var followUpPrompts: [String] {
        if let profile = selectedProfile {
            if !profile.suggestedAsks.isEmpty {
                return profile.suggestedAsks
            }
            return [
                "What's the latest status?",
                "Summarize your output files",
                "Run a fresh pass"
            ]
        }

        if companionManager.activeDocumentContext != nil {
            return [
                "Summarize this document",
                "Extract key action items",
                "Explain the tricky parts"
            ]
        }

        return [
            "What's on my screen right now?",
            "Help me plan my next step"
        ]
    }

    private var followUpPillsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(followUpPrompts, id: \.self) { promptText in
                    Button {
                        dispatchPromptFromInkOrPill(promptText)
                    } label: {
                        Text(promptText)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.surface2.opacity(0.85))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 7)
        }
    }

    private var activeRunningJobsForSelection: [ClickyJob] {
        if let slug = windowController.selectedSlug {
            return jobStore.activeJobs.filter { job in job.clickySlug == slug }
        }
        return []
    }

    @ViewBuilder
    private var runningTaskStopBar: some View {
        let runningJobs = activeRunningJobsForSelection
        if !runningJobs.isEmpty || !harnessRuntime.activeJobIDs.isEmpty && windowController.selectedSlug != nil {
            HStack(spacing: DS.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)

                Text(runningJobs.first?.title ?? "Agent task running...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                Spacer()

                Button {
                    for job in runningJobs {
                        companionManager.stopActiveAgentTask(jobID: job.id)
                    }
                    for activeThreadID in harnessRuntime.activeJobIDs where runningJobs.isEmpty {
                        Task {
                            try? await harnessRuntime.cancel(jobID: activeThreadID)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(DS.Colors.destructive)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 7)
            .background(DS.Colors.surface2.opacity(0.7))
        }
    }

    // MARK: - Composer

    private var canSendMessage: Bool {
        let trimmed = companionManager.textInputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !attachedFileURLs.isEmpty
    }

    @State private var runAsBackgroundJob = false

    private var composerArea: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if !attachedFileURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedFileURLs, id: \.self) { fileURL in
                            HStack(spacing: 5) {
                                Image(systemName: iconNameForFileExtension(fileURL.pathExtension))
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.accentText)

                                Button {
                                    windowController.openDocument(url: fileURL)
                                } label: {
                                    Text(fileURL.lastPathComponent)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(DS.Colors.textPrimary)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()

                                Button {
                                    attachedFileURLs.removeAll { existing in existing == fileURL }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.surface2)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                            )
                        }
                    }
                }
            }

            ClickyChatComposerBar(
                companionManager: companionManager,
                draftText: $companionManager.textInputDraft,
                placeholder: selectedProfile == nil
                    ? String(localized: "Message Clicky or drop files...")
                    : String(localized: "Message \(selectedProfile?.name ?? "Clicky")..."),
                runAsBackgroundJob: $runAsBackgroundJob,
                // Messages to a selected Clicky always run as its job, so the toggle would do nothing.
                showsBackgroundJobToggle: selectedProfile == nil,
                canSubmitWithoutText: !attachedFileURLs.isEmpty,
                onAttach: { presentFilePicker() },
                onStop: { companionManager.stopCurrentTurnFromChat() },
                onSubmit: { submitComposer(asBackgroundTask: runAsBackgroundJob || selectedProfile != nil) },
                isInputFocused: $isComposerFocused
            )
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 10)
        .background(
            isDropTargeted
                ? DS.Colors.accentSubtle
                : DS.Colors.surface1.opacity(0.60)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(isDropTargeted ? DS.Colors.accent : Color.clear, lineWidth: 1.5)
                .padding(4)
        )
        .overlay {
            if isDropTargeted {
                Text("Drop to attach")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedFileProviders(providers)
        }
    }

    // MARK: - Actions & Helpers

    private func submitComposer(asBackgroundTask: Bool) {
        let composedPrompt = buildComposedPrompt(
            rawText: companionManager.textInputDraft,
            attachments: attachedFileURLs
        )
        guard !composedPrompt.isEmpty else { return }

        companionManager.textInputDraft = ""
        attachedFileURLs = []

        if asBackgroundTask {
            let targetSlug = windowController.selectedSlug ?? "research-buddy"
            companionManager.startBackgroundAgentTask(prompt: composedPrompt, clickySlug: targetSlug)
            if windowController.selectedSlug == nil {
                windowController.selectThread(slug: targetSlug)
            }
        } else {
            companionManager.submitTextPrompt(composedPrompt, clickySlug: windowController.selectedSlug)
        }
    }

    private func dispatchPromptFromInkOrPill(_ promptText: String) {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let slug = windowController.selectedSlug {
            companionManager.startBackgroundAgentTask(prompt: trimmed, clickySlug: slug)
        } else {
            companionManager.submitTextPrompt(trimmed, clickySlug: nil)
        }
    }

    private func buildComposedPrompt(rawText: String, attachments: [URL]) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return trimmed }

        let attachmentPathsBlock = attachments
            .map { "- \($0.path)" }
            .joined(separator: "\n")

        if trimmed.isEmpty {
            return "Please inspect these attached files:\n\(attachmentPathsBlock)"
        }
        return "\(trimmed)\n\nAttached files:\n\(attachmentPathsBlock)"
    }

    private func presentFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.title = "Attach Files"

        if openPanel.runModal() == .OK {
            for selectedURL in openPanel.urls where !attachedFileURLs.contains(selectedURL) {
                attachedFileURLs.append(selectedURL)
            }
            if let firstURL = openPanel.urls.first {
                windowController.openDocument(url: firstURL)
            }
        }
    }

    private func handleDroppedFileProviders(_ providers: [NSItemProvider]) -> Bool {
        var didAcceptAny = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            didAcceptAny = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let url = item as? URL {
                    resolvedURL = url
                } else if let data = item as? Data,
                          let pathString = String(data: data, encoding: .utf8) {
                    resolvedURL = URL(string: pathString)
                } else {
                    resolvedURL = nil
                }

                guard let resolvedURL else { return }
                Task { @MainActor in
                    if !attachedFileURLs.contains(resolvedURL) {
                        attachedFileURLs.append(resolvedURL)
                    }
                    windowController.openDocument(url: resolvedURL)
                }
            }
        }
        return didAcceptAny
    }

    private func openPreferredArtifact(for job: ClickyJob) {
        if let firstArtifact = job.latestReplyArtifactEntries.first ?? job.artifactEntries.first {
            windowController.openDocument(atPath: firstArtifact.path)
            return
        }
        let noteURL = ClickyWorkFolderFiles.shared.noteMarkdownURL(forSlug: job.clickySlug)
        if FileManager.default.fileExists(atPath: noteURL.path) {
            windowController.openDocument(url: noteURL)
            return
        }
        let reportURL = ClickyWorkFolderFiles.shared.reportMarkdownURL(forSlug: job.clickySlug)
        if FileManager.default.fileExists(atPath: reportURL.path) {
            windowController.openDocument(url: reportURL)
        }
    }

    private func iconNameForFileExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "md", "markdown": return "doc.richtext"
        case "pdf": return "doc.text.fill"
        case "csv", "tsv", "xlsx": return "tablecells"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "swift", "py", "js", "ts", "json", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

// MARK: - Split Resize Cursor Bridge

private final class SplitHorizontalResizeCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct SplitHorizontalResizeCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SplitHorizontalResizeCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - New Clicky Creation Sheet

private struct NewClickySheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var clickyName: String = ""
    @State private var roleText: String = ""
    @State private var oneLiner: String = ""
    @State private var initialAsk: String = ""
    @State private var selectedProp: ClickyAgentProp = .sparkle

    let onCreated: (ClickyProfile) -> Void

    private var isCreateEnabled: Bool {
        !clickyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                ClickyAgentIconView(
                    agentKey: clickyName.isEmpty ? "new-clicky" : clickyName.lowercased(),
                    title: clickyName.isEmpty ? "New Clicky" : clickyName,
                    prop: selectedProp,
                    baseHue: 0.56,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("New Clicky")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Create a persistent specialist agent with its own workspace & memory.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                sheetField(label: "Name", placeholder: "e.g., Deal Scout", text: $clickyName)
                sheetField(label: "Role", placeholder: "e.g., Sales & competitive analyst", text: $roleText)
                sheetField(label: "What it does", placeholder: "One-line specialty description", text: $oneLiner)
                sheetField(label: "Suggested first ask (optional)", placeholder: "e.g., Audit our pricing page vs top 3 rivals", text: $initialAsk)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon Prop")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ClickyAgentProp.allCases) { prop in
                            let isChosen = selectedProp == prop
                            Button {
                                selectedProp = prop
                            } label: {
                                Image(systemName: prop.systemImageName)
                                    .font(.system(size: 13))
                                    .foregroundColor(isChosen ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                                    .frame(width: 30, height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                            .fill(isChosen ? DS.Colors.accent : DS.Colors.surface2)
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .dsSecondaryButtonStyle(isFullWidth: false)

                Button("Create Clicky") {
                    let trimmedName = clickyName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedRole = roleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedOneLiner = oneLiner.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedAsk = initialAsk.trimmingCharacters(in: .whitespacesAndNewlines)

                    let created = ClickyRoster.shared.createClicky(
                        name: trimmedName,
                        roleText: trimmedRole.isEmpty ? "Specialist" : trimmedRole,
                        oneLiner: trimmedOneLiner.isEmpty ? "Helps with recurring tasks and notes." : trimmedOneLiner,
                        prop: selectedProp,
                        suggestedAsks: trimmedAsk.isEmpty ? [] : [trimmedAsk]
                    )
                    onCreated(created)
                    dismiss()
                }
                .dsPrimaryButtonStyle(isFullWidth: false)
                .disabled(!isCreateEnabled)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 440)
        .background(DS.Colors.surface1)
    }

    private func sheetField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }
}
