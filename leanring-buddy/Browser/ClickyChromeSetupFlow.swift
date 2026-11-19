//
//  ClickyChromeSetupFlow.swift
//  leanring-buddy
//
//  Handles heyclicky://settings/browser deep-links, Chrome Web Store extension
//  installation, and old unpacked preview copy swap detection/guidance.
//

import AppKit
import Combine
import Foundation

extension Notification.Name {
    public static let clickyOpenBrowserSettings = Notification.Name("clickyOpenBrowserSettings")
}

@MainActor
public final class ClickyChromeSetupFlow: ObservableObject {
    public static let shared = ClickyChromeSetupFlow()

    public static let chromeWebStoreURL = URL(
        string: "https://chromewebstore.google.com/detail/heyclicky/bphdnlcghkpiaoiplkhfofpfboddahce"
    )!

    private static let oldPreviewExtensionIDPrefix = "pijeb"
    private static let oldCopyToRemoveDefaultsKey = "clicky.browserConnection.oldCopyToRemove.v1"

    public enum Choice: String, Sendable {
        case doItForMe
        case showMeHow
        case notNow
    }

    public enum SetupState: Equatable, Sendable {
        case noChromiumBrowser
        case needsExtension(browserName: String)
        case awaitingExtensionConnection(browserName: String)
        case needsOldCopyRemoval(browserName: String)
        case connected(browserName: String, profileCount: Int)
        case failed(message: String)
    }

    @Published public private(set) var setupState: SetupState = .noChromiumBrowser
    @Published public private(set) var isShowingHow: Bool = false
    @Published public private(set) var isSettingUpForThem: Bool = false
    @Published public private(set) var hasOldCopyToRemove: Bool = false
    @Published public private(set) var installedBrowsers: [ClickyChromiumBrowserDescriptor] = []
    @Published public var preferredBrowserName: String = "Google Chrome"
    @Published public private(set) var didRequestBrowserSettings: Bool = false
    @Published public private(set) var lastDeepLinkURL: URL?

    private var cancellables = Set<AnyCancellable>()
    private var isAwaitingConnection: Bool = false

    private init() {
        self.hasOldCopyToRemove = UserDefaults.standard.bool(forKey: Self.oldCopyToRemoveDefaultsKey)
        observeBridge()
        refreshSetupState()
    }

    // MARK: - Deep Link Routing

