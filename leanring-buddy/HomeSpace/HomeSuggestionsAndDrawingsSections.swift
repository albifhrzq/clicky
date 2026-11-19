//
//  HomeSuggestionsAndDrawingsSections.swift
//  leanring-buddy
//
//  Home → Suggestions (one idea at a time, with the reason and Yes / No thanks) and
//  Home → Drawings (replay finished drawings in a window, full screen, or on a white board).
//

import SwiftUI

// MARK: - Suggestions

struct HomeSuggestionsSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var suggestionsStore = ClickySuggestionsStore.shared

    @State private var selectedSuggestionIndex: Int = 0
    @State private var isAskingDeclineReason: Bool = false
    @State private var declineReasonText: String = ""

    var body: some View {
        if shouldShowSection {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                sectionHeader
                cardContent
                    .padding(DS.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge).fill(DS.Colors.surface1))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                            .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 1)
                    )
            }
        }
    }

    private var shouldShowSection: Bool {
        !suggestionsStore.suggestions.isEmpty
            || suggestionsStore.phase != .idle
            || suggestionsStore.hasGeneratedToday
    }

    private var sectionHeader: some View {
        HStack {
            Text("Suggestions")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Button(action: { ClickyMorningSuggestionsMonitor.shared.forceRefresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(Text("Refresh suggestions"))
            .disabled(suggestionsStore.phase == .loading)
            .pointerCursor(isEnabled: suggestionsStore.phase != .loading)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        let suggestions = suggestionsStore.suggestions
        if suggestionsStore.phase == .loading && suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finding suggestions…").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                Text("Looking for fresh ideas. This can take 5–10 minutes.")
                    .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            }
        } else if suggestionsStore.phase == .failed && suggestions.isEmpty {
            Text("Could not load suggestions. We’ll try again in a little while.")
                .font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary)
        } else if suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("You're all caught up").font(.system(size: 13, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                Text("Come back tomorrow for fresh ideas.").font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            }
        } else {
            let safeIndex = min(selectedSuggestionIndex, suggestions.count - 1)
            suggestionCard(suggestions[safeIndex], index: safeIndex, count: suggestions.count)
        }
    }

    private func suggestionCard(_ suggestion: ClickySuggestion, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                stepButton(systemName: "chevron.left", help: Text("Previous suggestion"), isEnabled: index > 0) {
                    selectedSuggestionIndex = index - 1
                    isAskingDeclineReason = false
                }
                Text("Suggestion \(index + 1) of \(count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                stepButton(systemName: "chevron.right", help: Text("Next suggestion"), isEnabled: index < count - 1) {
                    selectedSuggestionIndex = index + 1
                    isAskingDeclineReason = false
                }
            }

            Text(suggestion.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            if let reason = suggestion.reason {
                Text(reason)
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            if isAskingDeclineReason {
                declineReasonField(for: suggestion)
            } else {
                HStack(spacing: DS.Spacing.sm) {
                    pillButton(title: Text("Yes, do it"), isPrimary: true) {
                        companionManager.startBackgroundAgentTask(prompt: suggestion.title)
                        suggestionsStore.resolve(suggestion)
                        declineReasonText = ""
                    }
                    pillButton(title: Text("No thanks."), isPrimary: false) {
                        isAskingDeclineReason = true
                    }
                }
            }
        }
    }

    private func declineReasonField(for suggestion: ClickySuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(String(localized: "Not now because…"), text: $declineReasonText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitDecline(of: suggestion) }
            Text("Tell Clicky why. It makes the next suggestions better.")
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
            HStack(spacing: DS.Spacing.sm) {
                pillButton(title: Text("No thanks."), isPrimary: true) { submitDecline(of: suggestion) }
                pillButton(title: Text("Cancel"), isPrimary: false) { isAskingDeclineReason = false }
            }
        }
    }

    private func submitDecline(of suggestion: ClickySuggestion) {
        suggestionsStore.resolve(suggestion, declinedBecause: declineReasonText)
        declineReasonText = ""
        isAskingDeclineReason = false
    }

    private func stepButton(systemName: String, help: Text, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 10, weight: .bold))
                .foregroundColor(isEnabled ? DS.Colors.textSecondary : DS.Colors.textTertiary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
    }

    private func pillButton(title: Text, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isPrimary ? DS.Colors.accentText : DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(isPrimary ? DS.Colors.blue500.opacity(0.14) : DS.Colors.surface2))
                .overlay(Capsule().stroke(isPrimary ? DS.Colors.blue400.opacity(0.35) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Drawings

struct HomeDrawingsSection: View {
    @ObservedObject private var recentDrawings = ClickyRecentDrawings.shared

    var body: some View {
        if !recentDrawings.entries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Drawings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                VStack(spacing: DS.Spacing.sm) {
                    ForEach(recentDrawings.entries) { drawing in
                        drawingRow(drawing)
                    }
                }
            }
        }
    }

    private func drawingRow(_ drawing: ClickyRecentDrawing) -> some View {
        HStack(spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(drawing.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(drawing.createdAt, style: .relative)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Menu {
                Button(String(localized: "Play “\(drawing.title)” again in a window")) {
                    ClickyDrawingPlayer.play(drawingID: drawing.id, mode: .window)
                }
                Button("Play it full screen over your screen") {
                    ClickyDrawingPlayer.play(drawingID: drawing.id, mode: .fullScreen)
                }
                Button("Play on a white board") {
                    ClickyDrawingPlayer.play(drawingID: drawing.id, mode: .whiteboard)
                }
            } label: {
                Text("Play again").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .pointerCursor()

            Button(action: { recentDrawings.remove(id: drawing.id) }) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help(Text("Delete"))
            .pointerCursor()
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large).fill(DS.Colors.surface1))
    }
}
