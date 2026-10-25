import Foundation

public struct DrawInConfig: Sendable, Hashable {
    /// Delay between consecutive BFS waves of segments.
    public var nominalStagger: TimeInterval
    public var staggerRange: ClosedRange<TimeInterval>
    public var nominalSegmentDuration: TimeInterval
    public var minimumSegmentDuration: TimeInterval
    /// From the first segment starting to the last one finishing; wins over `staggerRange` for very deep figures.
    public var drawDurationRange: ClosedRange<TimeInterval>
    /// Brightest star starts lighting at 0, the faintest at `starLightWindow`.
    public var starLightWindow: TimeInterval
    public var starFadeDuration: TimeInterval
    public var labelFadeDuration: TimeInterval
    public var pulseDuration: TimeInterval
    /// Half-width of the glow pulse as a fraction of the figure's BFS depth (at least one wave).
    public var pulseHalfWidth: Double
    public var artworkFadeDuration: TimeInterval
    public var unlockFadeDuration: TimeInterval
    /// Re-locking within this long after the figure was last shown fully drawn skips the draw-in.
    public var recallWindow: TimeInterval
    public var recallFadeDuration: TimeInterval
    public var reduceMotionFadeDuration: TimeInterval

    public init(nominalStagger: TimeInterval = 0.10,
                staggerRange: ClosedRange<TimeInterval> = 0.08...0.12,
                nominalSegmentDuration: TimeInterval = 0.8,
                minimumSegmentDuration: TimeInterval = 0.3,
                drawDurationRange: ClosedRange<TimeInterval> = 1.0...1.5,
                starLightWindow: TimeInterval = 0.35,
                starFadeDuration: TimeInterval = 0.2,
                labelFadeDuration: TimeInterval = 0.4,
                pulseDuration: TimeInterval = 0.9,
                pulseHalfWidth: Double = 0.3,
                artworkFadeDuration: TimeInterval = 1.0,
                unlockFadeDuration: TimeInterval = 0.5,
                recallWindow: TimeInterval = 60,
                recallFadeDuration: TimeInterval = 0.3,
                reduceMotionFadeDuration: TimeInterval = 0.5) {
        self.nominalStagger = nominalStagger
        self.staggerRange = staggerRange
        self.nominalSegmentDuration = nominalSegmentDuration
        self.minimumSegmentDuration = minimumSegmentDuration
        self.drawDurationRange = drawDurationRange
        self.starLightWindow = starLightWindow
        self.starFadeDuration = starFadeDuration
        self.labelFadeDuration = labelFadeDuration
        self.pulseDuration = pulseDuration
        self.pulseHalfWidth = pulseHalfWidth
        self.artworkFadeDuration = artworkFadeDuration
        self.unlockFadeDuration = unlockFadeDuration
        self.recallWindow = recallWindow
        self.recallFadeDuration = recallFadeDuration
        self.reduceMotionFadeDuration = reduceMotionFadeDuration
    }
}

/// Draw-in timing for one figure. Times are seconds since the draw-in started ("local" time).
///
/// Segments trace breadth-first from each connected component's brightest star; all segments of one BFS wave
/// start together and waves start `stagger` apart, so `drawDuration = (waveCount − 1)·stagger + segmentDuration`.
public struct DrawInSchedule: Sendable, Hashable {
    public struct Star: Sendable, Hashable {
        public var hip: Int
        /// V magnitude, non-finite if unknown (sorted as faintest).
        public var magnitude: Double
        /// BFS depth from its component's brightest star.
        public var depth: Int
        public var lightStart: TimeInterval
    }

    public struct Segment: Sendable, Hashable {
        /// Index into the figure's `pairs`.
        public var index: Int
        /// Traced from `fromHip` (discovered first by the BFS) toward `toHip`.
        public var fromHip: Int
        public var toHip: Int
        /// The figure lists this pair as (toHip, fromHip).
        public var reversed: Bool
        public var wave: Int
        public var start: TimeInterval
    }

