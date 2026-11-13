//
//  ClickySoundEffectPlayer.swift
//  leanring-buddy
//
//  Plays bundled acoustic UI sound effects on a nonisolated serial queue
//  with Bluetooth/wired pre-roll silence warmup so cold audio routes never clip chimes.
//

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

public enum ClickySoundEffect: String, CaseIterable, Sendable {
    case agentLaunch = "agent-launch.wav"
    case agentDone = "agent-done.wav"
    case agentClose = "agent-close.wav"
    case agentNeedsYou = "agent-needs-you.wav"
    case gelPop = "gel-pop-1.wav"
    case badgePop = "badge-pop-1.wav"
    case ding = "ding-1.wav"
    case tada = "tada-1.wav"
    case slide = "slide-1.wav"
    case sparkle = "sparkle-1.wav"
    case stamp = "stamp-1.wav"
    case stickyPress = "sticky-press-1.wav"
    case buttonAppear = "button-appear-1.wav"
    case tapbackThumbsUp = "tapback-thumbs-up.wav"
    case whoosh = "whoosh-1.wav"
    case nope = "nope-1.wav"
    case enter = "enter.mp3"
    case clickyTextOpen = "clicky-text-open.wav"
    case clickyTextClose = "clicky-text-close.wav"
    case clickyTextSend = "clicky-text-send.wav"
    case clickyTextReceive = "clicky-text-receive.wav"
    case clickyQuestion = "clicky-question.wav"
    case clickySurprised = "clicky-surprised.wav"
    case homeReveal = "home-reveal.wav"
    case revealBoot = "reveal-boot.wav"
    case skillUp = "skill-up.wav"
    case skillDown = "skill-down.wav"
    case pencilBed = "pencil-paper-bed-1.wav"
    case highlighter = "highlighter-1.wav"
}

