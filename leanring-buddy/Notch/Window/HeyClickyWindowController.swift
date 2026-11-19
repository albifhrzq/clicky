//
//  HeyClickyWindowController.swift
//  leanring-buddy
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Custom NSWindow subclass allowing borderless/fullSizeContentView window
/// to accept key status and keyboard shortcuts reliably in an LSUIElement app.
private final class HeyClickyMainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class HeyClickyWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = HeyClickyWindowController()

    // MARK: - Persistence Keys

    static let frameDefaultsKey = "clicky.heyClickyWindow.frame.v1"
    static let sidebarShownDefaultsKey = "clicky.heyClickyWindow.sidebarShown.v1"
    static let documentWidthDefaultsKey = "clicky.heyClickyWindow.documentWidth.v1"

    static let minimumWindowSize = NSSize(width: 760, height: 520)
    static let defaultWindowSize = NSSize(width: 1120, height: 720)
    static let minimumDocumentWidth: CGFloat = 280
    static let maximumDocumentWidth: CGFloat = 720
    static let defaultDocumentWidth: CGFloat = 390

    // MARK: - Published UI State

    @Published var activeTab: ClickyNotchTab = .chat
    @Published var selectedSlug: String? = nil
    @Published var selectedDocumentURL: URL? = nil
    @Published var isDocumentColumnVisible: Bool = false
    @Published var isSidebarShown: Bool {
        didSet {
            defaults.set(isSidebarShown, forKey: Self.sidebarShownDefaultsKey)
        }
    }
    @Published var documentColumnWidth: CGFloat {
        didSet {
            defaults.set(Double(documentColumnWidth), forKey: Self.documentWidthDefaultsKey)
        }
    }
    @Published private(set) var isWindowOpen: Bool = false
    @Published var activeSettingsSection: HomeSpaceSettingsSection = .general

    // MARK: - Dependencies & Window

    private let defaults: UserDefaults
    private var window: HeyClickyMainWindow?
    private var hostingView: NSHostingView<AnyView>?
    private(set) var companionManager: CompanionManager?

    private override init() {
        let userDefaults = UserDefaults.standard
        self.defaults = userDefaults

        if userDefaults.object(forKey: Self.sidebarShownDefaultsKey) == nil {
            self.isSidebarShown = true
        } else {
            self.isSidebarShown = userDefaults.bool(forKey: Self.sidebarShownDefaultsKey)
        }

        let storedWidth = userDefaults.double(forKey: Self.documentWidthDefaultsKey)
        if storedWidth > 0 {
            self.documentColumnWidth = Self.clampedDocumentWidth(CGFloat(storedWidth))
        } else {
            self.documentColumnWidth = Self.defaultDocumentWidth
        }

        super.init()
    }

    // MARK: - Public Contract

    func configure(companionManager: CompanionManager) {
        self.companionManager = companionManager
        if let hostingView {
            hostingView.rootView = makeRootSwiftUIView(companionManager: companionManager)
        }
    }

    func open(
        selectedSlug: String? = nil,
        documentPath: String? = nil,
        initialTab: ClickyNotchTab = .chat
    ) {
        self.selectedSlug = selectedSlug

        if let slug = selectedSlug, !slug.isEmpty {
            markThreadAsRead(slug: slug)
        }

        if let documentPath, !documentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedPath = documentPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.lowercased().hasPrefix("http://") || trimmedPath.lowercased().hasPrefix("https://"),
               let webURL = URL(string: trimmedPath) {
                self.selectedDocumentURL = webURL
            } else {
                self.selectedDocumentURL = URL(fileURLWithPath: trimmedPath)
            }
            self.isDocumentColumnVisible = true
        }

        switch initialTab {
        case .document:
            self.activeTab = .chat
            self.isDocumentColumnVisible = true
        case .home, .chat, .settings:
            self.activeTab = initialTab
        }

        ensureWindowCreated()

        if let window {
            // Re-apply root view in case configure(companionManager:) was called before window creation
            if let companionManager, let hostingView {
                hostingView.rootView = makeRootSwiftUIView(companionManager: companionManager)
            }

            // Ensure an LSUIElement menu bar app activates so the user can type immediately
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            isWindowOpen = true
        }
    }

    func close() {
        saveWindowFrameIfPresent()
        window?.orderOut(nil)
        isWindowOpen = false
    }

    // MARK: - Workspace Actions

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: DS.Animation.fast)) {
            isSidebarShown.toggle()
        }
    }

    func selectThread(slug: String?) {
        selectedSlug = slug
        if activeTab != .chat {
            activeTab = .chat
        }
        if let slug, !slug.isEmpty {
            markThreadAsRead(slug: slug)
        }
    }

    func openDocument(atPath path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"),
           let webURL = URL(string: trimmed) {
            openDocument(url: webURL)
        } else {
            openDocument(url: URL(fileURLWithPath: trimmed))
        }
    }

    func openDocument(url: URL) {
        selectedDocumentURL = url
        withAnimation(.easeInOut(duration: DS.Animation.fast)) {
            isDocumentColumnVisible = true
        }
    }

    func openActiveDocumentContext() {
        if let reference = companionManager?.activeDocumentContext?.reference {
            switch reference {
            case .file(let path, _):
                selectedDocumentURL = URL(fileURLWithPath: path)
            case .webPage(let urlString, _):
                selectedDocumentURL = URL(string: urlString)
            }
        } else {
            selectedDocumentURL = nil
        }
        withAnimation(.easeInOut(duration: DS.Animation.fast)) {
            isDocumentColumnVisible = true
        }
    }

    func closeDocumentColumn() {
        withAnimation(.easeInOut(duration: DS.Animation.fast)) {
            isDocumentColumnVisible = false
        }
    }

    func updateDocumentColumnWidth(_ proposedWidth: CGFloat) {
        documentColumnWidth = Self.clampedDocumentWidth(proposedWidth)
    }

    func openSettings(section: HomeSpaceSettingsSection = .general) {
        activeSettingsSection = section
        activeTab = .settings
    }

    func collapseToNotch() {
        let targetTab: ClickyNotchTab = (activeTab == .settings) ? .settings : (activeTab == .home ? .home : .chat)
        close()
        NotchWindowManager.shared.showNotchPeek(tab: targetTab)
    }

    // MARK: - Window Lifecycle

    private func ensureWindowCreated() {
        if let existingWindow = window {
            let restoredFrame = validatedSavedFrame() ?? defaultCenteredFrame()
            if !existingWindow.isVisible {
                existingWindow.setFrame(restoredFrame, display: false)
            }
            return
        }

        let initialFrame = validatedSavedFrame() ?? defaultCenteredFrame()

        let createdWindow = HeyClickyMainWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "HeyClicky"
        // Lets the cursor buddy's local mouse-moved monitor keep following while the pointer is over this window.
        createdWindow.acceptsMouseMovedEvents = true
        createdWindow.titleVisibility = .hidden
        createdWindow.titlebarAppearsTransparent = true
        createdWindow.isMovableByWindowBackground = true
        createdWindow.isReleasedWhenClosed = false
        createdWindow.minSize = Self.minimumWindowSize
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = true
        createdWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        createdWindow.delegate = self

        let rootView: AnyView
        if let companionManager {
            rootView = makeRootSwiftUIView(companionManager: companionManager)
        } else {
            rootView = AnyView(
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Initializing HeyClicky...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ClickyPanelBackground(cornerRadius: 14, usesTranslucentMaterial: true))
            )
        }

        let hosted = NSHostingView(rootView: rootView)
        hosted.wantsLayer = true
        hosted.layer?.backgroundColor = NSColor.clear.cgColor
        hosted.autoresizingMask = [.width, .height]
        hosted.frame = NSRect(origin: .zero, size: initialFrame.size)

        createdWindow.contentView = hosted
        self.hostingView = hosted
        self.window = createdWindow
    }

    private func makeRootSwiftUIView(companionManager: CompanionManager) -> AnyView {
        AnyView(
            HeyClickyWindowView(
                windowController: self,
                companionManager: companionManager
            )
        )
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        saveWindowFrameIfPresent()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrameIfPresent()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowFrameIfPresent()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrameIfPresent()
        isWindowOpen = false
    }

    // MARK: - Frame & Read State Helpers

    private func saveWindowFrameIfPresent() {
        guard let window else { return }
        let frame = window.frame
        guard frame.width >= Self.minimumWindowSize.width,
              frame.height >= Self.minimumWindowSize.height else {
            return
        }
        defaults.set(NSStringFromRect(frame), forKey: Self.frameDefaultsKey)
    }

    private func validatedSavedFrame() -> NSRect? {
        guard let savedString = defaults.string(forKey: Self.frameDefaultsKey),
              !savedString.isEmpty else {
            return nil
        }

        var parsedRect = NSRectFromString(savedString)
        guard parsedRect.width > 0, parsedRect.height > 0 else {
            return nil
        }

        parsedRect.size.width = max(parsedRect.size.width, Self.minimumWindowSize.width)
        parsedRect.size.height = max(parsedRect.size.height, Self.minimumWindowSize.height)

        // Verify the restored frame sits visibly on at least one connected screen
        let visibleScreens = NSScreen.screens
        let intersectsAnyScreen = visibleScreens.contains { screen in
            let intersection = screen.visibleFrame.intersection(parsedRect)
            return intersection.width >= 120 && intersection.height >= 120
        }
        guard intersectsAnyScreen else {
            return nil
        }

        return parsedRect
    }

    private func defaultCenteredFrame() -> NSRect {
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(Self.defaultWindowSize.width, max(Self.minimumWindowSize.width, visibleFrame.width - 80))
        let height = min(Self.defaultWindowSize.height, max(Self.minimumWindowSize.height, visibleFrame.height - 80))
        let originX = visibleFrame.midX - (width / 2)
        let originY = visibleFrame.midY - (height / 2)
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    private func markThreadAsRead(slug: String) {
        ClickyRoster.shared.markRead(slug: slug)
        for job in ClickyJobStore.shared.jobs(forClickySlug: slug) where !job.isSeen {
            ClickyJobStore.shared.markSeen(jobID: job.id)
        }
    }

    private nonisolated static func clampedDocumentWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumDocumentWidth), maximumDocumentWidth)
    }
}