    public let id: String
    /// Brightest first.
    public let stars: [Star]
    /// In figure order: `segments[i].index == i`.
    public let segments: [Segment]
    public let waveCount: Int
    public let stagger: TimeInterval
    public let segmentDuration: TimeInterval
    public let drawDuration: TimeInterval
    /// The stagger had to go below `staggerRange` to keep `drawDuration` within `drawDurationRange`.
    public let isStaggerCompressed: Bool
    public let starFadeDuration: TimeInterval
    public let labelStart: TimeInterval
    public let labelDuration: TimeInterval
    public let pulseStart: TimeInterval
    public let pulseDuration: TimeInterval
    /// Pulse half-width in BFS waves.
    public let pulseHalfWidth: Double
    public let artworkStart: TimeInterval
    public let artworkDuration: TimeInterval

    public var starsLitAt: TimeInterval { (stars.last?.lightStart ?? 0) + starFadeDuration }
    public var pulseEnd: TimeInterval { pulseStart + pulseDuration }
    public var completion: TimeInterval { artworkStart + artworkDuration }

    public init(id: String, pairs: [(Int, Int)], magnitudes: [Int: Double], config: DrawInConfig = DrawInConfig()) {
        self.id = id
        func mag(_ hip: Int) -> Double {
            guard let m = magnitudes[hip], m.isFinite else { return .infinity }
            return m
        }
        let hips = Set(pairs.flatMap { [$0.0, $0.1] })
        let ordered = hips.sorted { mag($0) != mag($1) ? mag($0) < mag($1) : $0 < $1 }
        let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })

        var neighbours: [Int: Set<Int>] = [:]
        for (a, b) in pairs where a != b {
            neighbours[a, default: []].insert(b)
            neighbours[b, default: []].insert(a)
        }
        var depth: [Int: Int] = [:]
        var discovery: [Int: Int] = [:]
        for root in ordered where depth[root] == nil {
            depth[root] = 0
            discovery[root] = discovery.count
            var queue = [root], head = 0
            while head < queue.count {
                let u = queue[head]
                head += 1
                for v in (neighbours[u] ?? []).sorted(by: { rank[$0]! < rank[$1]! }) where depth[v] == nil {
                    depth[v] = depth[u]! + 1
                    discovery[v] = discovery.count
                    queue.append(v)
                }
            }
        }

        let waves = pairs.map { a, b in depth[discovery[a]! <= discovery[b]! ? a : b]! }
        let waveCount = (waves.max() ?? -1) + 1
        let timing = Self.solveTiming(waveCount: waveCount, config: config)
        self.waveCount = waveCount
        self.stagger = timing.stagger
        self.segmentDuration = timing.duration
        self.drawDuration = waveCount > 0 ? Double(waveCount - 1) * timing.stagger + timing.duration : 0
        self.isStaggerCompressed = waveCount > 1 && timing.stagger < config.staggerRange.lowerBound - 1e-12

        self.segments = pairs.enumerated().map { i, pair in
            let forward = discovery[pair.0]! <= discovery[pair.1]!
            return Segment(index: i, fromHip: forward ? pair.0 : pair.1, toHip: forward ? pair.1 : pair.0,
                           reversed: !forward, wave: waves[i], start: Double(waves[i]) * timing.stagger)
        }
        let lightStep = ordered.count > 1 ? config.starLightWindow / Double(ordered.count - 1) : 0
        self.stars = ordered.enumerated().map { i, hip in
            Star(hip: hip, magnitude: mag(hip), depth: depth[hip]!, lightStart: Double(i) * lightStep)
        }
        self.starFadeDuration = config.starFadeDuration
        self.labelStart = drawDuration
        self.labelDuration = config.labelFadeDuration
        self.pulseStart = drawDuration
        self.pulseDuration = config.pulseDuration
        self.pulseHalfWidth = max(config.pulseHalfWidth * Double(waveCount), 1)
        self.artworkStart = max(drawDuration + config.pulseDuration, drawDuration + config.labelFadeDuration)
        self.artworkDuration = config.artworkFadeDuration
    }

    /// Magnitudes from the catalog; stars missing from it are treated as faintest.
    public init(figure: ConstellationFigure, catalog: StarCatalog, config: DrawInConfig = DrawInConfig()) {
        var magnitudes: [Int: Double] = [:]
        for hip in figure.starHips {
            if let star = catalog.star(hip: hip) { magnitudes[hip] = Double(star.vmag) }
        }
        self.init(id: figure.id, pairs: figure.pairs, magnitudes: magnitudes, config: config)
    }

    public static func all(lines: ConstellationLines, catalog: StarCatalog,
                           config: DrawInConfig = DrawInConfig()) -> [String: DrawInSchedule] {
        Dictionary(lines.constellations.map { ($0.id, DrawInSchedule(figure: $0, catalog: catalog, config: config)) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Nominal stagger and duration, then: lengthen the duration up to the minimum total; shorten it down to
    /// its minimum; shorten the stagger (below its range only if unavoidable) to stay under the maximum total.
    static func solveTiming(waveCount: Int, config: DrawInConfig) -> (stagger: TimeInterval, duration: TimeInterval) {
        let lo = config.drawDurationRange.lowerBound, hi = config.drawDurationRange.upperBound
        let gaps = Double(max(waveCount - 1, 0))
        var s = config.nominalStagger, d = config.nominalSegmentDuration
        if gaps * s + d < lo {
            d = lo - gaps * s
        } else if gaps * s + d > hi {
            d = max(hi - gaps * s, min(config.minimumSegmentDuration, hi))
            if gaps * s + d > hi { s = (hi - d) / gaps }
        }
        return (s, d)
    }

    // MARK: Evaluation at local time

    public func starAlpha(_ i: Int, at local: TimeInterval) -> Double {
        DrawInEase.ramp(local, start: stars[i].lightStart, duration: starFadeDuration)
    }

    /// Fraction of the chord from `fromHip` toward `toHip` that is drawn, eased in and out.
    public func progress(_ i: Int, at local: TimeInterval) -> Double {
        DrawInEase.ramp(local, start: segments[i].start, duration: segmentDuration)
    }

    public func glow(_ i: Int, at local: TimeInterval) -> Double {
        guard let front = pulseFront(at: local) else { return 0 }
        return DrawInEase.bell((front - (Double(segments[i].wave) + 0.5)) / pulseHalfWidth)
    }

    /// Where the pulse front is along the segment (0 at `fromHip`, 1 at `toHip`).
    public func glowPosition(_ i: Int, at local: TimeInterval) -> Double {
        guard let front = pulseFront(at: local) else { return 0 }
        return DrawInEase.clamp01(front - Double(segments[i].wave))
    }

    public func labelAlpha(at local: TimeInterval) -> Double {
        DrawInEase.ramp(local, start: labelStart, duration: labelDuration)
    }

    public func artworkAlpha(at local: TimeInterval) -> Double {
        DrawInEase.ramp(local, start: artworkStart, duration: artworkDuration)
    }

    /// Pulse front in BFS waves, sweeping from −halfWidth to waveCount + halfWidth; nil outside the pulse.
    func pulseFront(at local: TimeInterval) -> Double? {
        guard waveCount > 0, pulseDuration > 0, local > pulseStart, local < pulseEnd else { return nil }
        let u = (local - pulseStart) / pulseDuration
        return -pulseHalfWidth + u * (Double(waveCount) + 2 * pulseHalfWidth)
    }
}

enum DrawInEase {
    static func clamp01(_ x: Double) -> Double { x.isNaN ? 0 : min(max(x, 0), 1) }

    static func smoothstep(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }

    /// 0 before `start`, eased 0→1 over `duration`, 1 after.
    static func ramp(_ t: TimeInterval, start: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return t >= start ? 1 : 0 }
        return smoothstep((t - start) / duration)
    }

    /// Raised cosine: 1 at 0, 0 for |x| ≥ 1.
    static func bell(_ x: Double) -> Double {
        guard abs(x) < 1 else { return 0 }
        return clamp01(0.5 * (1 + cos(.pi * x)))
    }
}
