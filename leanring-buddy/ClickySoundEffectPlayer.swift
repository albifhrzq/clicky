//
//  ClickySoundEffectPlayer.swift
//  leanring-buddy
//

import Foundation
import AVFoundation

public enum ClickySoundEffect: String {
    case agentLaunch = "agent-launch.wav"
    case agentDone = "agent-done.wav"
    case agentClose = "agent-close.wav"
    case gelPop = "gel-pop-1.wav"
    case badgePop = "badge-pop-1.wav"
    case ding = "ding-1.wav"
    case tada = "tada-1.wav"
    case slide = "slide-1.wav"
    case pencilBed = "pencil-paper-bed-1.wav"
    case highlighter = "highlighter-1.wav"
    case enter = "enter.mp3"
}

public final class ClickySoundEffectPlayer {
    public static let shared = ClickySoundEffectPlayer()

    private var audioPlayers: [String: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "com.clicky.sound-player", qos: .userInitiated)

    private init() {}

    public func play(_ sound: ClickySoundEffect) {
        guard ClickyConfiguration.shared.soundEffectsEnabled else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            let filename = sound.rawValue

            if let existingPlayer = self.audioPlayers[filename] {
                existingPlayer.currentTime = 0
                existingPlayer.play()
                return
            }

            // Find sound in main bundle or Resources subdirectory
            let ext = (filename as NSString).pathExtension
            let name = (filename as NSString).deletingPathExtension

            var soundURL = Bundle.main.url(forResource: name, withExtension: ext)
            if soundURL == nil {
                soundURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            }

            guard let url = soundURL else { return }

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.play()
                self.audioPlayers[filename] = player
            } catch {
                // Ignore audio playback failure
            }
        }
    }
}
