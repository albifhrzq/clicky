//
//  ClickySpotifyTipMonitor.swift
//  Shows a one-time notch tip the first time Spotify is brought to the front.
//

import AppKit
import Foundation

@MainActor
final class ClickySpotifyTipMonitor {
    static let shared = ClickySpotifyTipMonitor()

    static let hasShownDefaultsKey = "clicky_has_shown_spotify_tip"
    static let spotifyBundleIdentifier = "com.spotify.client"
    static let tryItPrompt = "Play Good Morning by Kanye West on Spotify. Use osascript (tell application \"Spotify\" to play track \"spotify:track:<id>\"), finding the track id with web search."

    private weak var companionManager: CompanionManager?
    private var activationObserver: NSObjectProtocol?

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedBundleIdentifier = activatedApplication?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.handleActivation(bundleIdentifier: activatedBundleIdentifier)
            }
        }
    }

    private func handleActivation(bundleIdentifier: String?) {
        guard bundleIdentifier == Self.spotifyBundleIdentifier,
              !UserDefaults.standard.bool(forKey: Self.hasShownDefaultsKey),
              UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
              // While the tour runs we leave the flag unset so the next activation retries.
              companionManager?.onboardingTourController.isActive == false,
              // A pending morning card would hide the tip; leave the flag unset so the next activation retries.
              NotchWindowManager.shared.pendingMorningSuggestions == nil
        else { return }

        UserDefaults.standard.set(true, forKey: Self.hasShownDefaultsKey)
        NotchWindowManager.shared.presentSpotifyTipCard()
    }
}
