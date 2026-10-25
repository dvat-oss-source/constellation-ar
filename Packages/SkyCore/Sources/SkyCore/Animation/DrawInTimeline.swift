import Foundation
import simd

public struct StarVisual: Sendable, Hashable {
    public var hip: Int
    public var alpha: Double
}

public struct SegmentVisual: Sendable, Hashable {
    /// Index into the figure's `pairs`.
    public var index: Int
    public var fromHip: Int
    public var toHip: Int
    /// Drawn fraction of the chord from `fromHip` toward `toHip`, 0...1 (render with `Projector.drawnPart`).
    public var progress: Double
    public var alpha: Double
    public var glow: Double
    /// Pulse position along the segment, 0 at `fromHip`, 1 at `toHip`; meaningful while `glow > 0`.
    public var glowPosition: Double
}

/// Highlight layer of one constellation, drawn over the dim resting lines. Every alpha and glow already
/// includes `highlight`, so all values can be used directly; all are within 0...1.
public struct ConstellationVisual: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        /// Brightest-first star light-up, BFS trace, label, glow pulse, artwork.
        case drawIn
        /// Re-locked within the recall window: appears already drawn.
        case recalled
        /// Reduce Motion: everything fades in together.
        case plainFade
    }

    public var id: String
    public var isLocked: Bool
    public var mode: Mode
    public var highlight: Double
    public var stars: [StarVisual]
    public var segments: [SegmentVisual]
    public var label: Double
    public var artwork: Double
}

extension Projector {
    /// On-screen part of the drawn fraction of a draw-in segment. `from`/`to` are the ENU directions of
    /// `segment.fromHip`/`segment.toHip`; the drawn tip is the chord point `from + progress·(to − from)`.
    /// `startT/endT` are parameters along that full chord.
    ///
    /// Clips the drawn sub-chord itself: `ClippedSegment.restricted` interpolates linearly in screen space,
    /// which is not perspective-correct, so its tip would slide off the chord point as the camera turns.
    public func drawnPart(of segment: SegmentVisual, from: SIMD3<Double>, to: SIMD3<Double>,
                          guardBand: Double = 64) -> ClippedSegment? {
        let p = DrawInEase.clamp01(segment.progress)
        guard p > 0 else { return nil }
        let a = simd_normalize(from), b = simd_normalize(to)
        let tip = a + p * (b - a)
        let tipLength = simd_length(tip)
        guard tipLength > 1e-12, var clipped = clipSegment(a, tip, guardBand: guardBand) else { return nil }
        func fullChordT(_ u: Double) -> Double { u * p / (tipLength * (1 - u) + u) }
        clipped.startT = fullChordT(clipped.startT)
        clipped.endT = fullChordT(clipped.endT)
        return clipped
    }
}

struct DrawInEpisode: Sendable {
    let schedule: DrawInSchedule
    let mode: ConstellationVisual.Mode
    /// Absolute time corresponding to the schedule's local time 0.
    let contentOrigin: TimeInterval
    let highlightFrom: Double
    let highlightStart: TimeInterval
    let highlightRise: TimeInterval
    var end: TimeInterval?
    var endFade: TimeInterval = 0

    private func risingHighlight(at t: TimeInterval) -> Double {
        highlightFrom + (1 - highlightFrom) * DrawInEase.ramp(t, start: highlightStart, duration: highlightRise)
    }

    func highlight(at t: TimeInterval) -> Double {
        guard let end, t > end else { return DrawInEase.clamp01(risingHighlight(at: t)) }
        let fade = 1 - DrawInEase.ramp(t, start: end, duration: endFade)
        return DrawInEase.clamp01(risingHighlight(at: end) * fade)
    }

    /// Schedule time; frozen at the unlock so an outgoing figure only fades.
    func contentTime(at t: TimeInterval) -> TimeInterval {
        min(t, end ?? t) - contentOrigin
    }

    func isFullyDrawn(at t: TimeInterval) -> Bool {
        mode != .drawIn || contentTime(at: t) >= schedule.drawDuration
    }

    func isFinished(at t: TimeInterval) -> Bool {
        guard let end else { return false }
        return t >= end + endFade
    }

