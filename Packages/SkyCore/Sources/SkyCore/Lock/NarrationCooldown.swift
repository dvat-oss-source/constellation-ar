import Foundation

/// SplitMix64 (Steele, Lea & Flood 2014): small, fast, seedable, deterministic across platforms.
public struct SplitMix64: RandomNumberGenerator, Sendable, Hashable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Per-constellation narration cooldown: after narrating `id` at `t`, `id` is silent until `t + d`,
/// with `d` drawn uniformly from `duration` by the injected generator.
public struct NarrationCooldown<Generator: RandomNumberGenerator & Sendable>: Sendable {
    public var duration: ClosedRange<TimeInterval>
    public private(set) var generator: Generator
    public private(set) var nextAllowed: [String: TimeInterval] = [:]

    public init(duration: ClosedRange<TimeInterval> = 30...45, generator: Generator) {
        self.duration = duration
        self.generator = generator
    }

    public func canNarrate(_ id: String, at time: TimeInterval) -> Bool {
        guard let next = nextAllowed[id] else { return true }
        return time >= next
    }

    public func nextAllowedTime(for id: String) -> TimeInterval? { nextAllowed[id] }

    /// Starts a new cooldown for `id` and returns its length.
    @discardableResult
    public mutating func markNarrated(_ id: String, at time: TimeInterval) -> TimeInterval {
        let d = duration.lowerBound == duration.upperBound
            ? duration.lowerBound
            : TimeInterval.random(in: duration, using: &generator)
        nextAllowed[id] = time + d
        return d
    }

    /// Marks and returns true when `id` may be narrated now; returns false (and changes nothing) otherwise.
    public mutating func narrateIfAllowed(_ id: String, at time: TimeInterval) -> Bool {
        guard canNarrate(id, at: time) else { return false }
        markNarrated(id, at: time)
        return true
    }
}

extension NarrationCooldown where Generator == SplitMix64 {
    public init(duration: ClosedRange<TimeInterval> = 30...45, seed: UInt64) {
        self.init(duration: duration, generator: SplitMix64(seed: seed))
    }
}
