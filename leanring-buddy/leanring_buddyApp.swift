//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls, alongside the
//  Notch peek and expandable HeyClicky window.
//

import AppKit
import CoreServices
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives in the menu bar panel, notch overlay, and expandable window.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene and also hooks SwiftUI's onOpenURL deep-link handler.
        Settings {
            EmptyView()
                .onOpenURL { url in
                    appDelegate.handleDeepLinkURL(url)
                }
        }
    }
}

/// Manages the companion lifecycle: single-instance enforcement, deep-link routing,
/// background core services, Sparkle idle updates, menu bar panel, and UI controllers.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private static let loginItemRegistrationSettledKey = "clicky.loginItem.registrationSettled.v1"

    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdateDelegate: SparkleUpdateDelegate?
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    private var isTerminatingDuplicateInstance = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !enforceSingleInstanceIfNeeded() {
            isTerminatingDuplicateInstance = true
            return
        }

        registerAppleEventGetURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isTerminatingDuplicateInstance else { return }

        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        startCoreServices()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()

        NotchWindowManager.shared.start(companionManager: companionManager)
        HeyClickyWindowController.shared.configure(companionManager: companionManager)

        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }

        registerAsLoginItemIfNeeded()
        startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isTerminatingDuplicateInstance else { return }

        sparkleUpdateDelegate?.stopIdlePolling()
        companionManager.stop()
        ClickyRoutineScheduler.shared.stop()
        ClickyBrowserBridge.shared.stop()
        ClickyLoopbackMCPServer.shared.stop()
        ClickyLocalAgentShim.shared.stop()
        ClickyAudioTopologyMonitor.shared.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleDeepLinkURL(url)
        }
    }

    // MARK: - Single-Instance Enforcement

    /// Ensures only one Clicky process runs at a time. If another running instance
    /// shares our bundle identifier, activates it and terminates this duplicate.
    private func enforceSingleInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return true
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningDuplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { runningApp in
                runningApp.processIdentifier != currentPID && !runningApp.isTerminated
            }

        guard let existingInstance = runningDuplicates.first else {
            return true
        }

        print("🎯 Clicky: Another instance is already running (PID \(existingInstance.processIdentifier)). Activating existing instance and exiting.")
        existingInstance.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Deep-Link Routing (NSAppleEventManager + SwiftUI onOpenURL)

    private func registerAppleEventGetURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleAppleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleAppleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        handleDeepLinkURL(url)
    }

    func handleDeepLinkURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "heyclicky" || scheme == "clicky" else {
            return
        }

        print("🔗 Clicky: Handling deep-link \(url.absoluteString)")
        NSApp.activate(ignoringOtherApps: true)

        // Browser setup deep-links (e.g. heyclicky://settings/browser)
        if ClickyChromeSetupFlow.shared.handleDeepLink(url) {
            HeyClickyWindowController.shared.open(initialTab: .settings)
            return
        }

        let host = url.host?.lowercased() ?? ""
        let pathComponents = url.pathComponents
            .filter { component in component != "/" }
            .map { component in component.lowercased() }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        func queryValue(_ names: [String]) -> String? {
            queryItems.first(where: { item in
                names.contains(item.name.lowercased())
            })?.value
        }

        let requestedSlug = queryValue(["slug", "clicky", "selectedslug"])
        let requestedDocumentPath = queryValue(["document", "documentpath", "path"])
        let requestedTab = resolvedNotchTab(
            host: host,
            pathComponents: pathComponents,
            explicitTabParam: queryValue(["tab"])
        )

        switch host {
        case "notch", "peek":
            NotchWindowManager.shared.showNotchPeek(tab: requestedTab)

        case "settings":
            HeyClickyWindowController.shared.open(
                selectedSlug: requestedSlug,
                documentPath: requestedDocumentPath,
                initialTab: .settings
            )

        case "window", "open", "chat", "home":
            HeyClickyWindowController.shared.open(
                selectedSlug: requestedSlug,
                documentPath: requestedDocumentPath,
                initialTab: requestedTab
            )

        case "document":
            if let requestedDocumentPath, !requestedDocumentPath.isEmpty {
                HeyClickyWindowController.shared.open(
                    selectedSlug: requestedSlug,
                    documentPath: requestedDocumentPath,
                    initialTab: .document
                )
            } else {
                NotchWindowManager.shared.showNotchPeek(tab: .document)
            }

        default:
            NotchWindowManager.shared.showNotchPeek(tab: requestedTab)
        }
    }

    private func resolvedNotchTab(
        host: String,
        pathComponents: [String],
        explicitTabParam: String?
    ) -> ClickyNotchTab {
        let candidate = (explicitTabParam ?? pathComponents.first ?? host).lowercased()
        switch candidate {
        case "chat":
            return .chat
        case "settings":
            return .settings
        case "document", "doc":
            return .document
        default:
            return .home
        }
    }

    // MARK: - Background Core Services

    private func startCoreServices() {
        ClickyAudioTopologyMonitor.shared.start()
        ClickySoundEffectPlayer.shared.preloadCommonEffects()
        ClickyJobStore.shared.markInterruptedWorkingJobsOnLaunch()

        // Start loopback MCP server and browser extension native messaging bridge.
        do {
            try ClickyLoopbackMCPServer.shared.start()
        } catch {
            print("⚠️ Clicky: Loopback MCP server failed to start: \(error.localizedDescription)")
        }
        ClickyBrowserBridge.shared.start()

        // Warm up the local OpenCodex / BYOK agent HTTP shim asynchronously.
        Task { @MainActor in
            do {
                let shimURL = try await ClickyLocalAgentShim.shared.ensureStarted()
                print("🚀 Clicky: Local agent shim listening at \(shimURL.absoluteString)")
            } catch {
                print("⚠️ Clicky: Failed to start local agent shim: \(error.localizedDescription)")
            }
        }

        // Wire scheduled routine execution into CompanionManager and start scheduler.
        ClickyRoutineScheduler.shared.onDispatchRoutine = { [weak self] routine, trigger in
            guard let self else {
                return .failed(summary: "Application is shutting down.", transientConnectivity: false)
            }
            return await self.companionManager.executeScheduledRoutine(routine, trigger: trigger)
        }
        ClickyRoutineScheduler.shared.start()
    }

    // MARK: - Login Item Registration

    /// Registers the app as a login item on initial setup only, guarded by
    /// `clicky.loginItem.registrationSettled.v1` so user opt-outs in System Settings
    /// are respected across future launches.
    private func registerAsLoginItemIfNeeded() {
        let defaults = UserDefaults.standard
        let loginItemService = SMAppService.mainApp

        if loginItemService.status == .enabled {
            defaults.set(true, forKey: Self.loginItemRegistrationSettledKey)
            return
        }

        guard !defaults.bool(forKey: Self.loginItemRegistrationSettledKey) else {
            return
        }

        do {
            try loginItemService.register()
            defaults.set(true, forKey: Self.loginItemRegistrationSettledKey)
            print("🎯 Clicky: Registered as login item")
        } catch {
            print("⚠️ Clicky: Failed to register as login item: \(error)")
        }
    }

    // MARK: - Sparkle Updater (IdleUpdateInstallPolicy)

    private func startSparkleUpdater() {
        let updateDelegate = SparkleUpdateDelegate(
            defaults: .standard,
            conditionsProvider: { [weak self] in
                guard let self else {
                    return IdleUpdateInstallConditions(secondsSinceHeyClickyWasLastBusy: 0)
                }
                return self.companionManager.currentIdleUpdateInstallConditions()
            }
        )
        self.sparkleUpdateDelegate = updateDelegate
        NotchWindowManager.shared.bindSparkleUpdateDelegate(updateDelegate)

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updateDelegate,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
