import Foundation
import simd

/// Which constellation a tap on the sky means.
///
/// 1. The ray's ICRS direction is precessed to B1875 and located in the VI/49 boundary polygons (they tile the sky).
/// 2. Only when the ray lies within `edgeBandDegrees` of an edge of that polygon (its "outer edge") is the nearest
///    stick-figure segment of any constellation considered: if one lies within `figureRadiusDegrees` and is nearer
///    than every figure segment of the boundary constellation itself, that figure's constellation wins.
///    Deeper inside a region the boundary answer is final.
public struct ConstellationHitTest: Sendable {
    public struct Hit: Sendable, Hashable {
        public enum Source: String, Sendable, Hashable {
            case boundary
            case figureFallback
        }

        /// IAU abbreviation of the answer.
        public var constellation: String
        public var source: Source
        /// The constellation whose boundary polygon contains the ray (equals `constellation` for `.boundary`).
        public var boundaryConstellation: String
        /// Distance from the ray to the nearest edge of that polygon.
        public var edgeDistanceDegrees: Double
        /// Distance to the winning figure segment for `.figureFallback`.
        public var figureDistanceDegrees: Double?
    }

    public static let defaultEdgeBandDegrees = 1.5
    public static let defaultFigureRadiusDegrees = 3.0

    public let boundaries: ConstellationBoundaries
    public let edgeBandDegrees: Double
    public let figureRadiusDegrees: Double
    let segments: [(constellation: String, a: SIMD3<Double>, b: SIMD3<Double>)]

    public init(boundaries: ConstellationBoundaries, figures: [ConstellationFigure], catalog: StarCatalog,
                edgeBandDegrees: Double = defaultEdgeBandDegrees, figureRadiusDegrees: Double = defaultFigureRadiusDegrees) {
        self.boundaries = boundaries
        self.edgeBandDegrees = edgeBandDegrees
        self.figureRadiusDegrees = figureRadiusDegrees
        var segs: [(String, SIMD3<Double>, SIMD3<Double>)] = []
        for figure in figures {
            for (h1, h2) in figure.pairs {
                guard let s1 = catalog.star(hip: h1), let s2 = catalog.star(hip: h2) else { continue }
                segs.append((figure.id, s1.directionDouble, s2.directionDouble))
            }
        }
        segments = segs
    }

    /// `direction` is an ICRS (J2000) unit vector, e.g. `SkySession.icrs(fromApparentOfDate:)` of the tap ray.
    public func hit(icrs direction: SIMD3<Double>) -> Hit? {
        let p = simd_normalize(direction)
        let (ra, dec) = boundaries.b1875(icrs: p)
        guard let index = boundaries.polygonIndices(raHours1875: ra, decDegrees1875: dec).first else { return nil }
        let own = boundaries.polygons[index].constellation
        let edge = boundaries.distanceToEdge(icrs: p, polygon: index)
        let boundaryHit = Hit(constellation: own, source: .boundary, boundaryConstellation: own, edgeDistanceDegrees: edge,
                              figureDistanceDegrees: nil)
        guard edge < edgeBandDegrees else { return boundaryHit }
        var nearest: (id: String, distance: Double)?
        var ownNearest = Double.infinity
        for s in segments {
            let d = Angle.degrees(SphereGeometry.distance(from: p, toArc: s.a, s.b))
            if s.constellation == own { ownNearest = min(ownNearest, d) }
            if d < (nearest?.distance ?? .infinity) { nearest = (s.constellation, d) }
        }
        guard let nearest, nearest.id != own, nearest.distance <= figureRadiusDegrees, nearest.distance < ownNearest else {
            return boundaryHit
        }
        var hit = boundaryHit
        hit.constellation = nearest.id
        hit.source = .figureFallback
        hit.figureDistanceDegrees = nearest.distance
        return hit
    }
}
