import Foundation

public enum LockEvent: Sendable, Hashable {
    case locked(String)
    case changed(from: String, to: String)
    case unlocked(String)
}

public struct LockEngineConfig: Sendable, Hashable {
    /// With nothing locked, the leader must stay the leader this long before it locks.
    public var initialDwell: TimeInterval
    /// A challenger must qualify continuously this long before it replaces the current lock.
    public var challengerDwell: TimeInterval
    /// A challenger qualifies only while its score is at least `challengerRatio ×` the current lock's score.
    public var challengerRatio: Double
    /// Scores below this never lock.
    public var minimumScore: Double
    /// The current lock is released after its score stays below `unlockBelow`, with no other constellation at
    /// `minimumScore`, for `unlockAfter`. While others score, a stale lock waits for a challenger instead.
    public var unlockBelow: Double
    public var unlockAfter: TimeInterval

    public init(initialDwell: TimeInterval = 0.3, challengerDwell: TimeInterval = 0.7, challengerRatio: Double = 1.2,
                minimumScore: Double = 0.15, unlockBelow: Double = 0.1, unlockAfter: TimeInterval = 1.0) {
        self.initialDwell = initialDwell
        self.challengerDwell = challengerDwell
        self.challengerRatio = challengerRatio
        self.minimumScore = minimumScore
        self.unlockBelow = unlockBelow
        self.unlockAfter = unlockAfter
    }
}

/// Anti-flicker lock state machine driven by per-frame scores and explicit timestamps.
public struct LockEngine: Sendable {
    public var config: LockEngineConfig
    public private(set) var currentLock: String?
    public private(set) var lockedSince: TimeInterval?
    /// With a lock: the qualifying challenger. Without: the leader waiting out `initialDwell`.
    public private(set) var challenger: String?
    public private(set) var challengerSince: TimeInterval?
    public private(set) var lowScoreSince: TimeInterval?

    public init(config: LockEngineConfig = LockEngineConfig()) {
        self.config = config
    }

    public mutating func reset() {
        currentLock = nil
        lockedSince = nil
        clearChallenger()
        lowScoreSince = nil
    }

    /// Missing ids score 0. Ties are broken by id so results never depend on dictionary order.
    @discardableResult
    public mutating func update(time: TimeInterval, scores: [String: Double]) -> [LockEvent] {
        guard let current = currentLock else {
            guard let (best, score) = Self.best(in: scores, excluding: nil), score >= config.minimumScore else {
                clearChallenger()
                return []
            }
            track(best, at: time)
            guard time - (challengerSince ?? time) >= config.initialDwell else { return [] }
            lock(best, at: time)
            return [.locked(best)]
        }

        let currentScore = scores[current] ?? 0
        let rival = Self.best(in: scores, excluding: current)
        if let (id, score) = rival,
           score >= config.minimumScore, score > currentScore, score >= config.challengerRatio * currentScore {
            track(id, at: time)
            if time - (challengerSince ?? time) >= config.challengerDwell {
                lock(id, at: time)
                return [.changed(from: current, to: id)]
            }
        } else {
            clearChallenger()
        }

        if currentScore < config.unlockBelow, (rival?.1 ?? 0) < config.minimumScore {
            let since = lowScoreSince ?? time
            lowScoreSince = since
            if time - since >= config.unlockAfter {
                reset()
                return [.unlocked(current)]
            }
        } else {
            lowScoreSince = nil
        }
        return []
    }

    private mutating func track(_ id: String, at time: TimeInterval) {
        if challenger != id {
            challenger = id
            challengerSince = time
        }
    }

    private mutating func clearChallenger() {
        challenger = nil
        challengerSince = nil
    }

    private mutating func lock(_ id: String, at time: TimeInterval) {
        currentLock = id
        lockedSince = time
        lowScoreSince = nil
        clearChallenger()
    }

    static func best(in scores: [String: Double], excluding excluded: String?) -> (String, Double)? {
        var best: (String, Double)?
        for (id, score) in scores where id != excluded && score.isFinite {
            if let b = best, score < b.1 || (score == b.1 && id >= b.0) { continue }
            best = (id, score)
        }
        return best
    }
}
