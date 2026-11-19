//
//  NotchWindowManager.swift
//  leanring-buddy
//
//  Multi-display hardware-notch-hugging non-activating NSPanel controller.
//  Calculates notch geometry via NSScreen.auxiliaryTopLeftArea /
//  auxiliaryTopRightArea / safeAreaInsets.top with a graceful floating pill
//  fallback on non-notch displays. Ignores mouse events outside the resting
//  pill when collapsed, auto-expands on hover/click or live system events
//  (upload approval, computer-use consent, TCC document notice), and collapses
//  cleanly on outside click or Escape.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Notch Tab

public enum ClickyNotchTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case chat
    case settings
    case document

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .home:
            return "Home"
        case .chat:
            return "Chat"
        case .settings:
            return "Settings"
        case .document:
            return "Document"
        }
    }

    public var systemImageName: String {
        switch self {
        case .home:
            return "sparkles"
        case .chat:
            return "bubble.left.and.bubble.right.fill"
        case .settings:
            return "slider.horizontal.3"
        case .document:
            return "doc.text.fill"
        }
    }
}

// MARK: - Screen Notch Geometry

public nonisolated struct NotchScreenGeometry: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let screenFrame: CGRect
    public let visibleFrame: CGRect
    public let hasHardwareNotch: Bool
    public let hardwareNotchRect: CGRect
    public let restingPillRect: CGRect
    public let activityPillRect: CGRect

    public static func resolve(for screen: NSScreen) -> NotchScreenGeometry {
        let displayID = Self.displayID(for: screen)
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0,
           let topLeft = screen.auxiliaryTopLeftArea,
           let topRight = screen.auxiliaryTopRightArea,
           topRight.minX - topLeft.maxX > 20 {
            let notchWidth = topRight.minX - topLeft.maxX
            let notchHeight = max(safeTop, topLeft.height, 32)
            let hardwareNotchRect = CGRect(
                x: topLeft.maxX,
                y: screenFrame.maxY - notchHeight,
                width: notchWidth,
                height: notchHeight
            )

            // Leave symmetric side wings beside the physical camera housing so
            // the brand mark, pulsing activity dot, and unread badge remain visible.
            let restingWingWidth: CGFloat = 54
            let restingWidth = notchWidth + (restingWingWidth * 2)
            let restingPillRect = CGRect(
                x: hardwareNotchRect.midX - (restingWidth / 2),
                y: screenFrame.maxY - notchHeight,
                width: restingWidth,
                height: notchHeight
            )

            let activityWingWidth: CGFloat = 94
            let activityWidth = notchWidth + (activityWingWidth * 2)
            let activityHeight = notchHeight + 4
            let activityPillRect = CGRect(
                x: hardwareNotchRect.midX - (activityWidth / 2),
                y: screenFrame.maxY - activityHeight,
                width: activityWidth,
                height: activityHeight
            )

            return NotchScreenGeometry(
                displayID: displayID,
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                hasHardwareNotch: true,
                hardwareNotchRect: hardwareNotchRect,
                restingPillRect: restingPillRect,
                activityPillRect: activityPillRect
            )
        }

        // Graceful pill fallback centered at the top edge on non-notch displays.
        let fallbackWidth: CGFloat = 156
        // Resting state is an invisible 156x22 hit area flush with the top edge (the visible handle is drawn inside it).
        let fallbackHeight: CGFloat = 22
        let fallbackTopMargin: CGFloat = 6
        let fallbackRestingTopMargin: CGFloat = 0
        let fallbackNotchRect = CGRect(
            x: screenFrame.midX - (fallbackWidth / 2),
            y: screenFrame.maxY - fallbackHeight - fallbackRestingTopMargin,
            width: fallbackWidth,
            height: fallbackHeight
        )

        let activityFallbackWidth: CGFloat = 248
        let activityFallbackHeight: CGFloat = 34
        let activityPillRect = CGRect(
            x: screenFrame.midX - (activityFallbackWidth / 2),
            y: screenFrame.maxY - activityFallbackHeight - fallbackTopMargin,
            width: activityFallbackWidth,
            height: activityFallbackHeight
        )

        return NotchScreenGeometry(
            displayID: displayID,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hasHardwareNotch: false,
            hardwareNotchRect: fallbackNotchRect,
            restingPillRect: fallbackNotchRect,
            activityPillRect: activityPillRect
        )
    }

    /// Side shadow margin on each side of the fixed canvas, so the panel shadow is not clipped.
    nonisolated static let canvasSideShadowMargin: CGFloat = 32
    /// Bottom shadow margin of the fixed canvas.
    nonisolated static let canvasBottomShadowMargin: CGFloat = 44

    /// Fixed, transparent panel frame: big enough for the largest expanded panel plus its shadow,
    /// so SwiftUI can morph the pill into the panel without the window ever resizing.
    nonisolated static func canvasRect(anchorMidX: CGFloat, screenFrame: CGRect, maximumPanelSize: CGSize) -> CGRect {
        let canvasWidth = min(maximumPanelSize.width + (canvasSideShadowMargin * 2), screenFrame.width)
        let canvasHeight = min(maximumPanelSize.height + canvasBottomShadowMargin, screenFrame.height)
        let rawOriginX = anchorMidX - (canvasWidth / 2)
        let originX = min(max(rawOriginX, screenFrame.minX), screenFrame.maxX - canvasWidth)
        return CGRect(x: originX, y: screenFrame.maxY - canvasHeight, width: canvasWidth, height: canvasHeight)
    }

    var canvasRect: CGRect {
        let anchorMidX = hasHardwareNotch ? hardwareNotchRect.midX : screenFrame.midX
        return Self.canvasRect(
            anchorMidX: anchorMidX,
            screenFrame: screenFrame,
            maximumPanelSize: NotchPanelMetrics.maximumExpandedSize
        )
    }

    /// The only part of the canvas that should take mouse events; the rest stays click-through.
    func interactiveRect(isExpanded: Bool, isActivityPillVisible: Bool, expandedContentSize: CGSize) -> CGRect {
        if isExpanded {
            return expandedPanelRect(for: expandedContentSize)
        }
        return isActivityPillVisible ? activityPillRect : restingPillRect
    }

    public func expandedPanelRect(for contentSize: CGSize) -> CGRect {
        let horizontalMargin: CGFloat = 12
        let clampedWidth = min(max(contentSize.width, 380), max(320, screenFrame.width - (horizontalMargin * 2)))
        let clampedHeight = min(max(contentSize.height, 220), max(220, screenFrame.height - 48))

        let anchorMidX = hasHardwareNotch ? hardwareNotchRect.midX : screenFrame.midX
        let rawOriginX = anchorMidX - (clampedWidth / 2)
        let minOriginX = screenFrame.minX + horizontalMargin
        let maxOriginX = max(minOriginX, screenFrame.maxX - clampedWidth - horizontalMargin)
        let originX = min(max(rawOriginX, minOriginX), maxOriginX)

        // Flush with the top edge on every display, like HeyClicky (the pill grows down from the edge).
        let originY = screenFrame.maxY - clampedHeight

        return CGRect(x: originX, y: originY, width: clampedWidth, height: clampedHeight)
    }

    public static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }
}

