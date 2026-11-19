//
//  ClickyAgentsSettingsView.swift
//  leanring-buddy
//
//  Settings > Agents: where agents work, how much autonomy they get, and
//  how they announce progress.
//

import AppKit
import SwiftUI

struct ClickyAgentsSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var configuration = ClickyConfiguration.shared

    private var agentFolderURL: URL {
        ClickyWorkFolderFiles.shared.rootDirectoryURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ClickySettingsSectionCard(title: String(localized: "Workspace")) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent folder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Where agents spawn and put the things they make.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(verbatim: (agentFolderURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([agentFolderURL])
                    }
                    .buttonStyle(ClickyGlossyPillButtonStyle.light)
                }
            }

            ClickySettingsSectionCard(title: String(localized: "Autonomy")) {
                ClickySettingsToggleRow(
                    title: String(localized: "Ask before starting jobs"),
                    subtitle: String(localized: "When off, Clicky starts a job as soon as you ask for one."),
                    isOn: $configuration.askBeforeStartingJobs
                )
                Divider().background(DS.Colors.borderSubtle)
                ClickySettingsToggleRow(
                    title: String(localized: "Always approve file uploads"),
                    subtitle: String(localized: "Let jobs add files from your Mac to websites without asking each turn. Keys, keychains and browser profiles stay off limits."),
                    isOn: $configuration.alwaysApproveFileUploads
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                ClickySettingsSectionCard(title: String(localized: "Announcements")) {
                    ClickySettingsToggleRow(
                        title: String(localized: "Speak when a job starts or finishes"),
                        subtitle: String(localized: "HeyClicky's voice tells you what a job got done."),
                        isOn: $configuration.speakWhenJobStartsOrFinishes
                    )
                    Divider().background(DS.Colors.borderSubtle)
                    ClickySettingsToggleRow(
                        title: String(localized: "Show updates beside the cursor"),
                        subtitle: String(localized: "A job's reply shows in a bubble next to your cursor when it finishes."),
                        isOn: $configuration.showJobUpdatesBesideCursor
                    )
                    Divider().background(DS.Colors.borderSubtle)
                    ClickySettingsToggleRow(
                        title: String(localized: "Suggest agent tasks"),
                        subtitle: String(localized: "Fresh task suggestions every 24 hours, based on what you do."),
                        isOn: $configuration.suggestAgentTasks
                    )
                }
                Text("HeyClicky stays quiet while you're on a call. Finished work waits in the chat and the notch shows how many jobs have something new.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            ClickyMacPermissionsCard(companionManager: companionManager)
        }
    }
}
