//
//  ClickySkillsSettingsView.swift
//  leanring-buddy
//
//  Settings > Skills: list, create, import, edit, activate and remove local skills.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClickySkillsSettingsView: View {
    let companionManager: CompanionManager

    @ObservedObject private var skillStore = ClickySkillStore.shared

    @State private var newSkillTopicLine = ""
    @State private var newSkillNotes = ""
    @State private var skillBeingEdited: ClickySkill?
    @State private var skillPendingRemoval: ClickySkill?
    @State private var skillWaitingForSwap: ClickySkill?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card(title: String(localized: "MY SKILLS")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A skill is a new superpower for Clicky. Tell it what to learn and it studies up like a real expert.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Active skills become part of Clicky, shaping its answers and guiding every agent it runs for you.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)

                    if skillStore.skills.isEmpty {
                        Text("No skills available yet.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    ForEach(skillStore.skills) { skill in
                        skillRow(skill)
                        Divider().background(DS.Colors.borderSubtle)
                    }

                    if let skillWaitingForSwap {
                        swapPicker(for: skillWaitingForSwap)
                    }

                    if let errorMessage = skillStore.lastErrorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.destructiveText)
                    }

                    HStack(spacing: 14) {
                        Button { importMarkdownFile() } label: {
                            Label("Import .md…", systemImage: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.accentText)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()

                        if !skillStore.activeSkillIDs.isEmpty {
                            Button { skillStore.deactivateAllSkills() } label: {
                                Text("Deactivate all attached skills")
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                }
            }

            card(title: String(localized: "CREATE A SKILL")) {
                createForm
            }
        }
        .sheet(item: $skillBeingEdited) { skill in
            ClickySkillEditorSheet(skill: skill, skillStore: skillStore) { skillBeingEdited = nil }
        }
        .alert(
            "Remove this skill",
            isPresented: Binding(get: { skillPendingRemoval != nil }, set: { if !$0 { skillPendingRemoval = nil } })
        ) {
            Button("Remove this skill", role: .destructive) {
                if let skillPendingRemoval { skillStore.removeSkill(id: skillPendingRemoval.id) }
                skillPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { skillPendingRemoval = nil }
        } message: {
            Text("This permanently removes the skill from the library. This can't be undone.")
        }
    }

    // MARK: - Rows

    private func skillRow(_ skill: ClickySkill) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if skill.isActive {
                        Text("Skill Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.accentText)
                    }
                }
                statusText(for: skill)
            }
            Spacer()

            if skill.status == .draft || skill.status == .ready {
                Toggle("", isOn: Binding(
                    get: { skill.isActive },
                    set: { isOn in handleToggle(skill, isOn: isOn) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
                .disabled(!skill.isActive && !skillStore.canActivate(skill))
                .help(String(localized: "Activate Skill"))
                .pointerCursor()

                Button {
                    skillStore.markReviewed(id: skill.id)
                    skillBeingEdited = skill
                } label: {
                    Image(systemName: "pencil").foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Edit skill"))
                .pointerCursor()
            }

            Button { skillPendingRemoval = skill } label: {
                Image(systemName: "trash").foregroundColor(DS.Colors.destructiveText)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove this skill"))
            .pointerCursor()
        }
    }

    @ViewBuilder
    private func statusText(for skill: ClickySkill) -> some View {
        switch skill.status {
        case .creating:
            Text("Researching and writing your skill…")
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
        case .failed:
            Text("Something went wrong while researching and writing this skill. Remove it and try again. Your notes aren't saved here, so keep a copy if they were long.")
                .font(.system(size: 11)).foregroundColor(DS.Colors.destructiveText)
        case .draft:
            Text(skillStore.canActivate(skill) ? LocalizedStringKey("Draft") : LocalizedStringKey("Draft. Open it with the pencil and read it before turning it on."))
                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
        case .ready:
            EmptyView()
        }
    }

    private func handleToggle(_ skill: ClickySkill, isOn: Bool) {
        guard isOn else {
            skillStore.deactivate(skillID: skill.id)
            return
        }
        switch skillStore.activationDecision(for: skill.id) {
        case .activate: skillStore.activate(skillID: skill.id)
        case .alreadyActive: break
        case .needsSwap: skillWaitingForSwap = skill
        }
    }

    private func swapPicker(for skill: ClickySkill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All 3 skill slots are full. Tap one to swap it out for \"\(skill.displayName)\":")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            ForEach(skillStore.skills.filter(\.isActive)) { activeSkill in
                Button {
                    skillStore.activate(skillID: skill.id, swappingOut: activeSkill.id)
                    skillWaitingForSwap = nil
                } label: {
                    Text(activeSkill.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Button("Cancel") { skillWaitingForSwap = nil }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .pointerCursor()
        }
    }

    // MARK: - Create

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start with one line, like: make me an expert at editing YouTube videos.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            TextField("", text: $newSkillTopicLine)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $newSkillNotes)
                .font(.system(size: 12))
                .frame(minHeight: 70, maxHeight: 120)
            Button {
                skillStore.beginCreatingSkill(
                    topicLine: newSkillTopicLine,
                    notes: newSkillNotes,
                    companionManager: companionManager
                )
                newSkillTopicLine = ""
                newSkillNotes = ""
            } label: {
                Text("Create my skill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .disabled(newSkillTopicLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .pointerCursor()
        }
    }

    // MARK: - Import

    private func importMarkdownFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        guard openPanel.runModal() == .OK, let selectedFileURL = openPanel.url else { return }
        skillStore.lastErrorMessage = nil
        skillStore.importMarkdownFile(at: selectedFileURL)
    }

    private func card<Content: View>(title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ClickySettingsSectionCard(title: title, content: content)
    }
}

/// Edit sheet: name field plus the raw Markdown.
private struct ClickySkillEditorSheet: View {
    let skill: ClickySkill
    let skillStore: ClickySkillStore
    let onClose: () -> Void

    @State private var displayNameDraft: String
    @State private var markdownDraft: String

    init(skill: ClickySkill, skillStore: ClickySkillStore, onClose: @escaping () -> Void) {
        self.skill = skill
        self.skillStore = skillStore
        self.onClose = onClose
        _displayNameDraft = State(initialValue: skill.displayName)
        _markdownDraft = State(initialValue: skillStore.readContent(of: skill) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit skill")
                .font(.system(size: 14, weight: .semibold))
            TextField("", text: $displayNameDraft)
                .textFieldStyle(.roundedBorder)
            Text("INSIDE THIS SKILL")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            TextEditor(text: $markdownDraft)
                .font(.system(size: 12, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel") { onClose() }.pointerCursor()
                Button("Save") {
                    skillStore.updateSkill(id: skill.id, displayName: displayNameDraft, markdown: markdownDraft)
                    onClose()
                }
                .disabled(markdownDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor()
            }
        }
        .padding(16)
        .frame(width: 520, height: 480)
    }
}
