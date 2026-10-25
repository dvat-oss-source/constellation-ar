import Foundation

public struct LockUpdate: Sendable, Hashable {
    public var events: [LockEvent]
    /// Newly locked constellation whose narration cooldown allowed it; its cooldown has been started.
    public var narrate: String?
}

/// Feeds `LockEngine` events into the draw-in timeline and the narration cooldown.
public struct ConstellationLockCoordinator<Generator: RandomNumberGenerator & Sendable>: Sendable {
    public var engine: LockEngine
    public var timeline: DrawInTimeline
    public var cooldown: NarrationCooldown<Generator>
    public let schedules: [String: DrawInSchedule]

    public init(schedules: [String: DrawInSchedule], engine: LockEngine = LockEngine(),
                timeline: DrawInTimeline = DrawInTimeline(), cooldown: NarrationCooldown<Generator>) {
        self.schedules = schedules
        self.engine = engine
        self.timeline = timeline
        self.cooldown = cooldown
    }

    public var currentLock: String? { engine.currentLock }

    public mutating func update(time: TimeInterval, scores: [String: Double]) -> LockUpdate {
        let events = engine.update(time: time, scores: scores)
        var narrate: String?
        for event in events {
            switch event {
            case .locked(let id), .changed(from: _, to: let id):
                let schedule = schedules[id] ?? DrawInSchedule(id: id, pairs: [], magnitudes: [:], config: timeline.config)
                timeline.lock(schedule, at: time)
                narrate = cooldown.narrateIfAllowed(id, at: time) ? id : nil
            case .unlocked:
                timeline.unlock(at: time)
            }
        }
        return LockUpdate(events: events, narrate: narrate)
    }

    public func frame(at time: TimeInterval) -> [ConstellationVisual] { timeline.frame(at: time) }
}

extension ConstellationLockCoordinator where Generator == SplitMix64 {
    public init(schedules: [String: DrawInSchedule], engine: LockEngine = LockEngine(),
                timeline: DrawInTimeline = DrawInTimeline(), seed: UInt64) {
        self.init(schedules: schedules, engine: engine, timeline: timeline,
                  cooldown: NarrationCooldown(seed: seed))
    }
}
