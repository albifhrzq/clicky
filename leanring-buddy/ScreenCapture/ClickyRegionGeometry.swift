//
//  ClickyRegionGeometry.swift
//  leanring-buddy
//
//  Pure helpers for region capture: drag points to screen rects, validity, queue cap, labels.
//

import CoreGraphics
import Foundation

nonisolated enum ClickyRegionGeometry {
    static let minimumRegionSideInPoints: CGFloat = 8
    static let maximumQueuedRegionCount = 4
    static let queuedRegionTimeToLiveSeconds: TimeInterval = 10 * 60

    /// Rect spanned by two drag points, regardless of drag direction.
    static func normalizedRect(from startPoint: CGPoint, to endPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    static func isLargeEnough(_ rect: CGRect) -> Bool {
        rect.width >= minimumRegionSideInPoints && rect.height >= minimumRegionSideInPoints
    }

    /// Converts a rect in a top-left-origin (flipped) view to a rect in global AppKit
    /// screen coordinates (bottom-left origin of the primary screen).
    static func globalScreenRect(fromFlippedViewRect viewRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + viewRect.minX,
            y: screenFrame.maxY - viewRect.maxY,
            width: viewRect.width,
            height: viewRect.height
        )
    }

    /// Drag rect must overlap the screen; otherwise the user dragged outside it.
    static func isOutsideScreen(globalRect: CGRect, screenFrame: CGRect) -> Bool {
        let intersection = globalRect.intersection(screenFrame)
        return intersection.isNull || intersection.width <= 0 || intersection.height <= 0
    }

    /// Clips a flipped view rect to the view bounds.
    static func clampedToBounds(_ viewRect: CGRect, boundsSize: CGSize) -> CGRect {
        viewRect.intersection(CGRect(origin: .zero, size: boundsSize))
    }

    /// Appends and drops the oldest entries beyond the cap.
    static func appendingWithCap<Element>(_ element: Element, to existing: [Element]) -> [Element] {
        Array((existing + [element]).suffix(maximumQueuedRegionCount))
    }

    /// Keeps only entries captured within the TTL.
    static func droppingExpired<Element>(
        _ elements: [Element],
        capturedAt: (Element) -> Date,
        now: Date,
        timeToLive: TimeInterval = queuedRegionTimeToLiveSeconds
    ) -> [Element] {
        elements.filter { now.timeIntervalSince(capturedAt($0)) < timeToLive }
    }

    static func queuedCountLabel(count: Int) -> String {
        count == 1
            ? String(localized: "Region queued")
            : String(localized: "\(count) regions queued")
    }
}
