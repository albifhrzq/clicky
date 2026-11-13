//
//  ClickyArcCard.swift
//  leanring-buddy
//
//  Arc job card displaying live status, segmented Aqua gel progress track,
//  interactive artifact file chips, elapsed time, and Stop / Open / Follow-up actions.
//

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - ClickyArcCard

public struct ClickyArcCard: View {
    public let job: ClickyJob
    public let onStop: (() -> Void)?
    public let onOpen: (() -> Void)?
    public let planSteps: [AgentPlanStep]
    public let onFollowUp: ((String) -> Void)?
    public let onOpenArtifact: ((ClickyJobArtifactEntry) -> Void)?

    @ObservedObject private var roster = ClickyRoster.shared

    public init(
        job: ClickyJob,
        onStop: (() -> Void)? = nil,
        onOpen: (() -> Void)? = nil,
        planSteps: [AgentPlanStep] = [],
        onFollowUp: ((String) -> Void)? = nil,
        onOpenArtifact: ((ClickyJobArtifactEntry) -> Void)? = nil
    ) {
        self.job = job
        self.onStop = onStop
        self.onOpen = onOpen
        self.planSteps = planSteps
        self.onFollowUp = onFollowUp
        self.onOpenArtifact = onOpenArtifact
    }

    public var body: some View {
        ClickyResultCardFace(
            job: job,
            profile: roster.clicky(forSlug: job.clickySlug),
            planSteps: planSteps,
            onStop: onStop,
            onOpen: onOpen,
            onFollowUp: onFollowUp,
            onOpenArtifact: onOpenArtifact
        )
    }
}

// MARK: - ClickyArcGelTrack

public struct ClickyArcGelTrack: View {
    public enum SegmentState: Equatable, Sendable {
        case completed
        case active
        case needsYou
        case failed
        case pending
    }

    public let segmentStates: [SegmentState]

    @State private var shimmerPhase: Bool = false

    public init(segmentStates: [SegmentState]) {
        self.segmentStates = segmentStates.isEmpty ? [.pending] : segmentStates
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(segmentStates.enumerated()), id: \.offset) { _, segmentState in
                gelSegmentView(for: segmentState)
            }
        }
        .frame(height: 10)
        .onAppear {
            if segmentStates.contains(.active) || segmentStates.contains(.needsYou) {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    shimmerPhase = true
                }
            }
        }
        .onChange(of: segmentStates) { _, updatedStates in
            if updatedStates.contains(.active) || updatedStates.contains(.needsYou) {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    shimmerPhase = true
                }
            } else {
                shimmerPhase = false
            }
        }
    }

    private func gelSegmentView(for segmentState: SegmentState) -> some View {
        let baseColors = gradientColors(for: segmentState)
        let isAnimated = segmentState == .active || segmentState == .needsYou

        return Capsule()
            .fill(
                LinearGradient(
                    colors: baseColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                // Classic Aqua top specular gloss highlight
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(segmentState == .pending ? 0.06 : 0.55),
                                Color.white.opacity(segmentState == .pending ? 0.02 : 0.14),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .padding(1.2)
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(for: segmentState),
                        lineWidth: 0.75
                    )
            )
            .opacity(isAnimated ? (shimmerPhase ? 1.0 : 0.68) : 1.0)
            .shadow(
                color: segmentState == .active
                    ? DS.Colors.blue400.opacity(shimmerPhase ? 0.45 : 0.18)
                    : Color.clear,
                radius: 4
            )
    }

    private func gradientColors(for segmentState: SegmentState) -> [Color] {
        switch segmentState {
        case .completed:
            return [Color(hex: "#6EE7B7"), DS.Colors.success]
        case .active:
            return [DS.Colors.blue300, DS.Colors.blue600]
        case .needsYou:
            return [Color(hex: "#FDE68A"), DS.Colors.warning]
        case .failed:
            return [DS.Colors.destructiveText, DS.Colors.destructive]
        case .pending:
            return [DS.Colors.surface3, DS.Colors.surface2]
        }
    }

    private func borderColor(for segmentState: SegmentState) -> Color {
        switch segmentState {
        case .completed:
            return DS.Colors.success.opacity(0.65)
        case .active:
            return DS.Colors.blue300.opacity(0.80)
        case .needsYou:
            return DS.Colors.warning.opacity(0.80)
        case .failed:
            return DS.Colors.destructive.opacity(0.75)
        case .pending:
            return DS.Colors.borderSubtle.opacity(0.6)
        }
    }
}

// MARK: - ClickyArcPlan

