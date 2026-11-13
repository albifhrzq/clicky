//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts CompanionPanelView
//  via NSHostingView with dynamic intrinsic/preference-driven sizing and
//  quick-action hooks to open Notch peek or HeyClickyWindow.
//

import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickyOpenNotchPeek = Notification.Name("clickyOpenNotchPeek")
    static let clickyOpenHeyClickyWindow = Notification.Name("clickyOpenHeyClickyWindow")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct MenuBarPanelSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct MenuBarPanelHostingContainer: View {
    @ObservedObject var companionManager: CompanionManager
    let minimumWidth: CGFloat
    let onSizeChanged: (CGSize) -> Void

    var body: some View {
        CompanionPanelView(companionManager: companionManager)
            .frame(minWidth: minimumWidth)
            .fixedSize(horizontal: true, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: MenuBarPanelSizePreferenceKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(MenuBarPanelSizePreferenceKey.self) { measuredSize in
                onSizeChanged(measuredSize)
            }
    }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    nonisolated(unsafe) private var clickOutsideMonitor: Any?
    nonisolated(unsafe) private var dismissPanelObserver: NSObjectProtocol?
    nonisolated(unsafe) private var openNotchPeekObserver: NSObjectProtocol?
    nonisolated(unsafe) private var openWindowObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let defaultPanelWidth: CGFloat = 320
    private let defaultPanelHeight: CGFloat = 380
    private var measuredContentSize: CGSize = CGSize(width: 320, height: 380)

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()
        installNotificationObservers()
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openNotchPeekObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func installNotificationObservers() {
        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
            }
        }

        openNotchPeekObserver = NotificationCenter.default.addObserver(
            forName: .clickyOpenNotchPeek,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let requestedTab = notification.object as? ClickyNotchTab ?? .home
            Task { @MainActor [weak self] in
                self?.openNotchPeek(tab: requestedTab)
            }
        }

        openWindowObserver = NotificationCenter.default.addObserver(
            forName: .clickyOpenHeyClickyWindow,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let requestedTab = notification.object as? ClickyNotchTab ?? .chat
            Task { @MainActor [weak self] in
                self?.openHeyClickyWindow(initialTab: requestedTab)
            }
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        let currentEvent = NSApp.currentEvent
        let isContextClick = currentEvent?.type == .rightMouseUp
            || (currentEvent?.modifierFlags.contains(.control) == true)

        if isContextClick {
            showQuickActionsMenu()
            return
        }

        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Quick Actions & Navigation Hooks

    func openNotchPeek(tab: ClickyNotchTab = .home) {
        hidePanel()
        NotchWindowManager.shared.showNotchPeek(tab: tab)
    }

    func openHeyClickyWindow(
        selectedSlug: String? = nil,
        documentPath: String? = nil,
        initialTab: ClickyNotchTab = .chat
    ) {
        hidePanel()
        HeyClickyWindowController.shared.open(
            selectedSlug: selectedSlug,
            documentPath: documentPath,
            initialTab: initialTab
        )
    }

    private func showQuickActionsMenu() {
        guard let button = statusItem?.button else { return }
        hidePanel()

        let menu = NSMenu(title: "Clicky")

        let notchItem = NSMenuItem(
            title: "Open Notch Peek",
            action: #selector(handleOpenNotchPeekMenuItem),
            keyEquivalent: ""
        )
        notchItem.target = self
        menu.addItem(notchItem)

        let notchChatItem = NSMenuItem(
            title: "Ask in Notch Chat",
            action: #selector(handleOpenNotchChatMenuItem),
            keyEquivalent: ""
        )
        notchChatItem.target = self
        menu.addItem(notchChatItem)

        let windowItem = NSMenuItem(
            title: "Open HeyClicky Window",
            action: #selector(handleOpenHeyClickyWindowMenuItem),
            keyEquivalent: ""
        )
        windowItem.target = self
        menu.addItem(windowItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(handleOpenSettingsMenuItem),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let cursorTitle = ClickyConfiguration.shared.hideFloatingCursor
            ? "Show Floating Cursor"
            : "Hide Floating Cursor"
        let toggleCursorItem = NSMenuItem(
            title: cursorTitle,
            action: #selector(handleToggleFloatingCursorMenuItem),
            keyEquivalent: ""
        )
        toggleCursorItem.target = self
        menu.addItem(toggleCursorItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Clicky",
            action: #selector(handleQuitMenuItem),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func handleOpenNotchPeekMenuItem() {
        openNotchPeek(tab: .home)
    }

    @objc private func handleOpenNotchChatMenuItem() {
        openNotchPeek(tab: .chat)
    }

    @objc private func handleOpenHeyClickyWindowMenuItem() {
        openHeyClickyWindow(initialTab: .chat)
    }

    @objc private func handleOpenSettingsMenuItem() {
        openHeyClickyWindow(initialTab: .settings)
    }

    @objc private func handleToggleFloatingCursorMenuItem() {
        ClickyConfiguration.shared.hideFloatingCursor.toggle()
    }

    @objc private func handleQuitMenuItem() {
        NSApp.terminate(nil)
    }

    // MARK: - Panel Lifecycle

    func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem(animated: false)

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let containerView = MenuBarPanelHostingContainer(
            companionManager: companionManager,
            minimumWidth: defaultPanelWidth,
            onSizeChanged: { [weak self] newSize in
                self?.handleMeasuredContentSizeChange(newSize)
            }
        )

        let hostingView = NSHostingView(rootView: containerView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.frame = NSRect(x: 0, y: 0, width: defaultPanelWidth, height: defaultPanelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: defaultPanelWidth, height: defaultPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func handleMeasuredContentSizeChange(_ newSize: CGSize) {
        guard newSize.width > 10, newSize.height > 10 else { return }
        let widthChanged = abs(newSize.width - measuredContentSize.width) > 0.5
        let heightChanged = abs(newSize.height - measuredContentSize.height) > 0.5
        guard widthChanged || heightChanged else { return }

        measuredContentSize = newSize
        if panel?.isVisible == true {
            positionPanelBelowStatusItem(animated: true)
        }
    }

    private func positionPanelBelowStatusItem(animated: Bool) {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        let fittingSize = panel.contentView?.fittingSize ?? measuredContentSize
        let resolvedWidth = max(defaultPanelWidth, fittingSize.width > 10 ? fittingSize.width : measuredContentSize.width)
        let rawHeight = fittingSize.height > 10 ? fittingSize.height : measuredContentSize.height

        let targetScreen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxAllowedHeight = max(240, visibleFrame.height - 24)
        let resolvedHeight = min(max(120, rawHeight), maxAllowedHeight)

        // Horizontally center beneath the status item while clamping inside screen bounds.
        let unclampedOriginX = statusItemFrame.midX - (resolvedWidth / 2)
        let minOriginX = visibleFrame.minX + 8
        let maxOriginX = max(minOriginX, visibleFrame.maxX - resolvedWidth - 8)
        let panelOriginX = min(max(unclampedOriginX, minOriginX), maxOriginX)

        let panelOriginY = max(visibleFrame.minY + 8, statusItemFrame.minY - resolvedHeight - gapBelowMenuBar)
        let targetFrame = NSRect(x: panelOriginX, y: panelOriginY, width: resolvedWidth, height: resolvedHeight)

        if abs(panel.frame.width - targetFrame.width) < 0.5,
           abs(panel.frame.height - targetFrame.height) < 0.5,
           abs(panel.frame.origin.x - targetFrame.origin.x) < 0.5,
           abs(panel.frame.origin.y - targetFrame.origin.y) < 0.5 {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                panel.setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }

                let clickLocation = NSEvent.mouseLocation
                if panel.frame.contains(clickLocation) {
                    return
                }

                // Delay dismissal slightly to avoid closing the panel when
                // a system permission dialog appears (e.g. microphone access).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, panel.isVisible else { return }

                    // If permissions aren't all granted yet, a system dialog
                    // may have focus — don't dismiss during onboarding.
                    if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                        return
                    }

                    self.hidePanel()
                }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
