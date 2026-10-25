import Foundation
import simd

/// Tuning for the stick-figure override. Score per constellation:
/// `coverageWeight·coverage + prominenceWeight·weightedDegrees/prominenceReferenceDegrees (+ romanBonus if official)`.
public struct LockScoringConfig: Sendable, Hashable {
    /// Great-circle sampling step along each segment, degrees.
    public var sampleSpacingDegrees: Double
    /// Gaussian centre weight `exp(-r²/2σ²)`, with `r` = view distance from centre / half view diagonal.
    public var centerSigma: Double
    /// Segment weight `10^(-0.4·exponent·(m − referenceMagnitude))`, clamped to `brightnessWeightRange`,
    /// where `m` is the mean V magnitude of the segment's two stars. 0 disables brightness weighting.
    public var brightnessExponent: Double
    public var brightnessReferenceMagnitude: Double
    public var brightnessWeightRange: ClosedRange<Double>
    public var coverageWeight: Double
    public var prominenceWeight: Double
    public var prominenceReferenceDegrees: Double
    /// Added to the constellation that officially (Roman 1987) contains the view centre.
    public var romanBonus: Double

    public init(sampleSpacingDegrees: Double = 0.5,
                centerSigma: Double = 0.35,
                brightnessExponent: Double = 0.8,
                brightnessReferenceMagnitude: Double = 3,
                brightnessWeightRange: ClosedRange<Double> = 0.2...5,
                coverageWeight: Double = 1,
                prominenceWeight: Double = 0.75,
                prominenceReferenceDegrees: Double = 30,
                romanBonus: Double = 0.3) {
        self.sampleSpacingDegrees = sampleSpacingDegrees
        self.centerSigma = centerSigma
        self.brightnessExponent = brightnessExponent
        self.brightnessReferenceMagnitude = brightnessReferenceMagnitude
        self.brightnessWeightRange = brightnessWeightRange
        self.coverageWeight = coverageWeight
        self.prominenceWeight = prominenceWeight
        self.prominenceReferenceDegrees = prominenceReferenceDegrees
        self.romanBonus = romanBonus
    }

    func brightnessWeight(magnitude m: Double) -> Double {
        guard m.isFinite, brightnessExponent != 0 else { return 1 }
        let w = pow(10, -0.4 * brightnessExponent * (m - brightnessReferenceMagnitude))
        return min(max(w, brightnessWeightRange.lowerBound), brightnessWeightRange.upperBound)
    }
}

/// A stick figure pre-sampled along its great circles in a fixed sky frame (normally ICRS).
public struct FigureGeometry: Sendable {
    public struct Segment: Sendable, Hashable {
        public var start: SIMD3<Double>
        public var end: SIMD3<Double>
        /// Mean V magnitude of the two endpoint stars (non-finite = unknown).
        public var magnitude: Double

        public init(start: SIMD3<Double>, end: SIMD3<Double>, magnitude: Double) {
            self.start = start
            self.end = end
            self.magnitude = magnitude
        }
    }

    public let id: String
    public let segments: [Segment]
    /// Length-weighted mean direction of the figure, unit vector in the segments' frame.
    public let centroid: SIMD3<Double>
    /// Angular radius around `centroid` containing every sample, radians.
    public let radius: Double
    /// Total great-circle length of the figure, radians.
    public let angularLength: Double
    let samples: [SIMD3<Double>]
    /// Brightness-weighted degrees represented by each sample.
    let sampleWeights: [Double]
    let totalWeight: Double

    public init(id: String, segments: [Segment], config: LockScoringConfig = LockScoringConfig()) {
        self.id = id
        self.segments = segments
        var samples: [SIMD3<Double>] = []
        var weights: [Double] = []
        var sum = SIMD3<Double>.zero
        var length = 0.0
        let spacing = max(config.sampleSpacingDegrees, 1e-3)
        for seg in segments {
            let a = simd_normalize(seg.start), b = simd_normalize(seg.end)
            let theta = Angle.separation(a, b)
            guard theta > 1e-12 else { continue }
            let n = max(1, Int((Angle.degrees(theta) / spacing).rounded(.up)))
            let w = Angle.degrees(theta) / Double(n) * config.brightnessWeight(magnitude: seg.magnitude)
            let s = sin(theta)
            for k in 0..<n {
                let t = (Double(k) + 0.5) / Double(n)
                let p = simd_normalize((sin((1 - t) * theta) * a + sin(t * theta) * b) / s)
                samples.append(p)
                weights.append(w)
                sum += p * (theta / Double(n))
            }
            length += theta
        }
        let centroid: SIMD3<Double>
        if simd_length(sum) > 1e-12 {
            centroid = simd_normalize(sum)
        } else if let first = segments.first {
            centroid = simd_normalize(first.start)
        } else {
            centroid = SIMD3(0, 0, 1)
        }
        self.centroid = centroid
        self.radius = samples.reduce(0) { max($0, Angle.separation(centroid, $1)) }
        self.angularLength = length
        self.samples = samples
        self.sampleWeights = weights
        self.totalWeight = weights.reduce(0, +)
    }

    /// Figure in ICRS from the catalog; segments whose stars are missing from the catalog are dropped.
    public init(figure: ConstellationFigure, catalog: StarCatalog, config: LockScoringConfig = LockScoringConfig()) {
        let segments: [Segment] = figure.pairs.compactMap { pair in
            guard let a = catalog.star(hip: pair.0), let b = catalog.star(hip: pair.1) else { return nil }
            return Segment(start: a.directionDouble, end: b.directionDouble,
                           magnitude: (Double(a.vmag) + Double(b.vmag)) / 2)
        }
        self.init(id: figure.id, segments: segments, config: config)
    }
}

