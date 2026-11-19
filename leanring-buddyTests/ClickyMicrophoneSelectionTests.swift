//
//  ClickyMicrophoneSelectionTests.swift
//  leanring-buddyTests
//

import CoreAudio
import Testing
@testable import Clicky

struct ClickyMicrophoneSelectionTests {
    private let builtInMicrophone = ClickyMicrophoneDeviceOption(
        uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        transportType: kAudioDeviceTransportTypeBuiltIn, audioDeviceID: 10
    )
    private let bluetoothHeadsetMicrophone = ClickyMicrophoneDeviceOption(
        uniqueID: "AA-BB-CC:input", name: "MINISO-CH510",
        transportType: kAudioDeviceTransportTypeBluetooth, audioDeviceID: 20
    )

    @Test func neverChosenPrefersTheBuiltInMicSoBluetoothStaysOutOfCallMode() {
        let resolved = ClickyMicrophoneSelection.resolveCaptureDevice(
            storedUniqueID: nil, availableDevices: [bluetoothHeadsetMicrophone, builtInMicrophone]
        )
        #expect(resolved == builtInMicrophone)
    }

    @Test func systemDefaultChoiceDoesNotPinAnyDevice() {
        let resolved = ClickyMicrophoneSelection.resolveCaptureDevice(
            storedUniqueID: "", availableDevices: [bluetoothHeadsetMicrophone, builtInMicrophone]
        )
        #expect(resolved == nil)
    }

    @Test func captureInputLooksUpTheBuiltInMicWhenNeverChosenAndNothingWhenSystemDefault() {
        #expect(ClickyMicrophoneCaptureInput.preferredCaptureDeviceUniqueID(
            storedUniqueID: nil, availableDevices: [bluetoothHeadsetMicrophone, builtInMicrophone]
        ) == "BuiltInMicrophoneDevice")
        #expect(ClickyMicrophoneCaptureInput.preferredCaptureDeviceUniqueID(
            storedUniqueID: "", availableDevices: [builtInMicrophone]
        ) == nil)
    }

    @Test func chosenDeviceIsPinnedAndFallsBackToSystemDefaultWhenUnplugged() {
        #expect(ClickyMicrophoneSelection.resolveCaptureDevice(
            storedUniqueID: "AA-BB-CC:input", availableDevices: [bluetoothHeadsetMicrophone, builtInMicrophone]
        ) == bluetoothHeadsetMicrophone)
        #expect(ClickyMicrophoneSelection.resolveCaptureDevice(
            storedUniqueID: "AA-BB-CC:input", availableDevices: [builtInMicrophone]
        ) == nil)
    }
}
