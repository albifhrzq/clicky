//
//  ClickyMicrophoneSelection.swift
//  leanring-buddy
//
//  Which microphone Clicky listens through (Settings → Microphone). Every capture engine
//  (push-to-talk dictation, wake word, realtime voice, mic test) reads this device through
//  ClickyMicrophoneCaptureInput. Until the user picks one, Clicky prefers the Mac's built-in mic: capturing
//  from a Bluetooth headset's mic flips it into the low-quality call profile (HFP), which
//  makes music sound bad and changes the mic format mid-recording.
//

import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct ClickyMicrophoneDeviceOption: Identifiable, Equatable, Sendable {
    let uniqueID: String
    let name: String
    let transportType: UInt32
    let audioDeviceID: AudioObjectID

    var id: String { uniqueID }
    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
}

@MainActor
final class ClickyMicrophoneSelection: ObservableObject {
    static let shared = ClickyMicrophoneSelection()

    /// Stored UID of the chosen mic. "" means System Default; a missing key means the user never chose.
    nonisolated static let selectedMicrophoneUniqueIDDefaultsKey = "clicky_selected_microphone_uid"
    nonisolated static let systemDefaultSelectionID = ""

    @Published private(set) var availableInputDevices: [ClickyMicrophoneDeviceOption] = []
    /// The row the Settings page shows as selected ("" = System Default).
    @Published private(set) var selectedRowID: String = systemDefaultSelectionID

    private var topologyCancellable: AnyCancellable?

    private init() {
        refreshAvailableInputDevices()
        // The topology monitor fires when devices connect/disconnect, so the list stays current.
        topologyCancellable = ClickyAudioTopologyMonitor.shared.$snapshot
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshAvailableInputDevices()
            }
    }

    func refreshAvailableInputDevices() {
        let devices = Self.queryInputDevices()
        availableInputDevices = devices
        let storedUniqueID = UserDefaults.standard.string(forKey: Self.selectedMicrophoneUniqueIDDefaultsKey)
        selectedRowID = Self.resolveCaptureDevice(storedUniqueID: storedUniqueID, availableDevices: devices)?.uniqueID
            ?? Self.systemDefaultSelectionID
    }

    func selectMicrophone(uniqueID: String) {
        UserDefaults.standard.set(uniqueID, forKey: Self.selectedMicrophoneUniqueIDDefaultsKey)
        refreshAvailableInputDevices()
    }

    // MARK: - Capture

    /// nil = use the system default input.
    /// - never chosen: the built-in mic when there is one (keeps Bluetooth headsets out of call mode)
    /// - "" (System Default): nil
    /// - a UID: that device, or nil when it is unplugged
    nonisolated static func resolveCaptureDevice(
        storedUniqueID: String?,
        availableDevices: [ClickyMicrophoneDeviceOption]
    ) -> ClickyMicrophoneDeviceOption? {
        guard let storedUniqueID else {
            return availableDevices.first(where: \.isBuiltIn)
        }
        if storedUniqueID == systemDefaultSelectionID { return nil }
        return availableDevices.first(where: { $0.uniqueID == storedUniqueID })
    }

    // MARK: - CoreAudio

    nonisolated static func queryInputDevices() -> [ClickyMicrophoneDeviceOption] {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &devicesAddress, 0, nil, &dataSize) == noErr else { return [] }

        var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObjectID, &devicesAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID: deviceID),
                  let uniqueID = queryDeviceUniqueID(deviceID: deviceID),
                  let name = ClickyAudioTopologyMonitor.queryDeviceName(deviceID: deviceID) else {
                return nil
            }
            return ClickyMicrophoneDeviceOption(
                uniqueID: uniqueID,
                name: name,
                transportType: ClickyAudioTopologyMonitor.queryTransportType(deviceID: deviceID),
                audioDeviceID: deviceID
            )
        }
    }

    nonisolated private static func hasInputStreams(deviceID: AudioObjectID) -> Bool {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    nonisolated private static func queryDeviceUniqueID(deviceID: AudioObjectID) -> String? {
        var uniqueIDAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUniqueID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &uniqueIDAddress, 0, nil, &dataSize, &unmanagedUniqueID)
        guard status == noErr, let uniqueID = unmanagedUniqueID?.takeRetainedValue() else { return nil }
        return uniqueID as String
    }
}

/// Settings → Microphone "Test microphone": runs the selected mic for a few seconds and reports its level.
@MainActor
final class ClickyMicrophoneTestController: ObservableObject {
    @Published private(set) var isTesting = false
    /// 0...1, drives the level bars.
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var errorMessage: String?

    private static let testDurationSeconds: UInt64 = 8
    private let microphoneCaptureInput = ClickyMicrophoneCaptureInput(logPrefix: "MicrophoneTest")
    private var autoStopTask: Task<Void, Never>?

    func toggleTest() {
        if isTesting { stopTest() } else { startTest() }
    }

    func startTest() {
        stopTest()
        errorMessage = nil
        do {
            try microphoneCaptureInput.start(
                onAudioBuffer: Self.makeLevelHandler { [weak self] level in
                    self?.inputLevel = level
                }
            )
        } catch {
            errorMessage = String(localized: "Could not start microphone test")
            return
        }
        isTesting = true
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.testDurationSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopTest()
        }
    }

    func stopTest() {
        autoStopTask?.cancel()
        autoStopTask = nil
        microphoneCaptureInput.stop()
        isTesting = false
        inputLevel = 0
    }

    /// Built off the main actor: buffers arrive on the capture queue, and a main-actor closure would trip
    /// Swift's isolation check there. Levels hop back to the main actor.
    nonisolated private static func makeLevelHandler(
        onLevel: @escaping @MainActor @Sendable (Float) -> Void
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in
            let level = normalizedInputLevel(from: buffer)
            Task { @MainActor in onLevel(level) }
        }
    }

    nonisolated static func normalizedInputLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelData[0][sampleIndex]
            summedSquares += sample * sample
        }
        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        return min(max(rootMeanSquare * 10, 0), 1)
    }
}