public struct ConstellationScore: Sendable, Hashable {
    public var id: String
    /// Centre-weighted fraction of the figure (brightness-weighted length) that is on screen, 0...1.
    public var coverage: Double
    /// Centre-weighted on-screen length, brightness-weighted degrees.
    public var weightedDegrees: Double
    /// The view centre lies inside this constellation's official boundary.
    public var isOfficial: Bool
    public var score: Double
}

/// Scores every constellation for the current view: stick-figure coverage weighted toward the view centre,
/// plus a bonus for the constellation that officially contains the centre.
public struct ConstellationScorer: Sendable {
    public let config: LockScoringConfig
    public let figures: [FigureGeometry]

    public init(figures: [FigureGeometry], config: LockScoringConfig = LockScoringConfig()) {
        self.figures = figures
        self.config = config
    }

    public init(lines: ConstellationLines, catalog: StarCatalog, config: LockScoringConfig = LockScoringConfig()) {
        self.init(figures: lines.constellations.map { FigureGeometry(figure: $0, catalog: catalog, config: config) },
                  config: config)
    }

    public func figure(_ id: String) -> FigureGeometry? { figures.first { $0.id == id } }

    /// Constellations with any figure on screen plus the official one, sorted by score (desc), then id.
    /// `skyToENU` maps the figures' frame to ENU for this frame (e.g. `SkySession.icrsToENU(at:)`).
    public func evaluate(projector: Projector, skyToENU: simd_double3x3, officialID: String?) -> [ConstellationScore] {
        let center = projector.viewCenter
        let size = projector.mapping.viewSize
        let halfDiagonal = max(simd_length(size) / 2, 1e-9)
        let centerRay = projector.ray(screenPoint: center)
        let corners = [SIMD2<Double>(0, 0), SIMD2(size.x, 0), SIMD2(0, size.y), size]
        let viewRadius = corners.reduce(0) { max($0, Angle.separation(centerRay, projector.ray(screenPoint: $1))) }
        let inv2s2 = 1 / (2 * config.centerSigma * config.centerSigma)
        let toCamera = projector.enuToCamera * skyToENU

        var results: [ConstellationScore] = []
        var officialSeen = false
        for fig in figures {
            let isOfficial = fig.id == officialID
            var weighted = 0.0
            if fig.totalWeight > 0,
               Angle.separation(centerRay, skyToENU * fig.centroid) <= viewRadius + fig.radius + 1e-6 {
                for (p, w) in zip(fig.samples, fig.sampleWeights) {
                    guard let px = projector.pixel(camera: toCamera * p) else { continue }
                    let s = projector.mapping.screen(fromPixel: px)
                    guard projector.isOnScreen(s) else { continue }
                    let r2 = simd_length_squared(s - center) / (halfDiagonal * halfDiagonal)
                    weighted += w * exp(-r2 * inv2s2)
                }
            }
            guard weighted > 0 || isOfficial else { continue }
            officialSeen = officialSeen || isOfficial
            let coverage = fig.totalWeight > 0 ? min(weighted / fig.totalWeight, 1) : 0
            results.append(score(id: fig.id, coverage: coverage, weightedDegrees: weighted, isOfficial: isOfficial))
        }
        if let officialID, !officialSeen {
            results.append(score(id: officialID, coverage: 0, weightedDegrees: 0, isOfficial: true))
        }
        return results.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }

    public func scores(projector: Projector, skyToENU: simd_double3x3, officialID: String?) -> [String: Double] {
        Dictionary(evaluate(projector: projector, skyToENU: skyToENU, officialID: officialID).map { ($0.id, $0.score) },
                   uniquingKeysWith: max)
    }

    /// ICRS figures, official constellation looked up at the view centre.
    public func evaluate(projector: Projector, session: SkySession, at instant: AstroInstant,
                         roman: RomanLookup) -> [ConstellationScore] {
        evaluate(projector: projector, skyToENU: session.icrsToENU(at: instant),
                 officialID: Self.officialConstellation(projector: projector, session: session, at: instant, roman: roman))
    }

    public func scores(projector: Projector, session: SkySession, at instant: AstroInstant,
                       roman: RomanLookup) -> [String: Double] {
        Dictionary(evaluate(projector: projector, session: session, at: instant, roman: roman).map { ($0.id, $0.score) },
                   uniquingKeysWith: max)
    }

    /// Roman (1987) constellation containing the view centre.
    public static func officialConstellation(projector: Projector, session: SkySession, at instant: AstroInstant,
                                             roman: RomanLookup) -> String? {
        officialConstellation(enu: projector.ray(screenPoint: projector.viewCenter), session: session, at: instant,
                              roman: roman)
    }

    public static func officialConstellation(enu: SIMD3<Double>, session: SkySession, at instant: AstroInstant,
                                             roman: RomanLookup) -> String? {
        roman.constellation(icrs: icrs(fromENU: enu, session: session, at: instant))
    }

    /// Inverse of `SkySession.enu(icrs:at:)`.
    public static func icrs(fromENU enu: SIMD3<Double>, session: SkySession, at instant: AstroInstant) -> SIMD3<Double> {
        session.icrs(fromApparentOfDate: session.horizonMatrix(at: instant).transpose * simd_normalize(enu))
    }

    private func score(id: String, coverage: Double, weightedDegrees: Double, isOfficial: Bool) -> ConstellationScore {
        let value = config.coverageWeight * coverage
            + config.prominenceWeight * weightedDegrees / config.prominenceReferenceDegrees
            + (isOfficial ? config.romanBonus : 0)
        return ConstellationScore(id: id, coverage: coverage, weightedDegrees: weightedDegrees,
                                  isOfficial: isOfficial, score: value)
    }
}
