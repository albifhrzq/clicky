//
//  ClickyVoiceDiagnostics.swift
//  leanring-buddy
//
//  Single source of truth for voice/dictation user-facing error copy plus the pure
//  decision helpers behind it (error mapping, noise filter, safety-filter detection,
//  mute/dead-mic checks, AEC and always-on gates). Pure so they can be unit tested.
//

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Copy

enum ClickyVoiceMessages {
    // Microphone state
    static var microphoneAccessIsOff: String { String(localized: "Microphone access is off") }
    static var microphonePermissionIsOff: String { String(localized: "Microphone permission is off") }
    static var waitingForMicrophonePermission: String { String(localized: "Waiting for microphone permission") }
    static var yourMacIsMuted: String { String(localized: "Your Mac is muted") }
    static var turnYourSoundBackOn: String { String(localized: "Turn your sound back on") }
    static var microphoneDisconnected: String { String(localized: "Microphone disconnected") }
    static var noMicrophoneFound: String { String(localized: "No microphone found") }
    static var couldntOpenTheMicrophone: String { String(localized: "Couldn't open the microphone") }
    static var microphoneCaptureFailed: String { String(localized: "Microphone capture failed") }
    static var openMicrophoneSettingsToPickAWorkingMic: String { String(localized: "Open microphone settings to pick a working mic") }
    static var clickyCantHearYou: String { String(localized: "Clicky can't hear you. Try different microphone.") }
    static var clickyCantHearYourMicrophone: String { String(localized: "Clicky can't hear your microphone") }
    static var yourMicrophone: String { String(localized: "Your microphone") }
    static var iCantHearYourMicrophone: String { String(localized: "I can't hear your microphone. Is it muted or unplugged?") }
    static var noMicrophoneAvailableToCapture: String { String(localized: "No microphone available to capture from.") }
    static var couldntStartTheMicrophone: String { String(localized: "Couldn't start the microphone.") }
    static func deviceIsntSendingAudio(_ deviceName: String) -> String {
        String(localized: "\(deviceName) isn't sending audio")
    }
    static func deviceStoppedSendingAudio(_ deviceName: String) -> String {
        String(localized: "\(deviceName) stopped sending audio")
    }

    // Voice / dictation errors
    static var iDidntCatchThat: String { String(localized: "I didn't catch that. Hold the keys while you talk, then let go.") }
    static var iCouldntHearThat: String { String(localized: "I couldn't hear that, my speech connection dropped. Try again in a moment, or type it instead.") }
    static var connectionDroppedMidResponse: String { String(localized: "connection dropped mid-response — try again.") }
    static var connectionDroppedMidResponsePushToTalk: String { String(localized: "connection dropped mid-response — push to talk to try again.") }
    static var speechConnectionWasInterrupted: String { String(localized: "The speech connection was interrupted.") }
    static var speechFinalTranscriptTimedOut: String { String(localized: "Speech final transcript timed out.") }
    static var speechAudioUploadStalled: String { String(localized: "Speech audio upload stalled.") }
    static var thatReplyWasntHeard: String { String(localized: "That reply wasn't heard") }
    static var sorryICouldntGetAnAnswer: String { String(localized: "Sorry, I couldn't get an answer just now. Try asking me again.") }
    static var myVoiceConnectionDidntOpen: String { String(localized: "My voice connection didn't open, so I wrote the answer instead.") }
    static func iCantReachProvider(_ providerName: String) -> String {
        String(localized: "I can't reach \(providerName) from this network. A firewall, proxy or DNS filter seems to be blocking it, so I can't answer until that changes.")
    }
    static var couldntTranscribeThatTryAgain: String { String(localized: "couldn't transcribe that. try again.") }
    static var couldntStartVoiceInput: String { String(localized: "couldn't start voice input. try again.") }
    static var dictationFailedTryAgain: String { String(localized: "Dictation failed. Try again") }
    static var invalidDictationResponse: String { String(localized: "Invalid dictation response.") }
    static var microphonePermissionRequiredForPushToTalk: String { String(localized: "microphone permission is required for push to talk.") }
    static var speechRecognitionPermissionRequiredForPushToTalk: String { String(localized: "speech recognition permission is required for push to talk.") }

