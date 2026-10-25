import Foundation
import simd

/// IAU constellation boundaries (Delporte, as digitised in VizieR VI/49) from `Data/boundaries.json`.
///
/// Every edge is a meridian or a parallel of the B1875.0 equator, so the polygons are stored as (RA hours, Dec degrees)
/// vertices and tested with the parallel-edge parity rule: count parallel edges north of the point whose RA arc
/// contains it; inside = odd (inverted for the polygon that encloses the north pole).
public struct ConstellationBoundaries: Sendable {
    public enum Pole: String, Sendable, Hashable, Codable { case north = "N", south = "S" }

    public struct Polygon: Sendable, Hashable {
        /// IAU abbreviation. Serpens has two polygons that share the id "Ser".
        public let constellation: String
        public let enclosesPole: Pole?
        /// (RA hours, Dec degrees) in B1875, closed: the last vertex equals the first.
        public let vertices: [SIMD2<Double>]
    }

    enum Edge: Sendable {
        case parallel(dec: Double, raStart: Double, width: Double)
        case meridian(ra: Double, decLow: Double, decHigh: Double)
    }

    struct ParallelRef: Sendable {
        let polygon: Int
        let dec: Double
        let raStart: Double
        let width: Double
    }

    public let polygons: [Polygon]
    /// Mean J2000 (ICRS) → mean equator and equinox of B1875.0.
    public let toB1875: simd_double3x3
    let edgesByPolygon: [[Edge]]
    let parallels: [ParallelRef]
    let parallelsByRABin: [[Int]]

    static let binsPerHour = 10

