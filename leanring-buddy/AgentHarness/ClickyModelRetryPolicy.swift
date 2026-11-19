//
//  ClickyModelRetryPolicy.swift
//  leanring-buddy
//
//  Retry rules for upstream AI model outages (5xx / 529 overloaded) in the local agent shim.
//

import Foundation

public nonisolated struct ClickyModelRetryStatus: Equatable, Sendable {
    /// 1-based number of the retry that is about to run.
    public let attempt: Int
    public let maximum: Int
}

public nonisolated enum ClickyModelRetryPolicy {
    /// Wait before retry 1, 2, 3 and 4. Four retries at most, then the failure is passed through.
    public static let backoffDelaysSeconds: [TimeInterval] = [2, 5, 15, 30]

    public static var maximumRetryCount: Int { backoffDelaysSeconds.count }

    /// Server errors and 529 (overloaded) are outages worth waiting out; 4xx are the caller's fault.
    public static func shouldRetry(statusCode: Int) -> Bool {
        (500...599).contains(statusCode)
    }

    /// Delay before the given 1-based retry, or nil when retries are exhausted.
    public static func delaySeconds(forRetry retryNumber: Int) -> TimeInterval? {
        guard retryNumber >= 1, retryNumber <= backoffDelaysSeconds.count else { return nil }
        return backoffDelaysSeconds[retryNumber - 1]
    }
}