    // Insertion, clipboard, safety filter
    static var providerSafetyFilterBlocked: String { String(localized: "My AI provider's safety filter blocked this because it looks like hands-on security work. I can still explain the concepts.") }
    static var iDidntFillThat: String { String(localized: "I didn't fill that in, that field didn't look safe to type into.") }
    static var iDidntFillThatPasswordField: String { String(localized: "I didn't fill that in, it's a password field, so type that one yourself.") }
    static var iCouldntDropThatCommandV: String { String(localized: "I couldn't drop that straight into the field, so it's on your clipboard. Press Command V to paste it.") }
    static var iPastedItButCheck: String { String(localized: "I pasted it, but I couldn't see it show up in the field, so check it's there.") }
    static var theScreenChangedBeforeITyped: String { String(localized: "The screen changed before I could type that in, so ask me again and I'll put it there.") }
    static var theAnswerIsOnYourClipboard: String { String(localized: "The answer is on your clipboard. Press ⌘V to paste") }
    static var copiedToYourClipboard: String { String(localized: "Copied to your clipboard") }
    static var pressCommandVToPaste: String { String(localized: "Press ⌘V to paste") }
    static var enableAccessibilityToInsertDictation: String { String(localized: "Enable Accessibility for Clicky to insert dictation.") }

    // Shortcut recorder
    static var pressTheModifiersYouWant: String { String(localized: "Press the modifiers you want…") }
    static var shortcutMatchesAnExistingOne: String { String(localized: "That matches one of your Clicky shortcuts. Pick a different combo.") }
    static var shortcutNotSet: String { String(localized: "Not set") }

    // Always-on voice
    static var alwaysOnNeedsHeadphones: String { String(localized: "always-on needs headphones. plug them in and triple-tap control again. heads up: it's experimental, so expect some bugs.") }
    static var alwaysOnEndedHeadphonesLost: String { String(localized: "always-on ended. it needs headphones and your audio just switched to speakers. reconnect headphones and triple-tap control to start it again.") }
    static var alwaysOnCouldntConnect: String { String(localized: "always-on couldn't connect. check your internet connection, then triple-tap control to try again.") }
    static var alwaysOnVoiceDisconnected: String { String(localized: "always-on voice disconnected — triple-tap control to restart it.") }
}

// MARK: - Error mapping

enum ClickyVoiceErrorMapper {
    /// Maps an error to the official copy. Falls back to the error's own description, then `fallback`.
    static func message(
        for error: Error,
        providerName: String = "the speech service",
        isPushToTalk: Bool = true,
        fallback: String
    ) -> String {
        if error is ClickySafetyFilterError {
            return ClickyVoiceMessages.providerSafetyFilterBlocked
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return ClickyVoiceMessages.speechFinalTranscriptTimedOut
            case .networkConnectionLost, .notConnectedToInternet:
                return isPushToTalk
                    ? ClickyVoiceMessages.connectionDroppedMidResponsePushToTalk
                    : ClickyVoiceMessages.connectionDroppedMidResponse
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
                return ClickyVoiceMessages.iCantReachProvider(providerName)
            default:
                break
            }
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }

        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty, description != "The operation couldn’t be completed." {
            return description
        }
        return fallback
    }
}

// MARK: - Microphone problems

enum ClickyMicrophoneProblem: Equatable {
    case permissionDenied
    case permissionPending
    case noDevice
    case deviceDisconnected
    case deadDevice(name: String)
    case outputMuted
    case openFailed

    var userFacingMessage: String {
        switch self {
        case .permissionDenied: return ClickyVoiceMessages.microphoneAccessIsOff
        case .permissionPending: return ClickyVoiceMessages.waitingForMicrophonePermission
        case .noDevice: return ClickyVoiceMessages.noMicrophoneFound
        case .deviceDisconnected: return ClickyVoiceMessages.microphoneDisconnected
        case .deadDevice(let name):
            return ClickyVoiceMessages.deviceIsntSendingAudio(name.isEmpty ? ClickyVoiceMessages.yourMicrophone : name)
        case .outputMuted:
            return "\(ClickyVoiceMessages.yourMacIsMuted) · \(ClickyVoiceMessages.turnYourSoundBackOn)"
        case .openFailed: return ClickyVoiceMessages.couldntOpenTheMicrophone
        }
    }
}

