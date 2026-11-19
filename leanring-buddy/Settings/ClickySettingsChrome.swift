//
//  ClickySettingsChrome.swift
//  leanring-buddy
//
//  Shared building blocks that give every Settings page the HeyClicky look:
//  big page title + grey subtitle, uppercase grey section header ABOVE a
//  rounded card, and rows with a title, secondary subtitle and trailing control.
//

import SwiftUI

/// HeyClicky 1.1.5 settings colors, measured from the official screenshots.
enum ClickySettingsPalette {
    static let contentBackground = Color(hex: "#1f1f1f")
    static let sidebarDivider = Color.white.opacity(0.06)
    static let cardFill = Color(hex: "#2a2a2a")
    static let cardStroke = Color.white.opacity(0.06)
    static let rowDivider = Color.white.opacity(0.06)
    static let primaryText = Color.white
    static let secondaryText = Color(hex: "#8e8e93")
    static let sidebarIcon = Color(hex: "#a1a1a6")
    static let sidebarLabel = Color(hex: "#e5e5ea")
    static let selectedRow = Color(hex: "#3a3a3c")
    static let groupHeader = Color(hex: "#6e6e73")
    static let keycap = Color(hex: "#3a3a3c")
    static let trailingValueText = Color(hex: "#a1a1a6")
    static let searchFieldFill = Color(hex: "#333333")
    static let radioEmptyStroke = Color(hex: "#5a5a5e")
    static let glossBlueTop = Color(hex: "#b4ccff")
    static let glossBlueBottom = Color(hex: "#7f9ff2")
    static let glossBlueGradient = LinearGradient(
        colors: [glossBlueTop, glossBlueBottom], startPoint: .top, endPoint: .bottom
    )
    static let navyText = Color(hex: "#0d1b3d")
    static let toggleOffKnob = Color(hex: "#d1d1d6")
}

struct ClickySettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(ClickySettingsPalette.primaryText)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(ClickySettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded card surface shared by section cards and standalone cards.
struct ClickySettingsCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ClickySettingsPalette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ClickySettingsPalette.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func clickySettingsCard() -> some View {
        modifier(ClickySettingsCardBackground())
    }
}

/// The section header sits outside (above) the card, like the official app,
/// so the card itself only holds rows.
struct ClickySettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(2)
                .foregroundColor(ClickySettingsPalette.secondaryText)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clickySettingsCard()
        }
    }
}

/// Official-style toggle: light-blue glossy capsule with a black knob when on,
/// dark capsule with a light-gray knob when off. Still a real Toggle for accessibility.
struct ClickyGlossyToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            glossySwitch(configuration: configuration)
        }
    }

    private func glossySwitch(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? AnyShapeStyle(ClickySettingsPalette.glossBlueGradient)
                          : AnyShapeStyle(ClickySettingsPalette.selectedRow))
                if configuration.isOn {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                                             startPoint: .top, endPoint: .center))
                        .padding(1)
                }
                Circle()
                    .fill(configuration.isOn ? Color.black : ClickySettingsPalette.toggleOffKnob)
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .frame(width: 46, height: 24)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

struct ClickyGlossyPillButtonStyle: ButtonStyle {
    enum Variant { case accent, light }
    let variant: Variant

    static var accent: ClickyGlossyPillButtonStyle { .init(variant: .accent) }
    static var light: ClickyGlossyPillButtonStyle { .init(variant: .light) }

    func makeBody(configuration: Configuration) -> some View {
        let isAccent = variant == .accent
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isAccent ? ClickySettingsPalette.navyText : Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isAccent
                    ? AnyShapeStyle(ClickySettingsPalette.glossBlueGradient)
                    : AnyShapeStyle(LinearGradient(colors: [.white, Color(hex: "#d9d9de")],
                                                   startPoint: .top, endPoint: .bottom))
                )
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(isAccent ? 0.5 : 0.7), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(isAccent ? 0 : 0.3), radius: 2, y: 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
            .pointerCursor()
    }
}

/// Shortcut keycap such as "⌃ control" or "fn".
struct ClickyKeycapView: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(ClickySettingsPalette.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ClickySettingsPalette.keycap)
            )
    }
}

/// Radio indicator for device rows: empty ring or glossy blue disc with black check.
struct ClickyGlossyRadioIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(ClickySettingsPalette.glossBlueGradient)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black)
            } else {
                Circle().stroke(ClickySettingsPalette.radioEmptyStroke, lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Divider between rows inside a card.
struct ClickySettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(ClickySettingsPalette.rowDivider)
            .frame(height: 1)
    }
}

struct ClickySettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(ClickySettingsPalette.primaryText)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(ClickySettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(ClickyGlossyToggleStyle())
                .labelsHidden()
        }
    }
}

struct ClickySettingsStatusBadge: View {
    let label: String
    let isPositive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPositive ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isPositive ? DS.Colors.success : DS.Colors.warningText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill((isPositive ? DS.Colors.success : DS.Colors.warning).opacity(0.15))
        )
    }
}

/// App name and version shown in the settings sidebar footer, read from the bundle
/// so it follows the product name instead of being hard-coded.
enum ClickyAppDisplayName {
    static var current: String {
        let bundle = Bundle.main
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "HeyClicky"
    }

    static var versionFooter: String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(current) \(shortVersion) (\(buildNumber))"
    }
}

/// Cursor color choice: a rounded card with a glowing cursor triangle in the color.
/// Selected card gets a light-blue ring and a glossy check badge.
struct ClickyCursorColorCard: View {
    let colorName: String
    let cursorColor: Color
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 34))
                    .rotationEffect(.degrees(-30))
                    .foregroundColor(cursorColor)
                    .shadow(color: cursorColor.opacity(0.8), radius: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isSelected {
                    ZStack {
                        Circle().fill(ClickySettingsPalette.glossBlueGradient)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                    }
                    .frame(width: 20, height: 20)
                    .padding(8)
                }
            }
            .frame(width: 120, height: 120)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ClickySettingsPalette.cardFill)
                    .overlay(Color.white.opacity(isHovering ? 0.04 : 0).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? ClickySettingsPalette.glossBlueTop : ClickySettingsPalette.cardStroke,
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(verbatim: colorName.capitalized))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
