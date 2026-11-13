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

                Button("Always approve for turn") {
                    onDecision(.approveTurn)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))

                Button("Always") {
                    onDecision(.alwaysApprove)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .secondary))

                Spacer(minLength: 0)

                Button("Decline") {
                    onDecision(.decline)
                }
                .buttonStyle(NotchCardActionButtonStyle(variant: .destructive))
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
                    Text(request.shortTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(request.step)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(3)

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
                Text("Move your mouse or press Escape anytime to take back control.")
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
                Button("Restart & Update") {
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
