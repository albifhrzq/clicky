//
//  ClickyAttentionExpiry.swift
//  leanring-buddy
//

import Foundation

/// Handed-back steps (signing, paying) stop asking for attention after an hour.
public nonisolated enum ClickyAttentionExpiry {
    public static let expirySeconds: TimeInterval = 60 * 60

    public static func hasExpired(raisedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(raisedAt) >= expirySeconds
    }
}
