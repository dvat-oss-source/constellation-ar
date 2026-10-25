import Foundation
import UIKit

/// Trace-in progress for the artwork silhouette after draw-in (or immediately with Reduce Motion).
@MainActor
final class FocusOutlineAnimation {
    static let traceDuration: Double = 1.2
    static let delayAfterDrawIn: Double = StyleTokens.drawInDuration

    private(set) var activeID: String?
    private var startedAt: Double = 0

    func begin(id: String, at displayTime: Double) {
        guard activeID != id else { return }
        activeID = id
        startedAt = displayTime
    }

    func clear() {
        activeID = nil
        startedAt = 0
    }

    func progress(at displayTime: Double) -> Double {
        guard activeID != nil else { return 0 }
        if UIAccessibility.isReduceMotionEnabled { return 1 }
        let elapsed = displayTime - startedAt - Self.delayAfterDrawIn
        guard elapsed > 0 else { return 0 }
        return min(1, elapsed / Self.traceDuration)
    }
}