// MARK: - Non-Activating Keyable NSPanel

private final class NotchHostingPanel: NSPanel {
    var allowKeyFocus: Bool = false

    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { false }
}

// MARK: - Notch Window Manager

@MainActor
final class NotchWindowManager: ObservableObject {
    static let shared = NotchWindowManager()

    @Published var activeTab: ClickyNotchTab = .home {
        didSet {
            guard activeTab != oldValue else { return }
            // Width always comes from the tab (never from measurement, which would feed the animated
            // frame back into itself). Height keeps the last measurement until SwiftUI reports the new tab's.
            expandedContentSize = CGSize(
                width: NotchPanelMetrics.size(for: activeTab).width,
                height: expandedContentSize.height
            )
        }
    }
    @Published private(set) var isExpanded: Bool = false
    @Published private(set) var isHovered: Bool = false
    /// Which display's pill is hovered, so only that pill grows on hover.
    @Published private(set) var hoveredDisplayID: CGDirectDisplayID?
    @Published private(set) var activeDisplayID: CGDirectDisplayID?
    @Published private(set) var geometriesByDisplayID: [CGDirectDisplayID: NotchScreenGeometry] = [:]
    @Published private(set) var isActivityPillVisible: Bool = false
    @Published private(set) var pendingAppUpdateVersion: String?
    @Published private(set) var isTextInputFocused: Bool = false
    @Published private(set) var pendingMorningSuggestions: NotchMorningSuggestionsContent?
    @Published private(set) var pendingUpcomingMeeting: NotchUpcomingMeetingContent?
    @Published private(set) var pendingSpotifyTip: Bool = false

