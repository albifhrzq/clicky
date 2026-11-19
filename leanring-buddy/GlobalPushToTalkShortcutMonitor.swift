//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures 4 configurable system-wide shortcut slots (voiceHold, textTrigger,
//  dictationHold, handsFreeDictation) using a listen-only CGEvent tap with
//  holdCombo + doubleTapModifier detection and Escape interrupt support.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

public enum ClickyShortcutSlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case voiceHold
    case textTrigger
    case dictationHold
    case handsFreeDictation
    case regionCapture

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .voiceHold: return "Voice Hold (Talk)"
        case .textTrigger: return "Text Trigger"
        case .dictationHold: return "Dictation Hold (Type Anywhere)"
        case .handsFreeDictation: return "Hands-Free Dictation (Toggle)"
        case .regionCapture: return String(localized: "Capture a Region")
        }
    }
}

public enum ClickyShortcutTriggerMode: String, CaseIterable, Codable, Sendable {
    case holdCombo
    case doubleTapModifier

    public var displayName: String {
        switch self {
        case .holdCombo: return "Hold Combo"
        case .doubleTapModifier: return "Double-Tap Modifier"
        }
    }
}

public enum ClickyShortcutModifierKey: String, CaseIterable, Codable, Sendable {
    case control
    case option
    case shift
    case command
    case function

    public var displayName: String {
        switch self {
        case .control: return "ctrl"
        case .option: return "option"
        case .shift: return "shift"
        case .command: return "cmd"
        case .function: return "fn"
        }
    }

    public var eventModifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        case .command: return .command
        case .function: return .function
        }
    }
}

public struct ClickyShortcutBinding: Codable, Equatable, Sendable {
    public var slot: ClickyShortcutSlot
    public var triggerMode: ClickyShortcutTriggerMode
    public var modifiers: [ClickyShortcutModifierKey]
    public var keyCode: UInt16?
    public var isEnabled: Bool

    public init(
        slot: ClickyShortcutSlot,
        triggerMode: ClickyShortcutTriggerMode,
        modifiers: [ClickyShortcutModifierKey],
        keyCode: UInt16? = nil,
        isEnabled: Bool = true
    ) {
        self.slot = slot
        self.triggerMode = triggerMode
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.isEnabled = isEnabled
    }

    public var requiredModifierFlags: NSEvent.ModifierFlags {
        modifiers.reduce(NSEvent.ModifierFlags()) { result, key in
            result.union(key.eventModifierFlag)
        }
    }

    public var keyCapsuleLabels: [String] {
        var labels = modifiers.map(\.displayName)
        if let keyCode {
            labels.append(Self.displayLabel(forKeyCode: keyCode))
        }
        if triggerMode == .doubleTapModifier, let first = labels.first {
            return ["2× \(first)"]
        }
        return labels
    }

    public var displayText: String {
        if triggerMode == .doubleTapModifier, let first = modifiers.first {
            return String(localized: "\(first.displayName), pressed twice")
        }
        return keyCapsuleLabels.joined(separator: " + ")
    }

    public static func defaultBindings() -> [ClickyShortcutSlot: ClickyShortcutBinding] {
        [
            .voiceHold: ClickyShortcutBinding(
                slot: .voiceHold,
                triggerMode: .holdCombo,
                modifiers: [.control, .option],
                keyCode: nil,
                isEnabled: true
            ),
            .textTrigger: ClickyShortcutBinding(
                slot: .textTrigger,
                triggerMode: .holdCombo,
                modifiers: [.control, .shift],
                keyCode: 49, // Space
                isEnabled: true
            ),
            .dictationHold: ClickyShortcutBinding(
                slot: .dictationHold,
                triggerMode: .holdCombo,
                modifiers: [.shift, .function],
                keyCode: nil,
                isEnabled: true
            ),
            .handsFreeDictation: ClickyShortcutBinding(
                slot: .handsFreeDictation,
                triggerMode: .doubleTapModifier,
                modifiers: [.function],
                keyCode: nil,
                isEnabled: true
            ),
            // No default keys: the user opts in by recording a shortcut in Settings.
            .regionCapture: ClickyShortcutBinding(
                slot: .regionCapture,
                triggerMode: .holdCombo,
                modifiers: [],
                keyCode: nil,
                isEnabled: false
            )
        ]
    }

    private static func displayLabel(forKeyCode keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "space"
        case 36: return "return"
        case 48: return "tab"
        case 53: return "esc"
        case 117: return String(localized: "Forward Delete")
        default: return String(localized: "Key #\(Int(keyCode))")
        }
    }
}

public enum ClickyShortcutSlotEvent: Equatable, Sendable {
    case pressed(slot: ClickyShortcutSlot)
    case released(slot: ClickyShortcutSlot)
    case triggered(slot: ClickyShortcutSlot)
    case escapeInterrupted
}

