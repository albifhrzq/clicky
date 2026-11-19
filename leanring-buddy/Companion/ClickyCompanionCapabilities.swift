//
//  ClickyCompanionCapabilities.swift
//  leanring-buddy
//
//  Single source of the "what you can do" prompt sections shared by every companion
//  channel (typed chat, push-to-talk voice, realtime voice), so a new ability is taught
//  to all of them at once.
//

import Foundation

nonisolated enum ClickyCompanionChannel: Sendable {
    /// Typed chat in the notch or HeyClicky window: Markdown allowed, reply is read.
    case text
    /// Push-to-talk voice: reply is spoken, so tags and code are stripped before TTS.
    case voice
    /// Realtime duplex voice: everything said is heard, so abilities are tools, never tags.
    case realtime
}

nonisolated enum ClickyCompanionCapabilities {
    /// Capability sections appended to a channel's base prompt.
    static func promptSections(for channel: ClickyCompanionChannel) -> String {
        [
            languageSection,
            ClickyDrawingPromptReference.section(for: channel),
            ClickyHandoffPromptReference.section(for: channel)
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Shared by every channel: reply language, right-to-left drawing, and silent progress updates.
    static let languageSection = """
    Language: reply, speak and write any text you draw in the user's language, meaning the language they just spoke or typed, or the voice language they configured. \
    For right-to-left languages (Arabic, Hebrew, Persian, Urdu) draw text with {anchor:'end'} so it grows leftward from its x position.
    Agent progress updates inserted into the conversation are silent context, not messages to answer.
    """
}