enum ClickyMicrophoneHealth {
    /// A mic that delivers exact digital silence for this long while capturing is treated as dead.
    static let deadInputSilenceSeconds: TimeInterval = 8
    /// Devices often emit exact silence while a (re)started capture warms up; ignore this window.
    static let captureWarmUpSeconds: TimeInterval = 3

    static func isInputDead(captureStartedAt: Date, lastNonSilentInputAt: Date?, now: Date) -> Bool {
        let warmUpEnd = captureStartedAt.addingTimeInterval(captureWarmUpSeconds)
        let reference = max(lastNonSilentInputAt ?? captureStartedAt, warmUpEnd)
        return now.timeIntervalSince(reference) >= deadInputSilenceSeconds
    }

    /// True when the default output device is muted or at zero volume.
    nonisolated static func isDefaultOutputMuted() -> Bool {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return false }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var muteValue: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &muteValue) == noErr, muteValue != 0 {
                return true
            }
        }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &volumeAddress) {
            var volumeValue: Float32 = 1
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &volumeValue) == noErr {
                return volumeValue <= 0.001
            }
        }
        return false
    }

    private nonisolated static func defaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - Transcript noise filter

enum ClickyTranscriptNoiseFilter {
    private static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "hmm", "hm", "mm", "mmm", "mhm", "ah", "eh", "er", "oh", "huh", "hmmm"
    ]

    /// True for empty, punctuation-only, or filler-only transcripts (stray noise).
    /// Short real answers such as "no", "ok" or "5" are kept.
    static func isNoise(_ transcript: String) -> Bool {
        let letters = transcript.filter { $0.isLetter || $0.isNumber }
        if letters.isEmpty { return true }
        let words = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy { fillerWords.contains($0) }
    }
}

// MARK: - Provider safety filter

struct ClickySafetyFilterError: LocalizedError {
    var errorDescription: String? { ClickyVoiceMessages.providerSafetyFilterBlocked }
}

enum ClickySafetyFilterDetector {
    /// Anthropic stream: `message_delta` carrying `delta.stop_reason == "refusal"`.
    static func isAnthropicRefusal(_ object: [String: Any]) -> Bool {
        if let delta = object["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" { return true }
        if let message = object["message"] as? [String: Any], message["stop_reason"] as? String == "refusal" { return true }
        return false
    }

    /// OpenAI stream: `choices[0].finish_reason == "content_filter"`.
    static func isOpenAIContentFilter(_ object: [String: Any]) -> Bool {
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return false }
        return first["finish_reason"] as? String == "content_filter"
    }

    /// Gemini: `candidates[0].finishReason == "SAFETY"` or `promptFeedback.blockReason` present.
    static func isGeminiSafetyBlock(_ object: [String: Any]) -> Bool {
        if let feedback = object["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { return true }
        if let candidates = object["candidates"] as? [[String: Any]],
           let reason = candidates.first?["finishReason"] as? String, reason == "SAFETY" {
            return true
        }
        return false
    }
}

// MARK: - Audio gates

enum ClickyAudioRoutePolicy {
    /// Voice processing (AEC) is only useful, and only safe, on the built-in speaker/mic path.
    /// Bluetooth/headphones would force the low-quality HFP profile and need no echo cancelling.
    static func shouldUseVoiceProcessing(outputIsBluetooth: Bool, outputIsHeadphones: Bool) -> Bool {
        !outputIsBluetooth && !outputIsHeadphones
    }

    /// Always-on voice requires headphones (otherwise it hears itself).
    static func canStartAlwaysOnVoice(outputIsBluetooth: Bool, outputIsHeadphones: Bool) -> Bool {
        outputIsBluetooth || outputIsHeadphones
    }
}