    var primaryDisplayID: CGDirectDisplayID? {
        if let mainScreen = NSScreen.main {
            return NotchScreenGeometry.displayID(for: mainScreen)
        }
        return NSScreen.screens.first.map { NotchScreenGeometry.displayID(for: $0) }
    }

    private weak var companionManager: CompanionManager?
    private var panelsByDisplayID: [CGDirectDisplayID: NotchHostingPanel] = [:]
    /// Measured size of the expanded content. Used for hit-testing and as the morph target; the panel itself never resizes.
    @Published private(set) var expandedContentSize: CGSize = NotchPanelMetrics.size(for: .home)
    /// Hover must linger this long before the pill morphs open (short, so it feels like the Dynamic Island).
    private static let hoverExpandDelayNanoseconds: UInt64 = 90_000_000
    private var appUpdateRestartHandler: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var hoverExpandTask: Task<Void, Never>?
    /// Set on collapse; cleared once the pointer leaves the pill.
    private var requiresPointerExitBeforeHoverExpand = false
    private var isStarted = false

    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) private var spaceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var globalMouseMoveMonitor: Any?
    nonisolated(unsafe) private var localMouseMoveMonitor: Any?
    nonisolated(unsafe) private var outsideClickGlobalMonitor: Any?
    nonisolated(unsafe) private var outsideClickLocalMonitor: Any?
    nonisolated(unsafe) private var escapeGlobalMonitor: Any?
    nonisolated(unsafe) private var escapeLocalMonitor: Any?

    private init() {}

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let globalMouseMoveMonitor {
            NSEvent.removeMonitor(globalMouseMoveMonitor)
        }
        if let localMouseMoveMonitor {
            NSEvent.removeMonitor(localMouseMoveMonitor)
        }
        if let outsideClickGlobalMonitor {
            NSEvent.removeMonitor(outsideClickGlobalMonitor)
        }
        if let outsideClickLocalMonitor {
            NSEvent.removeMonitor(outsideClickLocalMonitor)
        }
        if let escapeGlobalMonitor {
            NSEvent.removeMonitor(escapeGlobalMonitor)
        }
        if let escapeLocalMonitor {
            NSEvent.removeMonitor(escapeLocalMonitor)
        }
    }

    // MARK: - Public Lifecycle

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager

        if !isStarted {
            isStarted = true
            installSystemObservers()
            installMouseMoveMonitors()
        }

        bindStateObservers(companionManager: companionManager)
        rebuildPanels()
        refreshMousePassThroughForCurrentCursorLocation()
    }

    public func stop() {
        isStarted = false
        hoverExpandTask?.cancel()
        hoverExpandTask = nil
        cancellables.removeAll()
        removeExpandedDismissMonitors()
        removeMouseMoveMonitors()
        removeSystemObservers()

        for panel in panelsByDisplayID.values {
            panel.orderOut(nil)
            panel.close()
        }
        panelsByDisplayID.removeAll()
        geometriesByDisplayID.removeAll()
        isExpanded = false
        isHovered = false
        hoveredDisplayID = nil
        isTextInputFocused = false
    }

    func showNotchPeek(tab: ClickyNotchTab = .home) {
        let targetDisplay = activeDisplayID ?? displayIDContainingCursor() ?? primaryDisplayID
        expandNotch(tab: tab, on: targetDisplay)
    }

    func collapseNotch() {
        hoverExpandTask?.cancel()
        hoverExpandTask = nil

        guard isExpanded else {
            refreshMousePassThroughForCurrentCursorLocation()
            return
        }

        isExpanded = false
        isTextInputFocused = false
        removeExpandedDismissMonitors()

        for panel in panelsByDisplayID.values {
            let wasKey = panel.isKeyWindow
            panel.allowKeyFocus = false
            if wasKey {
                // Cycle orderOut/orderFrontRegardless to cleanly yield key focus
                // back to the previously active application on a non-activating panel.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }

        // The panel shrinks back over the pill, so a pointer still resting there must leave
        // the pill once before hover can reopen it (otherwise Esc reopens it after 90 ms).
        requiresPointerExitBeforeHoverExpand = true
        refreshMousePassThroughForCurrentCursorLocation()
    }

    public func toggleNotchPeek(tab: ClickyNotchTab? = nil) {
        if isExpanded {
            if let tab, tab != activeTab {
                activeTab = tab
            } else {
                collapseNotch()
            }
        } else {
            showNotchPeek(tab: tab ?? activeTab)
        }
    }

    public func geometry(for displayID: CGDirectDisplayID) -> NotchScreenGeometry? {
        geometriesByDisplayID[displayID]
    }

    public func setHovered(_ hovered: Bool, on displayID: CGDirectDisplayID) {
        isHovered = hovered
        hoveredDisplayID = hovered ? displayID : nil

        if hovered && !isExpanded && !requiresPointerExitBeforeHoverExpand {
            hoverExpandTask?.cancel()
            hoverExpandTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.hoverExpandDelayNanoseconds)
                guard !Task.isCancelled, let self, self.isHovered, !self.isExpanded else { return }
                // A pressed button means a click or hold-to-talk is in progress: let the
                // gesture decide (tap expands, hold talks) instead of opening on hover.
                guard NSEvent.pressedMouseButtons == 0 else { return }
                self.expandNotch(tab: self.activeTab, on: displayID)
            }
        } else if !hovered {
            requiresPointerExitBeforeHoverExpand = false
            hoverExpandTask?.cancel()
            hoverExpandTask = nil
        }
    }

    func isPillHovered(on displayID: CGDirectDisplayID) -> Bool {
        isHovered && hoveredDisplayID == displayID
    }

    /// Called when a press-and-hold starts so hover-expand does not open the notch mid-hold.
    public func cancelPendingHoverExpand() {
        hoverExpandTask?.cancel()
        hoverExpandTask = nil
    }

    public func setTextInputFocused(_ focused: Bool) {
        isTextInputFocused = focused
        guard isExpanded else { return }
        let targetDisplay = activeDisplayID ?? primaryDisplayID
        guard let targetDisplay, let panel = panelsByDisplayID[targetDisplay] else { return }

        panel.allowKeyFocus = true
        if focused && !panel.isKeyWindow {
            panel.makeKey()
        }
    }

    public func updateExpandedContentSize(_ size: CGSize, for displayID: CGDirectDisplayID) {
        guard isExpanded else { return }
        // Only the height is measured; the width comes from the tab so the animated frame can't feed back.
        let clampedWidth = NotchPanelMetrics.size(for: activeTab).width
        let clampedHeight = min(max(size.height, 240), NotchPanelMetrics.maximumExpandedSize.height)
        let newSize = CGSize(width: clampedWidth, height: clampedHeight)

        let deltaW = abs(newSize.width - expandedContentSize.width)
        let deltaH = abs(newSize.height - expandedContentSize.height)
        guard deltaW > 2 || deltaH > 2 else { return }

        expandedContentSize = newSize
        refreshMousePassThroughForCurrentCursorLocation()
    }

    // MARK: - Sparkle / App Update Wiring

    public func bindSparkleUpdateDelegate(_ delegate: SparkleUpdateDelegate) {
        delegate.$hasPendingIdleUpdateInstall
            .combineLatest(delegate.$pendingUpdateVersion)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak delegate] hasPending, version in
                guard let self else { return }
                if hasPending, let version, !version.isEmpty {
                    self.presentAppUpdatedCard(version: version) {
                        delegate?.triggerImmediateInstallIfReady()
                    }
                } else {
                    self.dismissAppUpdatedCard()
                }
            }
            .store(in: &cancellables)
    }

    public func presentAppUpdatedCard(version: String, onRestart: @escaping () -> Void) {
        pendingAppUpdateVersion = version
        appUpdateRestartHandler = onRestart
        expandNotch(tab: activeTab, on: displayIDContainingCursor() ?? primaryDisplayID)
    }

    public func dismissAppUpdatedCard() {
        pendingAppUpdateVersion = nil
        appUpdateRestartHandler = nil
    }

    // MARK: - Morning / Meeting / Spotify Cards

    func presentMorningSuggestionsCard(_ content: NotchMorningSuggestionsContent) {
        pendingMorningSuggestions = content
        expandNotch(tab: activeTab, on: displayIDContainingCursor() ?? primaryDisplayID)
    }

    func dismissMorningSuggestionsCard() {
        pendingMorningSuggestions = nil
    }

    func presentUpcomingMeetingCard(_ content: NotchUpcomingMeetingContent) {
        pendingUpcomingMeeting = content
        expandNotch(tab: activeTab, on: displayIDContainingCursor() ?? primaryDisplayID)
    }

    func dismissUpcomingMeetingCard() {
        pendingUpcomingMeeting = nil
    }

    func presentSpotifyTipCard() {
        pendingSpotifyTip = true
        expandNotch(tab: activeTab, on: displayIDContainingCursor() ?? primaryDisplayID)
    }

    func dismissSpotifyTipCard() {
        pendingSpotifyTip = false
    }

    public func triggerAppUpdateRestart() {
        let handler = appUpdateRestartHandler
        dismissAppUpdatedCard()
        handler?()
    }

    // MARK: - Internal Expansion

    func expandNotch(tab: ClickyNotchTab, on displayID: CGDirectDisplayID?) {
        hoverExpandTask?.cancel()
        hoverExpandTask = nil

        activeTab = tab
        activeDisplayID = displayID ?? displayIDContainingCursor() ?? primaryDisplayID

        if !isExpanded {
            isExpanded = true
        }

        if let activeID = activeDisplayID, let panel = panelsByDisplayID[activeID] {
            panel.allowKeyFocus = true
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }

        for (panelDisplayID, panel) in panelsByDisplayID where panelDisplayID != activeDisplayID {
            panel.allowKeyFocus = false
        }

        installExpandedDismissMonitors()
        refreshMousePassThroughForCurrentCursorLocation()
    }

    // MARK: - Panel Construction & Layout

    private func rebuildPanels() {
        guard let companionManager else { return }

        let currentScreens = NSScreen.screens
        var updatedGeometries: [CGDirectDisplayID: NotchScreenGeometry] = [:]
        var activeDisplayIDs = Set<CGDirectDisplayID>()

        for screen in currentScreens {
            let geometry = NotchScreenGeometry.resolve(for: screen)
            updatedGeometries[geometry.displayID] = geometry
            activeDisplayIDs.insert(geometry.displayID)
        }
        geometriesByDisplayID = updatedGeometries

        // Remove panels for disconnected displays.
        let staleIDs = panelsByDisplayID.keys.filter { !activeDisplayIDs.contains($0) }
        for staleID in staleIDs {
            if let panel = panelsByDisplayID.removeValue(forKey: staleID) {
                panel.orderOut(nil)
                panel.close()
            }
            if activeDisplayID == staleID {
                activeDisplayID = nil
            }
        }

        // Create or update panels for every connected display.
        for screen in currentScreens {
            let displayID = NotchScreenGeometry.displayID(for: screen)
            guard let geometry = updatedGeometries[displayID] else { continue }

            let panel: NotchHostingPanel
            if let existing = panelsByDisplayID[displayID] {
                panel = existing
            } else {
                panel = makePanel(for: geometry, companionManager: companionManager)
                panelsByDisplayID[displayID] = panel
            }

            let targetFrame = geometry.canvasRect
            panel.setFrame(targetFrame, display: true)
            panel.orderFrontRegardless()
        }
    }

    private func makePanel(
        for geometry: NotchScreenGeometry,
        companionManager: CompanionManager
    ) -> NotchHostingPanel {
        let initialFrame = geometry.canvasRect
        let panel = NotchHostingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        // Lets the cursor buddy's local mouse-moved monitor keep following while the pointer is over the notch.
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let rootView = NotchRootView(
            displayID: geometry.displayID,
            notchManager: self,
            companionManager: companionManager
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.contentView = hostingView
        return panel
    }

    // MARK: - Observers & Auto-Expand Triggers

    private func bindStateObservers(companionManager: CompanionManager) {
        cancellables.removeAll()

        // 1. v1.1.3 browser upload approval -> auto-expand notch.
        ClickyUploadApproval.shared.$pendingRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self, request != nil else { return }
                self.expandNotch(tab: self.activeTab, on: self.displayIDContainingCursor() ?? self.primaryDisplayID)
            }
            .store(in: &cancellables)

        // 2. mac_step computer-use consent -> auto-expand notch.
        ClickyTakeOverController.shared.$pendingConsent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] consent in
                guard let self, consent != nil else { return }
                self.expandNotch(tab: self.activeTab, on: self.displayIDContainingCursor() ?? self.primaryDisplayID)
            }
            .store(in: &cancellables)

        // 2b. Companion handoff confirmation ("Start a background job?") -> auto-expand notch.
        companionManager.$pendingHandoffRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self, request != nil else { return }
                self.expandNotch(tab: self.activeTab, on: self.displayIDContainingCursor() ?? self.primaryDisplayID)
            }
            .store(in: &cancellables)

        // 3. TCC document access notice (ActiveDocumentReader + CompanionManager) -> auto-expand notch.
        ActiveDocumentReader.shared.$activeDocumentAccessNotice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                guard let self, notice != nil else { return }
                self.expandNotch(tab: .document, on: self.displayIDContainingCursor() ?? self.primaryDisplayID)
            }
            .store(in: &cancellables)

        companionManager.$activeDocumentNotice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                guard let self, notice != nil else { return }
                self.expandNotch(tab: .document, on: self.displayIDContainingCursor() ?? self.primaryDisplayID)
            }
            .store(in: &cancellables)

        // 4. Live activity state -> resize collapsed activity pill vs resting pill.
        let voiceStateStream = companionManager.$voiceState
            .map { $0 != .idle }
            .eraseToAnyPublisher()
        let realtimeVoiceStream = RealtimeVoiceController.shared.$state
            .map { $0.isActive }
            .eraseToAnyPublisher()
        let dictationStream = companionManager.buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                companionManager.buddyDictationManager.$isSystemWideDictationActive,
                companionManager.buddyDictationManager.$isFinalizingTranscript
            )
            .map { $0 || $1 || $2 }
            .eraseToAnyPublisher()
        let jobsAndTakeOverStream = ClickyJobStore.shared.$jobs
            .combineLatest(ClickyTakeOverController.shared.$phase)
            .map { jobs, phase in
                let hasWorkingJob = jobs.contains { !$0.isArchived && !$0.isDismissed && $0.outcome == .working }
                return hasWorkingJob || phase == .driving
            }
            .eraseToAnyPublisher()

        Publishers.CombineLatest4(voiceStateStream, realtimeVoiceStream, dictationStream, jobsAndTakeOverStream)
            .map { $0 || $1 || $2 || $3 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                guard let self else { return }
                self.isActivityPillVisible = isActive
                if !self.isExpanded {
                    self.refreshMousePassThroughForCurrentCursorLocation()
                }
            }
            .store(in: &cancellables)
    }

    private func installSystemObservers() {
        removeSystemObservers()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPanels()
                self?.refreshMousePassThroughForCurrentCursorLocation()
            }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for panel in self.panelsByDisplayID.values {
                    panel.orderFrontRegardless()
                }
            }
        }
    }

    private func removeSystemObservers() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }

    // MARK: - Mouse Hit-Testing & Dismissal Monitors

    private func installMouseMoveMonitors() {
        removeMouseMoveMonitors()

        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            // A Task hop, not MainActor.assumeIsolated: that isolation check crashed inside AppKit's
            // event-monitor dispatch while Clicky's own window was key.
            Task { @MainActor [weak self] in
                self?.refreshMousePassThroughIfPointerIsNearNotch()
            }
        }

        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.refreshMousePassThroughIfPointerIsNearNotch()
            }
            return event
        }
    }

    /// Margin around the pill hit rect inside which mouse moves still trigger a full refresh.
    private static let notchHotZoneMargin: CGFloat = 24

    /// Whether the previous mouse event was inside the hot zone, so the exit event still runs a refresh.
    private var wasPointerInsideNotchHotZone = false

    /// Cheap gate in front of the full refresh: mouse moves far from the notch while collapsed do nothing.
    private func refreshMousePassThroughIfPointerIsNearNotch() {
        let pointerLocation = NSEvent.mouseLocation
        let hotZoneRect = geometriesByDisplayID.values
            .map { (isActivityPillVisible ? $0.activityPillRect : $0.restingPillRect).insetBy(dx: -Self.notchHotZoneMargin, dy: -Self.notchHotZoneMargin) }
            .first { $0.contains(pointerLocation) } ?? .null

        let shouldRefresh = Self.shouldRefreshNotchPassThrough(
            pointerLocation: pointerLocation,
            hotZoneRect: hotZoneRect,
            wasInsideHotZone: wasPointerInsideNotchHotZone,
            isPanelExpanded: isExpanded
        )
        wasPointerInsideNotchHotZone = hotZoneRect.contains(pointerLocation)
        guard shouldRefresh else { return }
        refreshMousePassThroughForCurrentCursorLocation()
    }

    /// Pure decision: refresh when expanded (panel owns the pointer), when inside the hot zone,
    /// or when the pointer just left it (so hover state and click-through are reset on exit).
    nonisolated static func shouldRefreshNotchPassThrough(
        pointerLocation: CGPoint,
        hotZoneRect: CGRect,
        wasInsideHotZone: Bool,
        isPanelExpanded: Bool
    ) -> Bool {
        if isPanelExpanded { return true }
        if hotZoneRect.contains(pointerLocation) { return true }
        return wasInsideHotZone
    }

    private func removeMouseMoveMonitors() {
        if let globalMouseMoveMonitor {
            NSEvent.removeMonitor(globalMouseMoveMonitor)
            self.globalMouseMoveMonitor = nil
        }
        if let localMouseMoveMonitor {
            NSEvent.removeMonitor(localMouseMoveMonitor)
            self.localMouseMoveMonitor = nil
        }
    }

    private func refreshMousePassThroughForCurrentCursorLocation() {
        let mouseLocation = NSEvent.mouseLocation
        var hoveringAnyCollapsedPill = false

        for (displayID, panel) in panelsByDisplayID {
            guard let geometry = geometriesByDisplayID[displayID] else {
                panel.ignoresMouseEvents = true
                continue
            }

            // The panel is a big transparent canvas: only the visible pill / expanded panel takes mouse events.
            let isThisScreenExpanded = isScreenExpanded(displayID)
            let hitRect = geometry.interactiveRect(
                isExpanded: isThisScreenExpanded,
                isActivityPillVisible: isActivityPillVisible,
                expandedContentSize: expandedContentSize
            ).insetBy(dx: -4, dy: -4)
            let isInside = hitRect.contains(mouseLocation)
            panel.ignoresMouseEvents = !isInside
            if isInside && !isThisScreenExpanded {
                hoveringAnyCollapsedPill = true
                if !isExpanded && !isHovered {
                    setHovered(true, on: displayID)
                }
            }
        }

        if !hoveringAnyCollapsedPill && !isExpanded {
            requiresPointerExitBeforeHoverExpand = false
        }
        if !hoveringAnyCollapsedPill && isHovered && !isExpanded {
            isHovered = false
            hoveredDisplayID = nil
            hoverExpandTask?.cancel()
            hoverExpandTask = nil
        }
    }

    private func isScreenExpanded(_ displayID: CGDirectDisplayID) -> Bool {
        isExpanded && (activeDisplayID == displayID || (activeDisplayID == nil && displayID == primaryDisplayID))
    }

    private func installExpandedDismissMonitors() {
        removeExpandedDismissMonitors()

        outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePotentialOutsideClick()
            }
        }

        outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePotentialOutsideClick()
            }
            return event
        }

        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.collapseNotch()
            }
        }

        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.collapseNotch()
            }
            return nil
        }
    }

    private func removeExpandedDismissMonitors() {
        if let outsideClickGlobalMonitor {
            NSEvent.removeMonitor(outsideClickGlobalMonitor)
            self.outsideClickGlobalMonitor = nil
        }
        if let outsideClickLocalMonitor {
            NSEvent.removeMonitor(outsideClickLocalMonitor)
            self.outsideClickLocalMonitor = nil
        }
        if let escapeGlobalMonitor {
            NSEvent.removeMonitor(escapeGlobalMonitor)
            self.escapeGlobalMonitor = nil
        }
        if let escapeLocalMonitor {
            NSEvent.removeMonitor(escapeLocalMonitor)
            self.escapeLocalMonitor = nil
        }
    }

    private func handlePotentialOutsideClick() {
        guard isExpanded else { return }
        let clickLocation = NSEvent.mouseLocation
        let targetDisplay = activeDisplayID ?? primaryDisplayID
        // Inside = the visible expanded panel, not the (much larger) transparent canvas window.
        if let targetDisplay,
           let geometry = geometriesByDisplayID[targetDisplay],
           geometry.expandedPanelRect(for: expandedContentSize).insetBy(dx: -4, dy: -4).contains(clickLocation) {
            return
        }
        collapseNotch()
    }

    private func displayIDContainingCursor() -> CGDirectDisplayID? {
        let cursor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) {
            return NotchScreenGeometry.displayID(for: screen)
        }
        return nil
    }
}