public struct ClickyArcPlan: View {
    public let phase: ClickyJobRailPhase
    public let planSteps: [AgentPlanStep]

    @State private var isExpanded: Bool = false

    public init(phase: ClickyJobRailPhase, planSteps: [AgentPlanStep] = []) {
        self.phase = phase
        self.planSteps = planSteps
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Spacing.sm) {
                Text(headlineLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                Spacer()

                if !planSteps.isEmpty {
                    Button(action: {
                        withAnimation(.easeOut(duration: DS.Animation.fast)) {
                            isExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Text("\(completedStepCount)/\(planSteps.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            ClickyArcGelTrack(segmentStates: resolvedSegmentStates)

            if isExpanded && !planSteps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(planSteps.enumerated()), id: \.offset) { _, planStep in
                        HStack(spacing: 6) {
                            Image(systemName: stepIconName(for: planStep.status))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(stepTintColor(for: planStep.status))
                            Text(planStep.step)
                                .font(.system(size: 11.5))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var completedStepCount: Int {
        planSteps.filter { stepItem in
            let normalized = stepItem.status.lowercased()
            return normalized == "completed" || normalized == "done"
        }.count
    }

    private var headlineLabel: String {
        if let activeStep = planSteps.first(where: { stepItem in
            let normalized = stepItem.status.lowercased()
            return normalized == "in_progress" || normalized == "working" || normalized == "active"
        }) {
            return activeStep.step
        }

        if !planSteps.isEmpty {
            switch phase {
            case .done:
                return "Completed all \(planSteps.count) steps"
            case .failed:
                return "Stopped with error"
            case .needsYou:
                return "Waiting for your input"
            case .stopped:
                return "Paused by you"
            case .queued, .working:
                return "\(completedStepCount) of \(planSteps.count) steps complete"
            }
        }

        switch phase {
        case .queued:
            return "Queued to start"
        case .working:
            return "Working through task…"
        case .needsYou:
            return "Needs a quick hand from you"
        case .done:
            return "Finished"
        case .failed:
            return "Ran into an issue"
        case .stopped:
            return "Stopped"
        }
    }

    private var resolvedSegmentStates: [ClickyArcGelTrack.SegmentState] {
        if !planSteps.isEmpty {
            return planSteps.map { stepItem in
                switch stepItem.status.lowercased() {
                case "completed", "done":
                    return .completed
                case "in_progress", "working", "active":
                    return phase == .needsYou ? .needsYou : .active
                case "failed", "error":
                    return .failed
                default:
                    return .pending
                }
            }
        }

        switch phase {
        case .queued:
            return [.active, .pending, .pending, .pending]
        case .working:
            return [.completed, .active, .pending, .pending]
        case .needsYou:
            return [.completed, .needsYou, .pending, .pending]
        case .done:
            return [.completed, .completed, .completed, .completed]
        case .failed:
            return [.completed, .failed, .pending, .pending]
        case .stopped:
            return [.completed, .pending, .pending, .pending]
        }
    }

    private func stepIconName(for status: String) -> String {
        switch status.lowercased() {
        case "completed", "done":
            return "checkmark.circle.fill"
        case "in_progress", "working", "active":
            return "circle.dotted.circle"
        case "failed", "error":
            return "exclamationmark.circle.fill"
        default:
            return "circle"
        }
    }

    private func stepTintColor(for status: String) -> Color {
        switch status.lowercased() {
        case "completed", "done":
            return DS.Colors.success
        case "in_progress", "working", "active":
            return DS.Colors.blue400
        case "failed", "error":
            return DS.Colors.destructiveText
        default:
            return DS.Colors.textTertiary
        }
    }
}

// MARK: - ClickyArcFileChip

public struct ClickyArcFileChip: View {
    public let entry: ClickyJobArtifactEntry
    public let clickySlug: String
    public let onOpenArtifact: ((ClickyJobArtifactEntry) -> Void)?

    @State private var isHovered: Bool = false

    public init(
        entry: ClickyJobArtifactEntry,
        clickySlug: String,
        onOpenArtifact: ((ClickyJobArtifactEntry) -> Void)? = nil
    ) {
        self.entry = entry
        self.clickySlug = clickySlug
        self.onOpenArtifact = onOpenArtifact
    }

    public var body: some View {
        Button(action: openArtifact) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(iconTint)

                Text(entry.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                if let formattedSize {
                    Text(formattedSize)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Image(systemName: entry.isLink ? "arrow.up.right" : "eye")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                    .fill(isHovered ? DS.Colors.surface3 : DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                    .stroke(isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(entry.path)
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                isHovered = hovering
            }
        }
    }

    private var iconName: String {
        if entry.isLink {
            return "link"
        }
        let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt":
            return "doc.text.fill"
        case "pdf":
            return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            return "photo.fill"
        case "csv", "xlsx", "xls", "numbers":
            return "tablecells.fill"
        case "html", "css", "js", "ts", "swift", "py", "json":
            return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz":
            return "archivebox.fill"
        default:
            return "doc.fill"
        }
    }

    private var iconTint: Color {
        if entry.isLink {
            return DS.Colors.info
        }
        let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt":
            return DS.Colors.blue400
        case "pdf":
            return DS.Colors.destructiveText
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            return Color(hex: "#F472B6")
        case "csv", "xlsx", "xls", "numbers":
            return DS.Colors.success
        default:
            return DS.Colors.accentText
        }
    }

    private var formattedSize: String? {
        guard let byteCount = entry.byteCount, byteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func openArtifact() {
        if let onOpenArtifact {
            onOpenArtifact(entry)
            return
        }

        if entry.isLink, let webURL = URL(string: entry.path), webURL.scheme != nil {
            NSWorkspace.shared.open(webURL)
            return
        }

        HeyClickyWindowController.shared.open(
            selectedSlug: clickySlug,
            documentPath: entry.path,
            initialTab: .document
        )
    }
}

// MARK: - ClickyResultCardFace

public struct ClickyResultCardFace: View {
    public let job: ClickyJob
    public let profile: ClickyProfile?
    public let planSteps: [AgentPlanStep]
    public let onStop: (() -> Void)?
    public let onOpen: (() -> Void)?
    public let onFollowUp: ((String) -> Void)?
    public let onOpenArtifact: ((ClickyJobArtifactEntry) -> Void)?

    @State private var isCardHovered: Bool = false
    @State private var isFollowUpComposerVisible: Bool = false
    @State private var followUpDraft: String = ""

    public init(
        job: ClickyJob,
        profile: ClickyProfile? = nil,
        planSteps: [AgentPlanStep] = [],
        onStop: (() -> Void)? = nil,
        onOpen: (() -> Void)? = nil,
        onFollowUp: ((String) -> Void)? = nil,
        onOpenArtifact: ((ClickyJobArtifactEntry) -> Void)? = nil
    ) {
        self.job = job
        self.profile = profile
        self.planSteps = planSteps
        self.onStop = onStop
        self.onOpen = onOpen
        self.onFollowUp = onFollowUp
        self.onOpenArtifact = onOpenArtifact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            cardHeader

            if let waitingStep = job.waitingStep {
                waitingStepBanner(waitingStep)
            }

            if let bodyPreviewText, !bodyPreviewText.isEmpty {
                Text(bodyPreviewText)
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ClickyArcPlan(phase: job.railPhase, planSteps: planSteps)

            if !displayedArtifacts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(displayedArtifacts) { artifact in
                            ClickyArcFileChip(
                                entry: artifact,
                                clickySlug: job.clickySlug,
                                onOpenArtifact: onOpenArtifact
                            )
                        }
                    }
                }
            }

            if isFollowUpComposerVisible {
                followUpComposerBar
            }

            actionFooter
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(isCardHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                isCardHovered = hovering
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            ClickyAgentIconView(
                agentKey: job.clickySlug,
                title: resolvedClickyName,
                mood: resolvedMood,
                prop: profile?.prop ?? ClickyAgentProp.defaultProp(forSlug: job.clickySlug),
                baseHue: profile?.baseHue ?? 0.58,
                size: 38
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)

                    if !job.isSeen && job.outcome != .working {
                        Circle()
                            .fill(DS.Colors.blue400)
                            .frame(width: 7, height: 7)
                    }
                }

                HStack(spacing: 6) {
                    Text(resolvedClickyName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("·")
                        .foregroundColor(DS.Colors.textTertiary)

                    elapsedTimeLabel
                }
            }

            Spacer()

            statusBadge
        }
    }

    @ViewBuilder
    private var elapsedTimeLabel: some View {
        if job.outcome == .working {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(formatElapsed(from: activeRunStartDate, to: context.date))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(DS.Colors.accentText)
            }
        } else {
            Text(formatElapsed(from: activeRunStartDate, to: job.finishedAt ?? job.createdAt))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var activeRunStartDate: Date {
        job.runs.last?.startedAt ?? job.createdAt
    }

    private var statusBadge: some View {
        let info = statusMetadata(for: job.railPhase)
        return HStack(spacing: 5) {
            Image(systemName: info.iconName)
                .font(.system(size: 10, weight: .semibold))
            Text(info.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(info.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(info.color.opacity(0.14)))
        .overlay(Capsule().stroke(info.color.opacity(0.35), lineWidth: 0.9))
    }

    private func waitingStepBanner(_ waitingStep: ClickyJobUserStep) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(waitingStep.step)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                if let page = waitingStep.page, !page.isEmpty {
                    Text(page)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .fill(DS.Colors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private var followUpComposerBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField("Send a quick follow-up…", text: $followUpDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .fill(DS.Colors.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .stroke(DS.Colors.borderStrong, lineWidth: 1)
                )
                .onSubmit {
                    submitFollowUpDraft()
                }

            Button("Send") {
                submitFollowUpDraft()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(DS.Colors.accent))
            .pointerCursor(isEnabled: !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .disabled(followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var actionFooter: some View {
        HStack(spacing: DS.Spacing.sm) {
            if job.outcome == .working, let onStop {
                Button(action: onStop) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill(DS.Colors.destructive.opacity(0.14)))
                    .overlay(Capsule().stroke(DS.Colors.destructive.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Button(action: triggerOpen) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(DS.Colors.surface3))
                .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                if onFollowUp != nil {
                    withAnimation(.easeOut(duration: DS.Animation.fast)) {
                        isFollowUpComposerVisible.toggle()
                    }
                } else {
                    triggerOpen()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Follow-up")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(DS.Colors.blue500.opacity(0.12)))
                .overlay(Capsule().stroke(DS.Colors.blue400.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()

            if job.runs.count > 1 {
                Text("\(job.runs.count) runs")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var resolvedClickyName: String {
        profile?.name ?? job.nickname ?? job.clickySlug
    }

    private var resolvedMood: ClickyAgentMood {
        switch job.railPhase {
        case .queued, .working:
            return .working
        case .needsYou:
            return .needsYou
        case .done:
            return .happy
        case .failed:
            return .failed
        case .stopped:
            return .sleepy
        }
    }

    private var bodyPreviewText: String? {
        if let summary = job.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        if let reply = job.replyText?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            return reply
        }
        let promptTrimmed = job.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return promptTrimmed.isEmpty ? nil : promptTrimmed
    }

    private var displayedArtifacts: [ClickyJobArtifactEntry] {
        if !job.latestReplyArtifactEntries.isEmpty {
            return job.latestReplyArtifactEntries
        }
        return job.artifactEntries
    }

    private var cardBorderColor: Color {
        if job.railPhase == .needsYou {
            return DS.Colors.warning.opacity(0.45)
        }
        if isCardHovered {
            return DS.Colors.borderStrong
        }
        return DS.Colors.borderSubtle
    }

    private func triggerOpen() {
        ClickyJobStore.shared.markSeen(jobID: job.id)
        if let onOpen {
            onOpen()
        } else {
            HeyClickyWindowController.shared.open(
                selectedSlug: job.clickySlug,
                initialTab: .chat
            )
        }
    }

    private func submitFollowUpDraft() {
        let trimmed = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        followUpDraft = ""
        withAnimation(.easeOut(duration: DS.Animation.fast)) {
            isFollowUpComposerVisible = false
        }
        onFollowUp?(trimmed)
    }

    private func statusMetadata(for phase: ClickyJobRailPhase) -> (title: String, iconName: String, color: Color) {
        switch phase {
        case .queued:
            return ("Queued", "clock", DS.Colors.textSecondary)
        case .working:
            return ("Working", "sparkles", DS.Colors.blue400)
        case .needsYou:
            return ("Needs You", "exclamationmark.bubble.fill", DS.Colors.warning)
        case .done:
            return ("Done", "checkmark.circle.fill", DS.Colors.success)
        case .failed:
            return ("Failed", "xmark.octagon.fill", DS.Colors.destructiveText)
        case .stopped:
            return ("Stopped", "pause.circle.fill", DS.Colors.textTertiary)
        }
    }

    private func formatElapsed(from startDate: Date, to endDate: Date) -> String {
        let elapsedSeconds = max(0, Int(endDate.timeIntervalSince(startDate)))
        if elapsedSeconds < 60 {
            return "\(elapsedSeconds)s"
        }
        let minutes = elapsedSeconds / 60
        let remainderSeconds = elapsedSeconds % 60
        if minutes < 60 {
            return String(format: "%dm %02ds", minutes, remainderSeconds)
        }
        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        return String(format: "%dh %02dm", hours, remainderMinutes)
    }
}