private nonisolated final class SoundEffectPlaybackEngine: @unchecked Sendable {
    private let playbackQueue = DispatchQueue(
        label: "com.clicky.sound-player",
        qos: .userInitiated
    )
    private var audioPlayers: [String: AVAudioPlayer] = [:]
    private var warmupSilencePlayer: AVAudioPlayer?
    private var lastAudioActivityAt: Date = .distantPast
    private var lastWarmOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var pendingChimeWorkItem: DispatchWorkItem?

    private static let warmRouteWindowSeconds: TimeInterval = 2.0

    func play(
        filename: String,
        preRollSilenceDuration: TimeInterval,
        outputDeviceID: AudioObjectID,
        volume: Float
    ) {
        playbackQueue.async { [weak self] in
            self?.performPlay(
                filename: filename,
                preRollSilenceDuration: preRollSilenceDuration,
                outputDeviceID: outputDeviceID,
                volume: volume
            )
        }
    }

    func preload(_ filenames: [String]) {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            for filename in filenames {
                _ = self.loadOrCreatePlayer(for: filename)
            }
        }
    }

    func stopAll() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.pendingChimeWorkItem?.cancel()
            self.pendingChimeWorkItem = nil
            self.warmupSilencePlayer?.stop()
            for player in self.audioPlayers.values {
                player.stop()
            }
        }
    }

    private func performPlay(
        filename: String,
        preRollSilenceDuration: TimeInterval,
        outputDeviceID: AudioObjectID,
        volume: Float
    ) {
        guard let chimePlayer = loadOrCreatePlayer(for: filename) else { return }

        let now = Date()
        let isSameDevice = outputDeviceID != kAudioObjectUnknown && outputDeviceID == lastWarmOutputDeviceID
        let isRouteRecentlyWarm = isSameDevice
            && now.timeIntervalSince(lastAudioActivityAt) < Self.warmRouteWindowSeconds

        pendingChimeWorkItem?.cancel()
        pendingChimeWorkItem = nil

        if isRouteRecentlyWarm || preRollSilenceDuration <= 0 {
            playPlayer(chimePlayer, volume: volume)
            lastAudioActivityAt = Date()
            lastWarmOutputDeviceID = outputDeviceID
            return
        }

        playWarmupSilence(duration: preRollSilenceDuration)
        lastWarmOutputDeviceID = outputDeviceID
        lastAudioActivityAt = now.addingTimeInterval(preRollSilenceDuration)

        let workItem = DispatchWorkItem { [weak self, weak chimePlayer] in
            guard let self, let chimePlayer else { return }
            self.playPlayer(chimePlayer, volume: volume)
            self.lastAudioActivityAt = Date()
        }
        pendingChimeWorkItem = workItem
        playbackQueue.asyncAfter(
            deadline: .now() + preRollSilenceDuration,
            execute: workItem
        )
    }

    private func playPlayer(_ player: AVAudioPlayer, volume: Float) {
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    private func loadOrCreatePlayer(for filename: String) -> AVAudioPlayer? {
        if let existingPlayer = audioPlayers[filename] {
            return existingPlayer
        }

        let fileExtension = (filename as NSString).pathExtension
        let baseName = (filename as NSString).deletingPathExtension

        let soundURL = Bundle.main.url(forResource: baseName, withExtension: fileExtension)
            ?? Bundle.main.url(forResource: baseName, withExtension: fileExtension, subdirectory: "Resources")

        guard let url = soundURL else { return nil }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            audioPlayers[filename] = player
            return player
        } catch {
            return nil
        }
    }

    private func playWarmupSilence(duration: TimeInterval) {
        let clampedDuration = max(0.05, min(duration, 1.0))
        let sampleRate = 44_100
        let sampleCount = Int((Double(sampleRate) * clampedDuration).rounded())
        let pcmByteCount = sampleCount * MemoryLayout<Int16>.size
        let silentPCMData = Data(count: pcmByteCount)
        let silentWAVData = Self.makeSilentWAVData(pcmData: silentPCMData, sampleRate: sampleRate)

        do {
            let silencePlayer = try AVAudioPlayer(data: silentWAVData)
            silencePlayer.volume = 0.0
            silencePlayer.prepareToPlay()
            silencePlayer.play()
            warmupSilencePlayer = silencePlayer
        } catch {
            // If warmup silence cannot be instantiated, chime playback will still proceed.
        }
    }

    private static func makeSilentWAVData(pcmData: Data, sampleRate: Int) -> Data {
        let channelCount = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataSize = UInt32(pcmData.count)
        let riffChunkSize = UInt32(36) + dataSize

        var wavData = Data(capacity: 44 + pcmData.count)
        wavData.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var littleEndianRiffSize = riffChunkSize.littleEndian
        wavData.append(Data(bytes: &littleEndianRiffSize, count: 4))
        wavData.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        wavData.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var fmtChunkSize = UInt32(16).littleEndian
        wavData.append(Data(bytes: &fmtChunkSize, count: 4))
        var audioFormatPCM = UInt16(1).littleEndian
        wavData.append(Data(bytes: &audioFormatPCM, count: 2))
        var littleEndianChannels = UInt16(channelCount).littleEndian
        wavData.append(Data(bytes: &littleEndianChannels, count: 2))
        var littleEndianSampleRate = UInt32(sampleRate).littleEndian
        wavData.append(Data(bytes: &littleEndianSampleRate, count: 4))
        var littleEndianByteRate = UInt32(byteRate).littleEndian
        wavData.append(Data(bytes: &littleEndianByteRate, count: 4))
        var littleEndianBlockAlign = UInt16(blockAlign).littleEndian
        wavData.append(Data(bytes: &littleEndianBlockAlign, count: 2))
        var littleEndianBitsPerSample = UInt16(bitsPerSample).littleEndian
        wavData.append(Data(bytes: &littleEndianBitsPerSample, count: 2))
        wavData.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var littleEndianDataSize = dataSize.littleEndian
        wavData.append(Data(bytes: &littleEndianDataSize, count: 4))
        wavData.append(pcmData)
        return wavData
    }
}

@MainActor
public final class ClickySoundEffectPlayer {
    public static let shared = ClickySoundEffectPlayer()

    private let playbackEngine = SoundEffectPlaybackEngine()

    private init() {}

    public func play(_ sound: ClickySoundEffect, volume: Float = 1.0) {
        guard ClickyConfiguration.shared.soundEffectsEnabled else { return }

        let topologySnapshot = ClickyAudioTopologyMonitor.shared.snapshot
        let preRollDuration = topologySnapshot.requiredPreRollSilenceDuration

        playbackEngine.play(
            filename: sound.rawValue,
            preRollSilenceDuration: preRollDuration,
            outputDeviceID: topologySnapshot.defaultOutputDeviceID,
            volume: volume
        )
    }

    public func preloadCommonEffects() {
        let commonEffects: [ClickySoundEffect] = [
            .agentLaunch, .agentDone, .agentClose, .agentNeedsYou,
            .gelPop, .badgePop, .ding, .tada,
            .clickyTextOpen, .clickyTextClose, .clickyTextSend, .clickyTextReceive
        ]
        playbackEngine.preload(commonEffects.map(\.rawValue))
    }

    public func stopAll() {
        playbackEngine.stopAll()
    }
}