@MainActor
final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    private static let bindingsDefaultsKey = "clicky_shortcut_bindings_v1"
    private static let escapeKeyCode: UInt16 = 53
    private static let maxSingleTapHoldSeconds: TimeInterval = 0.35
    private static let maxDoubleTapGapSeconds: TimeInterval = 0.42

    /// Legacy publisher for the `voiceHold` slot consumed by `CompanionManager`.
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Unified publisher for all 4 configurable shortcut slots + Escape interrupt.
    let slotEventPublisher = PassthroughSubject<ClickyShortcutSlotEvent, Never>()

    /// Optional direct callbacks for Escape interrupt and slot events.
    var onEscapeInterrupt: (() -> Void)?
    var onSlotEvent: ((ClickyShortcutSlotEvent) -> Void)?

    nonisolated(unsafe) private var globalEventTap: CFMachPort?
    nonisolated(unsafe) private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    @Published private(set) var activeHoldSlots: Set<ClickyShortcutSlot> = []
    @Published private(set) var isHandsFreeDictationToggledOn = false
    @Published public var bindings: [ClickyShortcutSlot: ClickyShortcutBinding]

    private struct DoubleTapTrackingState {
        var isModifierCurrentlyHeld = false
        var pressStartedAt: TimeInterval = 0
        var lastTapReleasedAt: TimeInterval = 0
        var hadInterveningKeyOrExtraModifier = false
    }

    private var doubleTapStatesBySlot: [ClickyShortcutSlot: DoubleTapTrackingState] = [:]

    init() {
        self.bindings = Self.loadPersistedBindings()
    }

    deinit {
        teardownEventTap()
    }

    func binding(for slot: ClickyShortcutSlot) -> ClickyShortcutBinding {
        bindings[slot] ?? ClickyShortcutBinding.defaultBindings()[slot]!
    }

    func updateBinding(_ binding: ClickyShortcutBinding) {
        bindings[binding.slot] = binding
        activeHoldSlots.remove(binding.slot)
        doubleTapStatesBySlot[binding.slot] = nil
        if binding.slot == .voiceHold {
            isShortcutCurrentlyPressed = false
        }
        persistBindings()
    }

    func resetBindingsToDefaults() {
        bindings = ClickyShortcutBinding.defaultBindings()
        activeHoldSlots.removeAll()
        doubleTapStatesBySlot.removeAll()
        isShortcutCurrentlyPressed = false
        isHandsFreeDictationToggledOn = false
        persistBindings()
    }

    func resetHandsFreeToggleState() {
        isHandsFreeDictationToggledOn = false
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return monitor.handleGlobalEventTapOnMainThread(
                eventType: eventType,
                event: event
            )
        }

        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            createdTap,
            0
        ) else {
            CFMachPortInvalidate(createdTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = createdTap
        self.globalEventTapRunLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        activeHoldSlots.removeAll()
        doubleTapStatesBySlot.removeAll()
        teardownEventTap()
    }

    nonisolated private func teardownEventTap() {
        if let runLoopSource = globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            globalEventTapRunLoopSource = nil
        }

        if let tap = globalEventTap {
            CFMachPortInvalidate(tap)
            globalEventTap = nil
        }
    }

    nonisolated private func handleGlobalEventTapOnMainThread(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let tap = globalEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let rawFlags = event.flags.rawValue

        // Callback runs on CFRunLoopGetMain(), so MainActor.assumeIsolated is guaranteed safe.
        MainActor.assumeIsolated {
            self.processGlobalEvent(
                eventType: eventType,
                keyCode: eventKeyCode,
                modifierFlagsRawValue: rawFlags
            )
        }

        return Unmanaged.passUnretained(event)
    }

    private func processGlobalEvent(
        eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64
    ) {
        let currentFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection([.control, .option, .shift, .command, .function])
        let now = ProcessInfo.processInfo.systemUptime

        // 1. Escape interrupt
        if eventType == .keyDown && keyCode == Self.escapeKeyCode {
            if isHandsFreeDictationToggledOn {
                isHandsFreeDictationToggledOn = false
            }
            emitSlotEvent(.escapeInterrupted)
            onEscapeInterrupt?()
        }

        // Invalidate pending double-tap candidates if any non-modifier key is pressed
        if eventType == .keyDown {
            for slot in doubleTapStatesBySlot.keys {
                doubleTapStatesBySlot[slot]?.hadInterveningKeyOrExtraModifier = true
                doubleTapStatesBySlot[slot]?.lastTapReleasedAt = 0
            }
        }

        // 2. Evaluate all 4 configurable slots
        for slot in ClickyShortcutSlot.allCases {
            let binding = self.binding(for: slot)
            guard binding.isEnabled else { continue }

            switch binding.triggerMode {
            case .holdCombo:
                evaluateHoldCombo(
                    slot: slot,
                    binding: binding,
                    eventType: eventType,
                    keyCode: keyCode,
                    currentFlags: currentFlags
                )

            case .doubleTapModifier:
                evaluateDoubleTapModifier(
                    slot: slot,
                    binding: binding,
                    eventType: eventType,
                    currentFlags: currentFlags,
                    timestamp: now
                )
            }
        }
    }

    private func evaluateHoldCombo(
        slot: ClickyShortcutSlot,
        binding: ClickyShortcutBinding,
        eventType: CGEventType,
        keyCode: UInt16,
        currentFlags: NSEvent.ModifierFlags
    ) {
        let requiredFlags = binding.requiredModifierFlags
        let wasPressed = activeHoldSlots.contains(slot)

        if let triggerKeyCode = binding.keyCode {
            let matchesModifiers = requiredFlags.isEmpty || currentFlags.isSuperset(of: requiredFlags)
            if eventType == .keyDown && keyCode == triggerKeyCode && matchesModifiers && !wasPressed {
                activeHoldSlots.insert(slot)
                dispatchPressTransition(for: slot)
            } else if eventType == .keyUp && keyCode == triggerKeyCode && wasPressed {
                activeHoldSlots.remove(slot)
                dispatchReleaseTransition(for: slot)
            }
        } else {
            guard eventType == .flagsChanged, !requiredFlags.isEmpty else { return }
            let isCurrentlyPressed = currentFlags.contains(requiredFlags)
            if isCurrentlyPressed && !wasPressed {
                activeHoldSlots.insert(slot)
                dispatchPressTransition(for: slot)
            } else if !isCurrentlyPressed && wasPressed {
                activeHoldSlots.remove(slot)
                dispatchReleaseTransition(for: slot)
            }
        }
    }

    private func evaluateDoubleTapModifier(
        slot: ClickyShortcutSlot,
        binding: ClickyShortcutBinding,
        eventType: CGEventType,
        currentFlags: NSEvent.ModifierFlags,
        timestamp: TimeInterval
    ) {
        guard eventType == .flagsChanged else { return }
        guard let targetModifier = binding.modifiers.first else { return }

        let targetFlag = targetModifier.eventModifierFlag
        var tracking = doubleTapStatesBySlot[slot] ?? DoubleTapTrackingState()

        let isOnlyTargetModifierHeld = currentFlags == targetFlag
        let isTargetHeldWithExtras = currentFlags.contains(targetFlag) && currentFlags != targetFlag
        let isTargetReleased = !currentFlags.contains(targetFlag)

        if isTargetHeldWithExtras {
            tracking.hadInterveningKeyOrExtraModifier = true
            tracking.lastTapReleasedAt = 0
        }

        if isOnlyTargetModifierHeld && !tracking.isModifierCurrentlyHeld {
            tracking.isModifierCurrentlyHeld = true
            tracking.pressStartedAt = timestamp
            tracking.hadInterveningKeyOrExtraModifier = false
        } else if isTargetReleased && tracking.isModifierCurrentlyHeld {
            tracking.isModifierCurrentlyHeld = false
            let holdDuration = timestamp - tracking.pressStartedAt

            if !tracking.hadInterveningKeyOrExtraModifier && holdDuration <= Self.maxSingleTapHoldSeconds {
                if tracking.lastTapReleasedAt > 0
                    && (timestamp - tracking.lastTapReleasedAt) <= Self.maxDoubleTapGapSeconds {
                    tracking.lastTapReleasedAt = 0
                    doubleTapStatesBySlot[slot] = tracking
                    dispatchTriggeredEvent(for: slot)
                    return
                } else {
                    tracking.lastTapReleasedAt = timestamp
                }
            } else {
                tracking.lastTapReleasedAt = 0
            }
        }

        doubleTapStatesBySlot[slot] = tracking
    }

    private func dispatchPressTransition(for slot: ClickyShortcutSlot) {
        if slot == .voiceHold {
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        }
        if slot == .textTrigger {
            emitSlotEvent(.triggered(slot: .textTrigger))
        }
        if slot == .regionCapture {
            emitSlotEvent(.triggered(slot: .regionCapture))
            ClickyRegionCaptureController.shared.begin()
        }
        emitSlotEvent(.pressed(slot: slot))
    }

    private func dispatchReleaseTransition(for slot: ClickyShortcutSlot) {
        if slot == .voiceHold {
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }
        emitSlotEvent(.released(slot: slot))
    }

    private func dispatchTriggeredEvent(for slot: ClickyShortcutSlot) {
        if slot == .handsFreeDictation {
            isHandsFreeDictationToggledOn.toggle()
        }
        emitSlotEvent(.triggered(slot: slot))
    }

    private func emitSlotEvent(_ event: ClickyShortcutSlotEvent) {
        slotEventPublisher.send(event)
        onSlotEvent?(event)
    }

    // MARK: - Persistence

    private func persistBindings() {
        let encodedList = Array(bindings.values)
        if let data = try? JSONEncoder().encode(encodedList) {
            UserDefaults.standard.set(data, forKey: Self.bindingsDefaultsKey)
        }
    }

    private static func loadPersistedBindings() -> [ClickyShortcutSlot: ClickyShortcutBinding] {
        var resolved = ClickyShortcutBinding.defaultBindings()
        guard let data = UserDefaults.standard.data(forKey: bindingsDefaultsKey),
              let decoded = try? JSONDecoder().decode([ClickyShortcutBinding].self, from: data) else {
            return resolved
        }
        for binding in decoded {
            resolved[binding.slot] = binding
        }
        return resolved
    }
}
