//
//  HomeSpaceView.swift
//  leanring-buddy
//
//  HeyClicky's Home Space: quick task launcher, active & recent ClickyArcCards,
//  starter and user-created Clickys from ClickyRoster.shared, active routines
//  summary from ClickyRoutineScheduler.shared, and ClickyInk live note viewer.
//

import AppKit
import Combine
import Foundation
import SwiftUI

public struct HomeSpaceView: View {
    @ObservedObject public var companionManager: CompanionManager
    public let onOpenSettings: (() -> Void)?

    @ObservedObject private var roster = ClickyRoster.shared
    @ObservedObject private var jobStore = ClickyJobStore.shared
    @ObservedObject private var routineScheduler = ClickyRoutineScheduler.shared

    @State private var quickPromptText: String = ""
    @State private var selectedClickySlug: String = "research-buddy"
    @State private var selectedJobFilter: JobFilter = .all
    @State private var isShowingCreateClickySheet: Bool = false
    @State private var inspectedNoteSlug: String?
    @State private var hoveredClickySlug: String?
    @State private var hoveredRoutineID: String?

    public enum JobFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case needsYou = "Needs You"
        case done = "Done"

        public var id: String { rawValue }
    }

    public init(
        companionManager: CompanionManager,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.companionManager = companionManager
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                homeHeader
                quickTaskLauncherCard
                jobsSection
                clickyRosterSection
                routinesSummarySection
                liveNotePreviewSection
            }
            .padding(DS.Spacing.xl)
        }
        .background(DS.Colors.background)
        .onAppear {
            ensureValidSelectedSlug()
        }
        .onChange(of: roster.clickys) { _, _ in
            ensureValidSelectedSlug()
        }
        .sheet(isPresented: $isShowingCreateClickySheet) {
            CreateClickySheet { createdProfile in
                selectedClickySlug = createdProfile.slug
            }
        }
        .sheet(
            isPresented: Binding(
                get: { inspectedNoteSlug != nil },
                set: { shouldShow in
                    if !shouldShow {
                        inspectedNoteSlug = nil
                    }
                }
            )
        ) {
            if let noteSlug = inspectedNoteSlug {
                LiveNoteModalSheet(
                    clickySlug: noteSlug,
                    clickyName: roster.clicky(forSlug: noteSlug)?.name ?? noteSlug,
                    onClose: {
                        inspectedNoteSlug = nil
                    },
                    onAction: { actionPrompt in
                        inspectedNoteSlug = nil
                        launchChatPrompt(actionPrompt, clickySlug: noteSlug)
                    }
                )
            }
        }
    }

    // MARK: - Header

    private var homeHeader: some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Home Space")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Launch tasks, check active Clickys, and manage your routines.")
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if jobStore.unreadCount > 0 {
                HStack(spacing: 5) {
                    Circle()
                        .fill(DS.Colors.blue400)
                        .frame(width: 7, height: 7)
                    Text("\(jobStore.unreadCount) unread")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.Colors.blue500.opacity(0.14)))
                .overlay(Capsule().stroke(DS.Colors.blue400.opacity(0.35), lineWidth: 1))
            }

            Button(action: {
                if let onOpenSettings {
                    onOpenSettings()
                } else {
                    HeyClickyWindowController.shared.open(
                        selectedSlug: selectedClickySlug,
                        initialTab: .settings
                    )
                }
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .dsIconButtonStyle(size: 32, tooltip: "Settings", tooltipAlignment: .trailing)
        }
    }

    // MARK: - Quick Task Launcher

    private var quickTaskLauncherCard: some View {
        let activeProfile = selectedProfile

        return VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                if let activeProfile {
                    ClickyAgentIconView(
                        agentKey: activeProfile.slug,
                        title: activeProfile.name,
                        mood: moodForClicky(activeProfile),
                        prop: activeProfile.prop,
                        baseHue: activeProfile.baseHue,
                        size: 32
                    )
                }

                Text("Quick Task Launcher")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                if let documentContext = companionManager.activeDocumentContext {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(DS.Colors.info)
                        Text(documentContext.reference.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.surface2))
                    .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 1))
                }
            }

            // Clicky target picker row
            if !roster.clickys.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(roster.clickys) { profile in
                            let isSelected = profile.slug == selectedClickySlug
                            Button(action: {
                                withAnimation(.easeOut(duration: DS.Animation.fast)) {
                                    selectedClickySlug = profile.slug
                                }
                            }) {
                                HStack(spacing: 6) {
                                    ClickyAgentIconView(
                                        agentKey: profile.slug,
                                        title: profile.name,
                                        mood: moodForClicky(profile),
                                        prop: profile.prop,
                                        baseHue: profile.baseHue,
                                        size: 20
                                    )
                                    Text(profile.name)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                        .foregroundColor(isSelected ? .white : DS.Colors.textSecondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? DS.Colors.accent.opacity(0.28) : DS.Colors.surface2)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? DS.Colors.blue400 : DS.Colors.borderSubtle, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                }
            }

            // Prompt input box
            HStack(spacing: DS.Spacing.sm) {
                TextField(
                    "Ask \(activeProfile?.name ?? "Clicky") to research, build, or automate something…",
                    text: $quickPromptText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .onSubmit {
                    launchBackgroundTaskFromLauncher()
                }
            }
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                    .fill(DS.Colors.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                    .stroke(DS.Colors.borderStrong, lineWidth: 1)
            )

            // Suggested asks for the selected Clicky
            if let suggestions = activeProfile?.suggestedAsks, !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(action: {
                                quickPromptText = suggestion
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10))
                                        .foregroundColor(DS.Colors.accentText)
                                    Text(suggestion)
                                        .font(.system(size: 11.5))
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(DS.Colors.surface2))
                                .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.9))
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                Spacer()

                Button(action: {
                    let trimmed = quickPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    quickPromptText = ""
                    launchChatPrompt(trimmed, clickySlug: selectedClickySlug)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Open in Chat")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(DS.Colors.surface2))
                    .overlay(Capsule().stroke(DS.Colors.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: !isQuickPromptEmpty)
                .disabled(isQuickPromptEmpty)
                .opacity(isQuickPromptEmpty ? 0.5 : 1.0)

                Button(action: launchBackgroundTaskFromLauncher) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Run Task")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: !isQuickPromptEmpty)
                .disabled(isQuickPromptEmpty)
                .opacity(isQuickPromptEmpty ? 0.5 : 1.0)
            }
        }
        .padding(DS.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Active & Recent Arc Cards

    private var jobsSection: some View {
        let filteredJobs = filteredVisibleJobs

        return VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.md) {
                Text("Active & Recent Work")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(JobFilter.allCases) { filterOption in
                        let isSelected = selectedJobFilter == filterOption
                        let count = jobCount(for: filterOption)
                        Button(action: {
                            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                                selectedJobFilter = filterOption
                            }
                        }) {
                            HStack(spacing: 4) {
                                Text(filterOption.rawValue)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundColor(isSelected ? .white : DS.Colors.textTertiary)
                                }
                            }
                            .foregroundColor(isSelected ? .white : DS.Colors.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(isSelected ? DS.Colors.accent : DS.Colors.surface1)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? DS.Colors.blue400 : DS.Colors.borderSubtle, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }

            if filteredJobs.isEmpty {
                emptyJobsView
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: DS.Spacing.md)],
                    spacing: DS.Spacing.md
                ) {
                    ForEach(filteredJobs) { jobItem in
                        ClickyArcCard(
                            job: jobItem,
                            onStop: {
                                companionManager.stopActiveAgentTask(jobID: jobItem.id)
                            },
                            onOpen: {
                                ClickyJobStore.shared.markSeen(jobID: jobItem.id)
                                HeyClickyWindowController.shared.open(
                                    selectedSlug: jobItem.clickySlug,
                                    initialTab: .chat
                                )
                            },
                            onFollowUp: { followUpText in
                                launchChatPrompt(followUpText, clickySlug: jobItem.clickySlug)
                            }
                        )
                    }
                }
            }
        }
    }

    private var emptyJobsView: some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 20))
                .foregroundColor(DS.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedJobFilter == .all ? "No background tasks yet" : "No tasks in \"\(selectedJobFilter.rawValue)\"")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Launch a task above or click any Clicky below to start working together.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()
        }
        .padding(DS.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Starter & User-Created Clickys

    private var clickyRosterSection: some View {
        let starterClickys = roster.clickys.filter(\.isStarterDefault)
        let customClickys = roster.clickys.filter { !$0.isStarterDefault }

        return VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("Your Clickys")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("\(roster.clickys.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.surface2))

                Spacer()

                Button(action: {
                    isShowingCreateClickySheet = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("New Clicky")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill(DS.Colors.blue500.opacity(0.14)))
                    .overlay(Capsule().stroke(DS.Colors.blue400.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if !starterClickys.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("STARTER CLICKYS")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .tracking(0.6)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: DS.Spacing.md)],
                        spacing: DS.Spacing.md
                    ) {
                        ForEach(starterClickys) { profile in
                            clickyProfileCard(profile)
                        }
                    }
                }
            }

            if !customClickys.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("CREATED BY YOU")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .tracking(0.6)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: DS.Spacing.md)],
                        spacing: DS.Spacing.md
                    ) {
                        ForEach(customClickys) { profile in
                            clickyProfileCard(profile)
                        }
                    }
                }
            }
        }
    }

    private func clickyProfileCard(_ profile: ClickyProfile) -> some View {
        let isHovered = hoveredClickySlug == profile.slug
        let latestJob = jobStore.jobs(forClickySlug: profile.slug).first
        let latestActivity = latestJob?.finishedAt ?? latestJob?.createdAt
        let hasUnread = roster.isUnread(slug: profile.slug, latestActivityAt: latestActivity)
        let hasLiveNote = !ClickyWorkFolderFiles.shared.readLiveNote(forSlug: profile.slug)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                ClickyAgentIconView(
                    agentKey: profile.slug,
                    title: profile.name,
                    mood: moodForClicky(profile),
                    prop: profile.prop,
                    baseHue: profile.baseHue,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)

                        if hasUnread {
                            Circle()
                                .fill(DS.Colors.blue400)
                                .frame(width: 7, height: 7)
                        }
                    }

                    Text(profile.roleText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                        .lineLimit(1)
                }

                Spacer()

                if hasLiveNote {
                    Button(action: {
                        inspectedNoteSlug = profile.slug
                    }) {
                        Image(systemName: "note.text")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(DS.Colors.warningText)
                            .padding(6)
                            .background(Circle().fill(DS.Colors.warning.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .nativeTooltip("Open Live Note")
                }
            }

            Text(profile.oneLiner)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DS.Spacing.sm) {
                Text(profile.isStarterDefault ? "Starter" : "Custom")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(DS.Colors.surface2))

                Spacer()

                HStack(spacing: 4) {
                    Text("Open chat")
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(isHovered ? DS.Colors.blue300 : DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(isHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge))
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                hoveredClickySlug = hovering ? profile.slug : (hoveredClickySlug == profile.slug ? nil : hoveredClickySlug)
            }
        }
        .onTapGesture {
            openClickyWindow(slug: profile.slug)
        }
    }

    // MARK: - Active Routines Summary

    private var routinesSummarySection: some View {
        let armedRoutines = routineScheduler.routines.filter { !$0.isPaused }
        let pausedRoutines = routineScheduler.routines.filter(\.isPaused)

        return VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                Text("Active Routines")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("\(armedRoutines.count) armed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(armedRoutines.isEmpty ? DS.Colors.textTertiary : DS.Colors.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill((armedRoutines.isEmpty ? DS.Colors.surface2 : DS.Colors.success.opacity(0.14)))
                    )

                if !pausedRoutines.isEmpty {
                    Text("\(pausedRoutines.count) paused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(DS.Colors.surface2))
                }

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(routineScheduler.isNetworkAvailable ? DS.Colors.success : DS.Colors.warning)
                        .frame(width: 6.5, height: 6.5)
                    Text(routineScheduler.isNetworkAvailable ? "Online" : "Waiting for network")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            if routineScheduler.routines.isEmpty {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("No scheduled routines yet. Ask any Clicky to run a task on a schedule.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 1)
                )
            } else {
                VStack(spacing: DS.Spacing.sm) {
                    ForEach(routineScheduler.routines) { routine in
                        routineRowCard(routine)
                    }
                }
            }
        }
    }

    private func routineRowCard(_ routine: ClickyRoutine) -> some View {
        let isHovered = hoveredRoutineID == routine.id
        let clickySlug = routine.clickySlug ?? "research-buddy"
        let clickyName = roster.clicky(forSlug: clickySlug)?.name ?? clickySlug

        return HStack(spacing: DS.Spacing.md) {
            Image(systemName: routine.isPaused ? "pause.circle.fill" : "clock.badge.checkmark.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(routine.isPaused ? DS.Colors.textTertiary : DS.Colors.success)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(routine.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)

                    Text("· \(clickyName)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                }

                HStack(spacing: 8) {
                    Text(routine.cadenceLabel)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)

                    if let nextRunAt = routine.nextRunAt, !routine.isPaused {
                        Text("Next \(nextRunAt, style: .relative)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    if routine.lastRunFailed {
                        Text("Last run failed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.destructiveText)
                    }
                }
            }

            Spacer()

            Button(action: {
                Task {
                    await routineScheduler.runNow(id: routine.id)
                }
            }) {
                Text("Run Now")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.blue500.opacity(0.12)))
                    .overlay(Capsule().stroke(DS.Colors.blue400.opacity(0.35), lineWidth: 0.9))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                routineScheduler.togglePause(id: routine.id)
            }) {
                Text(routine.isPaused ? "Resume" : "Pause")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.surface2))
                    .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.9))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(isHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large))
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                hoveredRoutineID = hovering ? routine.id : (hoveredRoutineID == routine.id ? nil : hoveredRoutineID)
            }
        }
        .onTapGesture {
            openClickyWindow(slug: clickySlug)
        }
    }

    // MARK: - Live Note Preview

    private var liveNotePreviewSection: some View {
        let noteContent = ClickyWorkFolderFiles.shared.readLiveNote(forSlug: selectedClickySlug)
        let activeName = selectedProfile?.name ?? selectedClickySlug

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("Live Note · \(activeName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button(action: {
                    inspectedNoteSlug = selectedClickySlug
                }) {
                    HStack(spacing: 4) {
                        Text("Expand")
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.accentText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            ClickyInkSheetView(
                markdown: noteContent,
                title: "\(activeName) Note",
                onAction: { actionPrompt in
                    launchChatPrompt(actionPrompt, clickySlug: selectedClickySlug)
                }
            )
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                    .fill(DS.Colors.surface1.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }

    // MARK: - Helpers

    private var selectedProfile: ClickyProfile? {
        roster.activeClicky(forSlug: selectedClickySlug) ?? roster.clickys.first
    }

    private var isQuickPromptEmpty: Bool {
        quickPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredVisibleJobs: [ClickyJob] {
        let visible = jobStore.visibleJobs
        switch selectedJobFilter {
        case .all:
            return visible
        case .active:
            return visible.filter { job in job.railPhase == .working || job.railPhase == .queued }
        case .needsYou:
            return visible.filter { job in job.railPhase == .needsYou }
        case .done:
            return visible.filter { job in job.railPhase == .done || job.railPhase == .failed || job.railPhase == .stopped }
        }
    }

    private func jobCount(for filterOption: JobFilter) -> Int {
        let visible = jobStore.visibleJobs
        switch filterOption {
        case .all:
            return visible.count
        case .active:
            return visible.filter { job in job.railPhase == .working || job.railPhase == .queued }.count
        case .needsYou:
            return visible.filter { job in job.railPhase == .needsYou }.count
        case .done:
            return visible.filter { job in job.railPhase == .done || job.railPhase == .failed || job.railPhase == .stopped }.count
        }
    }

    private func moodForClicky(_ profile: ClickyProfile) -> ClickyAgentMood {
        let slugJobs = jobStore.jobs(forClickySlug: profile.slug)
        if slugJobs.contains(where: { job in job.railPhase == .needsYou }) {
            return .needsYou
        }
        if slugJobs.contains(where: { job in job.railPhase == .working || job.railPhase == .queued }) {
            return .working
        }
        if let latest = slugJobs.first {
            switch latest.railPhase {
            case .failed:
                return .failed
            case .done:
                return .happy
            case .stopped:
                return .sleepy
            case .queued, .working, .needsYou:
                return .working
            }
        }
        return .idle
    }

    private func ensureValidSelectedSlug() {
        if roster.activeClicky(forSlug: selectedClickySlug) == nil,
           let firstClicky = roster.clickys.first {
            selectedClickySlug = firstClicky.slug
        }
    }

    private func launchBackgroundTaskFromLauncher() {
        let trimmed = quickPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        quickPromptText = ""
        companionManager.startBackgroundAgentTask(prompt: trimmed, clickySlug: selectedClickySlug)
    }

    private func launchChatPrompt(_ prompt: String, clickySlug: String) {
        roster.markRead(slug: clickySlug)
        companionManager.submitTextPrompt(prompt, clickySlug: clickySlug)
        HeyClickyWindowController.shared.open(
            selectedSlug: clickySlug,
            initialTab: .chat
        )
    }

    private func openClickyWindow(slug: String) {
        roster.markRead(slug: slug)
        HeyClickyWindowController.shared.open(
            selectedSlug: slug,
            initialTab: .chat
        )
    }
}

// MARK: - Live Note Modal Sheet

private struct LiveNoteModalSheet: View {
    let clickySlug: String
    let clickyName: String
    let onClose: () -> Void
    let onAction: (String) -> Void

    var body: some View {
        let noteMarkdown = ClickyWorkFolderFiles.shared.readLiveNote(forSlug: clickySlug)

        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("\(clickyName) Live Note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .dsIconButtonStyle(size: 28, tooltip: "Close", tooltipAlignment: .trailing)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            ScrollView {
                ClickyInkSheetView(
                    markdown: noteMarkdown,
                    title: nil,
                    onAction: onAction
                )
            }
        }
        .padding(DS.Spacing.xl)
        .frame(minWidth: 520, minHeight: 420)
        .background(DS.Colors.background)
    }
}

// MARK: - Create Clicky Sheet

private struct CreateClickySheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreated: (ClickyProfile) -> Void

    @State private var nameInput: String = ""
    @State private var roleInput: String = ""
    @State private var oneLinerInput: String = ""
    @State private var selectedProp: ClickyAgentProp = .sparkle
    @State private var selectedHue: Double = 0.56

    private let hueOptions: [Double] = [0.56, 0.38, 0.08, 0.78, 0.92, 0.14]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            HStack(spacing: DS.Spacing.md) {
                ClickyAgentIconView(
                    agentKey: nameInput.isEmpty ? "new-clicky" : nameInput,
                    title: nameInput,
                    mood: .happy,
                    prop: selectedProp,
                    baseHue: selectedHue,
                    size: 48
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a New Clicky")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Give your companion a name, role, and workspace.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                labeledField("Name", placeholder: "e.g. Inbox Scout", text: $nameInput)
                labeledField("Role", placeholder: "e.g. Email Triage Helper", text: $roleInput)
                labeledField("What they do", placeholder: "Short description of how they help you", text: $oneLinerInput)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Color")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                HStack(spacing: 10) {
                    ForEach(hueOptions, id: \.self) { hueOption in
                        let isSelected = abs(selectedHue - hueOption) < 0.01
                        Button(action: {
                            selectedHue = hueOption
                        }) {
                            Circle()
                                .fill(Color(hue: hueOption, saturation: 0.65, brightness: 0.88))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: isSelected ? 2.5 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Badge Icon")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 10),
                    spacing: 6
                ) {
                    ForEach(ClickyAgentProp.allCases) { propOption in
                        let isSelected = selectedProp == propOption
                        Button(action: {
                            selectedProp = propOption
                        }) {
                            Image(systemName: propOption.systemImageName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isSelected ? .white : DS.Colors.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                                        .fill(isSelected ? DS.Colors.accent : DS.Colors.surface2)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
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
                    let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedRole = roleInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedOneLiner = oneLinerInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let createdProfile = ClickyRoster.shared.createClicky(
                        name: trimmedName,
                        roleText: resolvedRole.isEmpty ? "Assistant" : resolvedRole,
                        oneLiner: resolvedOneLiner.isEmpty ? "Helps out with tasks in its own workspace." : resolvedOneLiner,
                        baseHue: selectedHue,
                        prop: selectedProp
                    )
                    onCreated(createdProfile)
                    dismiss()
                }
                .dsPrimaryButtonStyle(isFullWidth: false)
                .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 440)
        .background(DS.Colors.background)
    }

    private func labeledField(
        _ label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }
}
