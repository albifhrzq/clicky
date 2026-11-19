import Foundation

/// Decides whether an app/space change should wipe the drawing on screen.
/// Pure so it can be unit tested without the overlay or NSWorkspace.
// ponytail: fixed grace period; upgrade: compare screenshots before/after
nonisolated enum ScreenDrawingClearPolicy {
    /// Why: focus often shifts to another app right as a spoken drawing finishes, and the user still needs to see it.
    static let gracePeriodAfterFinishSeconds: TimeInterval = 4

    static func shouldClearOnScreenChange(
        isStreaming: Bool,
        secondsSinceFinished: TimeInterval?,
        isVoiceTurnActive: Bool
    ) -> Bool {
        if isStreaming { return false }
        if isVoiceTurnActive { return false }
        if let secondsSinceFinished, secondsSinceFinished < gracePeriodAfterFinishSeconds { return false }
        return true
    }
}
