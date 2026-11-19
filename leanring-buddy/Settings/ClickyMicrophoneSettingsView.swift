//
//  ClickyMicrophoneSettingsView.swift
//  leanring-buddy
//
//  Settings → Microphone: pick the input device Clicky listens through and test it.
//

import SwiftUI

struct ClickyMicrophoneSettingsView: View {
    @ObservedObject private var microphoneSelection = ClickyMicrophoneSelection.shared
    @StateObject private var microphoneTestController = ClickyMicrophoneTestController()

    private static let levelBarCount = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which microphone Clicky listens through.")
                .font(.system(size: 12))
                .foregroundColor(ClickySettingsPalette.secondaryText)

            card(title: String(localized: "INPUT DEVICE")) {
                VStack(alignment: .leading, spacing: 0) {
                    deviceRow(
                        name: String(localized: "System Default"),
                        rowID: ClickyMicrophoneSelection.systemDefaultSelectionID
                    )
                    ForEach(microphoneSelection.availableInputDevices) { device in
                        ClickySettingsRowDivider()
                        deviceRow(name: device.name, rowID: device.uniqueID)
                    }
                }
            }

            card(title: String(localized: "TEST")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button {
                            microphoneTestController.toggleTest()
                        } label: {
                            Text(microphoneTestController.isTesting ? "Stop test" : "Test microphone")
                        }
                        .buttonStyle(ClickyGlossyPillButtonStyle.light)

                        levelBars
                    }

                    Text(microphoneTestController.errorMessage ?? String(localized: "Tap to test selected input"))
                        .font(.system(size: 11))
                        .foregroundColor(
                            microphoneTestController.errorMessage == nil ? DS.Colors.textTertiary : DS.Colors.destructiveText
                        )
                }
            }

            Text("Speak normally — the bars should move as Clicky hears you. Bluetooth headset mics switch the headset to low-quality call audio, so the Mac's built-in mic is used until you pick another.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { microphoneSelection.refreshAvailableInputDevices() }
        .onDisappear { microphoneTestController.stopTest() }
    }

    private func deviceRow(name: String, rowID: String) -> some View {
        let isSelected = microphoneSelection.selectedRowID == rowID
        return Button {
            microphoneTestController.stopTest()
            microphoneSelection.selectMicrophone(uniqueID: rowID)
        } label: {
            HStack(spacing: 10) {
                ClickyGlossyRadioIndicator(isSelected: isSelected)
                Text(name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(ClickySettingsPalette.primaryText)
                Spacer()
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var levelBars: some View {
        let litBarCount = Int((microphoneTestController.inputLevel * Float(Self.levelBarCount)).rounded())
        return HStack(spacing: 3) {
            ForEach(0..<Self.levelBarCount, id: \.self) { barIndex in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(barIndex < litBarCount ? ClickySettingsPalette.glossBlueTop : ClickySettingsPalette.selectedRow)
                    .frame(width: 5, height: 16)
            }
        }
        .animation(.linear(duration: 0.08), value: litBarCount)
    }

    private func card<Content: View>(title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ClickySettingsSectionCard(title: title, content: content)
    }
}
