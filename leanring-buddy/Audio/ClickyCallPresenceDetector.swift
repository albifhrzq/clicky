//
//  ClickyCallPresenceDetector.swift
//  leanring-buddy
//
//  Decides whether the user is "on a call" so unprompted audio can stay quiet.
//  A call = some OTHER process currently has an audio input running, excluding
//  recording apps. An app merely being open (FaceTime) never counts: only
//  processes whose input is actively running are considered.
//

import AppKit
import CoreAudio
import Foundation

struct ClickyAudioInputProcess: Equatable {
    let processID: pid_t
    let bundleIdentifier: String?
    let isRunningInput: Bool
}

enum ClickyCallPresenceDecision {
    static let recordingAppBundleIdentifiers: Set<String> = [
        "com.apple.garageband10",
        "org.audacityteam.audacity",
        "com.obsproject.obs-studio",
        "com.apple.logic10",
        "com.apple.VoiceMemos"
    ]

    /// Pure decision: true when a non-self, non-recording process has live mic input.
    static func isCallActive(
        processes: [ClickyAudioInputProcess],
        ownProcessID: pid_t
    ) -> Bool {
        processes.contains { process in
            guard process.isRunningInput, process.processID != ownProcessID else { return false }
            if let bundleIdentifier = process.bundleIdentifier,
               recordingAppBundleIdentifiers.contains(bundleIdentifier) {
                return false
            }
            return true
        }
    }
}

enum ClickyCallPresenceDetector {
    /// Quiet gate for UNPROMPTED audio only. Replies to the user's own request must not call this.
    static func shouldStayQuietForUnpromptedAudio() -> Bool {
        guard ClickyConfiguration.shared.stayQuietDuringCalls else { return false }
        return isCallActive()
    }

    static func isCallActive() -> Bool {
        ClickyCallPresenceDecision.isCallActive(
            processes: currentAudioProcesses(),
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }

    private static func currentAudioProcesses() -> [ClickyAudioInputProcess] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        var processObjectIDs = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize, &processObjectIDs) == noErr else {
            return []
        }

        return processObjectIDs.compactMap { processObjectID in
            guard let processID: pid_t = readValue(processObjectID, kAudioProcessPropertyPID),
                  let isRunningInput: UInt32 = readValue(processObjectID, kAudioProcessPropertyIsRunningInput)
            else { return nil }
            return ClickyAudioInputProcess(
                processID: processID,
                bundleIdentifier: NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
                isRunningInput: isRunningInput != 0
            )
        }
    }

    private static func readValue<Value>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let buffer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer) == noErr else { return nil }
        return buffer.pointee
    }
}