    /// Handles deep-links such as `heyclicky://settings/browser` or `clicky://settings/browser`.
    @discardableResult
    public func handleDeepLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "heyclicky" || scheme == "clicky" else {
            return false
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        let isBrowserSettingsRoute =
            (host == "settings" && (path == "/browser" || path == "/chrome" || path == "/integrations/browser"))
            || (host == "browser" && (path.isEmpty || path == "/" || path == "/setup"))

        guard isBrowserSettingsRoute else {
            return false
        }

        lastDeepLinkURL = url
        didRequestBrowserSettings = true

        ClickyBrowserBridge.shared.start()
        refreshSetupState()

        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .clickyOpenBrowserSettings, object: url)
        return true
    }

    public func clearPendingBrowserSettingsRequest() {
        didRequestBrowserSettings = false
    }

    // MARK: - State Inspection

    public func refreshSetupState() {
        let bridge = ClickyBrowserBridge.shared
        let browsers = bridge.installedChromiumBrowsers()
        installedBrowsers = browsers

        let detectedOldCopy = detectOldUnpackedExtensionCopy()
        hasOldCopyToRemove = detectedOldCopy
        UserDefaults.standard.set(detectedOldCopy, forKey: Self.oldCopyToRemoveDefaultsKey)

        if let firstError = bridge.nativeHostSetupErrors.first {
            setupState = .failed(
                message: String(localized: "Clicky couldn't set up the browser connection: \(firstError.underlyingDescription)")
            )
            return
        }

        guard let targetBrowser = preferredBrowserDescriptor(from: browsers) else {
            setupState = .noChromiumBrowser
            return
        }

        preferredBrowserName = targetBrowser.displayName

        if bridge.isConnected {
            let activeBrowser = bridge.connectedBrowsers.first ?? targetBrowser.displayName
            if detectedOldCopy {
                setupState = .needsOldCopyRemoval(browserName: activeBrowser)
            } else {
                setupState = .connected(
                    browserName: activeBrowser,
                    profileCount: max(1, bridge.profiles.count)
                )
            }
            isAwaitingConnection = false
            isSettingUpForThem = false
            return
        }

        if isAwaitingConnection {
            setupState = .awaitingExtensionConnection(browserName: targetBrowser.displayName)
        } else {
            setupState = .needsExtension(browserName: targetBrowser.displayName)
        }
    }

    // MARK: - Chrome Web Store Setup & Swap Actions

    public func choose(_ choice: Choice) {
        switch choice {
        case .doItForMe:
            isSettingUpForThem = true
            isShowingHow = false
            openChromeWebStore()
        case .showMeHow:
            isShowingHow = true
            isSettingUpForThem = false
            openChromeWebStore()
        case .notNow:
            isShowingHow = false
            isSettingUpForThem = false
            isAwaitingConnection = false
            refreshSetupState()
        }
    }

    public func openChromeWebStore(in browser: ClickyChromiumBrowserDescriptor? = nil) {
        let bridge = ClickyBrowserBridge.shared
        bridge.start()

        let browsers = bridge.installedChromiumBrowsers()
        installedBrowsers = browsers

        guard let targetBrowser = browser ?? preferredBrowserDescriptor(from: browsers) else {
            openNoChromiumBrowserGuide()
            refreshSetupState()
            return
        }

        preferredBrowserName = targetBrowser.displayName
        isAwaitingConnection = true
        setupState = .awaitingExtensionConnection(browserName: targetBrowser.displayName)

        openURL(Self.chromeWebStoreURL, in: targetBrowser)
    }

    public func openExtensionsPageForSwap(in browser: ClickyChromiumBrowserDescriptor? = nil) {
        let browsers = ClickyBrowserBridge.shared.installedChromiumBrowsers()
        let targetBrowser = browser ?? preferredBrowserDescriptor(from: browsers)

        guard let targetBrowser else {
            openNoChromiumBrowserGuide()
            return
        }

        if let extensionsURL = URL(string: targetBrowser.extensionsPageURL) {
            openURL(extensionsURL, in: targetBrowser)
        }
    }

    public func openNoChromiumBrowserGuide() {
        if let setupHTMLURL = Bundle.main.url(forResource: "ClickyBrowserSetup", withExtension: "html") {
            NSWorkspace.shared.open(setupHTMLURL)
            return
        }
        if let fallbackChromeDownload = URL(string: "https://www.google.com/chrome/") {
            NSWorkspace.shared.open(fallbackChromeDownload)
        }
    }

    @discardableResult
    public func removeOldPreviewExtensionFolderIfPresent() -> Bool {
        let legacyExtensionFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clicky/HeyClicky Chrome Extension", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyExtensionFolder.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: legacyExtensionFolder)
            refreshSetupState()
            return true
        } catch {
            return false
        }
    }

    /// Detects whether an old unpacked preview copy of the HeyClicky Chrome extension
    /// (whose extension ID starts with `pijeb`) or legacy unpacked folder is present.
    public func detectOldUnpackedExtensionCopy() -> Bool {
        let fileManager = FileManager.default
        let legacyExtensionFolder = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clicky/HeyClicky Chrome Extension", isDirectory: true)
        if fileManager.fileExists(atPath: legacyExtensionFolder.path) {
            return true
        }

        for browser in ClickyBrowserBridge.supportedBrowsers {
            let userDataDir = browser.userDataDirectory()
            guard fileManager.fileExists(atPath: userDataDir.path),
                  let children = try? fileManager.contentsOfDirectory(
                      at: userDataDir,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for profileDir in children {
                let name = profileDir.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") else { continue }
                let preferencesURL = profileDir.appendingPathComponent("Preferences", isDirectory: false)
                if let data = try? Data(contentsOf: preferencesURL),
                   let text = String(data: data, encoding: .utf8),
                   text.contains(Self.oldPreviewExtensionIDPrefix) {
                    return true
                }
            }
        }

        return false
    }

    /// Guided step for the old unpacked path. Toggling Developer mode for the user is not
    /// safe (it means editing the browser's own preferences), so we only tell them where it is.
    public static var developerModeStepInstruction: String {
        String(localized: "Turn on Developer mode (top right of chrome://extensions).")
    }

    /// Generates concise guided instructions for swapping out the old preview copy
    /// or adding the extension from the Chrome Web Store.
    public func swapOrInstallInstructions(for browserName: String? = nil) -> String {
        let targetName = browserName ?? preferredBrowserName
        if hasOldCopyToRemove {
            return [
                String(localized: "Open \(targetName) extensions and find the old Clicky preview copy (turned off, unpacked, or showing an error)."),
                Self.developerModeStepInstruction,
                String(localized: "Click Remove on that old card and confirm Remove."),
                String(localized: "Add the Clicky extension from the Chrome Web Store: \(Self.chromeWebStoreURL.absoluteString)")
            ].enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        return String(localized: "Finish in \(targetName): add Clicky from the Chrome Web Store. It connects by itself.")
    }

    // MARK: - Extension Update Prompt

    /// "Swap" means replacing an old, manually installed (unpacked) copy with the Web Store
    /// extension, which updates itself. The Web Store build numbers (e.g. 0.6.x) are not the
    /// app's version, so the prompt depends only on an old copy being present.
    /// Pure rule: prompt only when an old copy exists AND no agent job is using the browser.
    nonisolated public static func shouldPromptExtensionSwap(hasOldCopy: Bool, isAnyJobRunning: Bool) -> Bool {
        hasOldCopy && !isAnyJobRunning
    }

    /// Whether the "There's a new version of the extension" prompt should show right now.
    public var shouldShowNewExtensionPrompt: Bool {
        Self.shouldPromptExtensionSwap(
            hasOldCopy: hasOldCopyToRemove,
            isAnyJobRunning: !AgentHarnessRunnerRuntime.shared.activeJobIDs.isEmpty
        )
    }

    /// True while a job is running and a swap is pending, so the UI can say it will wait.
    public var isNewExtensionPromptWaitingForIdle: Bool {
        hasOldCopyToRemove && !AgentHarnessRunnerRuntime.shared.activeJobIDs.isEmpty
    }

    // MARK: - Private Helpers

    private func observeBridge() {
        let bridge = ClickyBrowserBridge.shared
        bridge.$isConnected
            .sink { [weak self] _ in
                self?.refreshSetupState()
            }
            .store(in: &cancellables)

        bridge.$connectedBrowsers
            .sink { [weak self] _ in
                self?.refreshSetupState()
            }
            .store(in: &cancellables)
    }

    private func preferredBrowserDescriptor(from browsers: [ClickyChromiumBrowserDescriptor]) -> ClickyChromiumBrowserDescriptor? {
        if let exact = browsers.first(where: { $0.displayName == preferredBrowserName }) {
            return exact
        }
        if let chrome = browsers.first(where: { $0.id == "google-chrome" }) {
            return chrome
        }
        return browsers.first
    }

    private func openURL(_ url: URL, in browser: ClickyChromiumBrowserDescriptor) {
        for bundleIdentifier in browser.bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }
}