    public init(polygons: [Polygon]) {
        self.polygons = polygons
        toB1875 = EarthOrientation.precession(centuriesTT: RomanLookup.b1875CenturiesTT) * EarthOrientation.frameBias
        var edges: [[Edge]] = []
        var refs: [ParallelRef] = []
        for (index, polygon) in polygons.enumerated() {
            var list: [Edge] = []
            for (a, b) in zip(polygon.vertices, polygon.vertices.dropFirst()) {
                if a.y == b.y, a.x != b.x {
                    var w = (b.x - a.x).truncatingRemainder(dividingBy: 24)
                    if w < 0 { w += 24 }
                    let (start, width) = w <= 12 ? (a.x, w) : (b.x, 24 - w)
                    list.append(.parallel(dec: a.y, raStart: start, width: width))
                    refs.append(ParallelRef(polygon: index, dec: a.y, raStart: start, width: width))
                } else if a.x == b.x, a.y != b.y {
                    list.append(.meridian(ra: a.x, decLow: min(a.y, b.y), decHigh: max(a.y, b.y)))
                }
            }
            edges.append(list)
        }
        var bins = [[Int]](repeating: [], count: 24 * Self.binsPerHour)
        for (i, e) in refs.enumerated() {
            let first = Int(e.raStart * Double(Self.binsPerHour))
            let count = Int((e.width * Double(Self.binsPerHour)).rounded(.up)) + 1
            for k in 0...count { bins[(first + k) % bins.count].append(i) }
        }
        edgesByPolygon = edges
        parallels = refs
        parallelsByRABin = bins
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public init(data: Data) throws {
        struct File: Decodable {
            struct Constellation: Decodable {
                struct Poly: Decodable {
                    let enclosesPole: Pole?
                    let vertices: [[Double]]
                }
                let id: String
                let polygons: [Poly]
            }
            let constellations: [Constellation]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var out: [Polygon] = []
        for c in file.constellations {
            for p in c.polygons {
                guard p.vertices.count >= 4, p.vertices.allSatisfy({ $0.count == 2 }), p.vertices.first == p.vertices.last else {
                    throw CatalogError.malformed("boundary polygon of \(c.id)")
                }
                out.append(Polygon(constellation: c.id, enclosesPole: p.enclosesPole, vertices: p.vertices.map { SIMD2($0[0], $0[1]) }))
            }
        }
        self.init(polygons: out)
    }

    /// B1875 (RA hours in [0, 24), Dec degrees) of an ICRS direction.
    public func b1875(icrs v: SIMD3<Double>) -> (raHours: Double, decDegrees: Double) {
        let (lon, lat) = (toB1875 * simd_normalize(v)).lonLat
        return (Angle.degrees(lon) / 15, Angle.degrees(lat))
    }

    /// Indices into `polygons` of every polygon containing the B1875 point (one, except exactly on a border).
    public func polygonIndices(raHours1875 ra: Double, decDegrees1875 dec: Double) -> [Int] {
        var r = ra.truncatingRemainder(dividingBy: 24)
        if r < 0 { r += 24 }
        var parity = [Bool](repeating: false, count: polygons.count)
        for i in parallelsByRABin[min(parallelsByRABin.count - 1, Int(r * Double(Self.binsPerHour)))] {
            let e = parallels[i]
            guard e.dec > dec else { continue }
            var d = (r - e.raStart).truncatingRemainder(dividingBy: 24)
            if d < 0 { d += 24 }
            if d < e.width { parity[e.polygon].toggle() }
        }
        return parity.indices.filter { parity[$0] != (polygons[$0].enclosesPole == .north) }
    }

    /// IAU abbreviation of the constellation containing a B1875 point.
    public func constellation(raHours1875 ra: Double, decDegrees1875 dec: Double) -> String? {
        polygonIndices(raHours1875: ra, decDegrees1875: dec).first.map { polygons[$0].constellation }
    }

    /// IAU abbreviation of the constellation containing an ICRS (J2000) direction.
    public func constellation(icrs v: SIMD3<Double>) -> String? {
        let (ra, dec) = b1875(icrs: v)
        return constellation(raHours1875: ra, decDegrees1875: dec)
    }

    /// Angular distance in degrees from an ICRS direction to the nearest edge of polygon `index`.
    public func distanceToEdge(icrs v: SIMD3<Double>, polygon index: Int) -> Double {
        let p = simd_normalize(toB1875 * simd_normalize(v))
        let (lon, lat) = p.lonLat
        let ra = Angle.degrees(lon) / 15, dec = Angle.degrees(lat)
        var best = Double.infinity
        for edge in edgesByPolygon[index] {
            switch edge {
            case let .parallel(d0, start, width):
                var delta = (ra - start).truncatingRemainder(dividingBy: 24)
                if delta < 0 { delta += 24 }
                if delta < width {
                    best = min(best, abs(dec - d0))
                } else {
                    let a = SIMD3<Double>.unit(lon: Angle.radians(start * 15), lat: Angle.radians(d0))
                    let b = SIMD3<Double>.unit(lon: Angle.radians((start + width) * 15), lat: Angle.radians(d0))
                    best = min(best, Angle.degrees(min(Angle.separation(p, a), Angle.separation(p, b))))
                }
            case let .meridian(r, lo, hi):
                let a = SIMD3<Double>.unit(lon: Angle.radians(r * 15), lat: Angle.radians(lo))
                let b = SIMD3<Double>.unit(lon: Angle.radians(r * 15), lat: Angle.radians(hi))
                best = min(best, Angle.degrees(SphereGeometry.distance(from: p, toArc: a, b)))
            }
        }
        return best
    }
}

enum SphereGeometry {
    /// Angular distance (radians) from unit vector `p` to the minor great-circle arc a→b.
    static func distance(from p: SIMD3<Double>, toArc a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let n = simd_cross(a, b)
        let nl = simd_length(n)
        guard nl > 1e-14 else { return min(Angle.separation(p, a), Angle.separation(p, b)) }
        let nu = n / nl
        let foot = p - simd_dot(p, nu) * nu
        if simd_length(foot) > 1e-14 {
            let q = simd_normalize(foot)
            if simd_dot(simd_cross(a, q), nu) >= 0, simd_dot(simd_cross(q, b), nu) >= 0 {
                return asin(min(1, abs(simd_dot(p, nu))))
            }
        }
        return min(Angle.separation(p, a), Angle.separation(p, b))
    }
}