    func visual(at t: TimeInterval) -> ConstellationVisual {
        let h = highlight(at: t)
        let s = schedule
        let stars: [StarVisual]
        let segments: [SegmentVisual]
        let label: Double, artwork: Double
        switch mode {
        case .drawIn:
            let local = contentTime(at: t)
            stars = s.stars.indices.map { StarVisual(hip: s.stars[$0].hip, alpha: s.starAlpha($0, at: local) * h) }
            segments = s.segments.indices.map { i in
                SegmentVisual(index: i, fromHip: s.segments[i].fromHip, toHip: s.segments[i].toHip,
                              progress: s.progress(i, at: local), alpha: h, glow: s.glow(i, at: local) * h,
                              glowPosition: s.glowPosition(i, at: local))
            }
            label = s.labelAlpha(at: local) * h
            artwork = s.artworkAlpha(at: local) * h
        case .recalled, .plainFade:
            stars = s.stars.map { StarVisual(hip: $0.hip, alpha: h) }
            segments = s.segments.map {
                SegmentVisual(index: $0.index, fromHip: $0.fromHip, toHip: $0.toHip, progress: 1, alpha: h, glow: 0,
                              glowPosition: 0)
            }
            label = h
            artwork = h
        }
        return ConstellationVisual(id: s.id, isLocked: end.map { t < $0 } ?? true, mode: mode, highlight: h,
                                   stars: stars, segments: segments, label: label, artwork: artwork)
    }
}

/// Draw-in / fade-out state for the locked constellation and any constellations still fading out.
/// Mutated only by `lock`/`unlock` events; `frame(at:)` is a pure function of those events and the time.
public struct DrawInTimeline: Sendable {
    public var config: DrawInConfig
    /// Read when a lock starts; an episode keeps the mode it started with.
    public var reduceMotion: Bool
    /// Last time each constellation was shown fully drawn (recorded when it was unlocked).
    public private(set) var lastFullyDrawn: [String: TimeInterval] = [:]
    var active: DrawInEpisode?
    var outgoing: [DrawInEpisode] = []

    public init(config: DrawInConfig = DrawInConfig(), reduceMotion: Bool = false) {
        self.config = config
        self.reduceMotion = reduceMotion
    }

    public var lockedID: String? { active?.schedule.id }

    /// Locks `schedule.id`, unlocking any other constellation at the same instant. Re-locking the current one
    /// does nothing. Re-locking one that is still fading out continues it from its current state.
    public mutating func lock(_ schedule: DrawInSchedule, at t: TimeInterval) {
        if active?.schedule.id == schedule.id { return }
        unlock(at: t)
        let previous = outgoing.firstIndex { $0.schedule.id == schedule.id }.map { outgoing.remove(at: $0) }
        let h0 = previous?.highlight(at: t) ?? 0

        if reduceMotion {
            active = DrawInEpisode(schedule: schedule, mode: .plainFade, contentOrigin: t, highlightFrom: h0,
                                   highlightStart: t, highlightRise: config.reduceMotionFadeDuration)
        } else if let previous, previous.mode == .drawIn, let end = previous.end {
            active = DrawInEpisode(schedule: schedule, mode: .drawIn,
                                   contentOrigin: t - (end - previous.contentOrigin), highlightFrom: h0,
                                   highlightStart: t, highlightRise: config.recallFadeDuration)
        } else if wouldAppearDrawn(schedule.id, at: t) {
            active = DrawInEpisode(schedule: schedule, mode: .recalled, contentOrigin: t, highlightFrom: h0,
                                   highlightStart: t, highlightRise: config.recallFadeDuration)
        } else {
            active = DrawInEpisode(schedule: schedule, mode: .drawIn, contentOrigin: t, highlightFrom: 1,
                                   highlightStart: t, highlightRise: 0)
        }
    }

    public mutating func unlock(at t: TimeInterval) {
        outgoing.removeAll { $0.isFinished(at: t) }
        guard var episode = active else { return }
        active = nil
        if episode.isFullyDrawn(at: t) { lastFullyDrawn[episode.schedule.id] = t }
        episode.end = t
        episode.endFade = reduceMotion || episode.mode == .plainFade
            ? config.reduceMotionFadeDuration : config.unlockFadeDuration
        outgoing.append(episode)
    }

    /// Whether locking `id` at `t` would show it already drawn (ignoring Reduce Motion).
    public func wouldAppearDrawn(_ id: String, at t: TimeInterval) -> Bool {
        if let active, active.schedule.id == id { return active.isFullyDrawn(at: t) }
        guard let last = lastFullyDrawn[id] else { return false }
        return t - last <= config.recallWindow
    }

    /// Outgoing constellations (fading to the resting state) first, then the locked one.
    public func frame(at t: TimeInterval) -> [ConstellationVisual] {
        var visuals = outgoing.filter { !$0.isFinished(at: t) }.map { $0.visual(at: t) }
        if let active { visuals.append(active.visual(at: t)) }
        return visuals
    }

    public func visual(for id: String, at t: TimeInterval) -> ConstellationVisual? {
        frame(at: t).last { $0.id == id }
    }
}
